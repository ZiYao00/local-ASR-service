from __future__ import annotations

import asyncio
import json
import os
import tempfile
from pathlib import Path
from typing import Any

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse

from .alignment import classify_script_match, forced_aligner_status, run_forced_alignment, script_match_score
from .engine import AsrEngine
from .subtitles import PRESETS, format_srt, segment_aligned_transcript, summarize_cues


ROOT = Path(__file__).resolve().parents[1]
LOCAL_CONFIG = ROOT / "config" / "local.json"


def _resolve_project_path(value: str) -> str:
    path = Path(value)
    if path.is_absolute():
        raise RuntimeError(f"Machine-local paths must be relative to project root: {value}")
    return str((ROOT / path).resolve())


def _resolve_model_reference(value: str) -> str:
    """Resolve project-local model paths while allowing official model IDs for fresh installs."""
    path = Path(value)
    if path.is_absolute():
        raise RuntimeError(f"Model paths must be relative to project root or a model ID: {value}")
    candidate = ROOT / path
    if candidate.exists():
        return str(candidate.resolve())
    if value.replace("/", "\\").lower().startswith("models\\"):
        raise RuntimeError(f"Configured local model directory does not exist: {candidate}")
    return value


def _load_config() -> dict[str, Any]:
    if not LOCAL_CONFIG.is_file():
        raise RuntimeError(f"Missing machine-local configuration: {LOCAL_CONFIG}")
    data = json.loads(LOCAL_CONFIG.read_text(encoding="utf-8"))
    required = [
        "host",
        "port",
        "modelName",
        "modelPath",
        "vadModel",
        "puncModel",
        "temp",
        "queueTimeoutSeconds",
    ]
    for key in required:
        if key not in data or data[key] in (None, ""):
            raise RuntimeError(f"Missing required setting '{key}' in config/local.json")

    model_path = _resolve_model_reference(str(data["modelPath"]))
    vad_model = _resolve_model_reference(str(data["vadModel"]))
    punc_model = _resolve_model_reference(str(data["puncModel"]))
    temp_dir = _resolve_project_path(str(data["temp"]))

    os.environ["MODELSCOPE_CACHE"] = _resolve_project_path(str(data["modelScopeCache"]))
    os.environ["HF_HOME"] = str((Path(_resolve_project_path(str(data["runtimeCache"]))) / "huggingface"))
    os.environ["TORCH_HOME"] = str((Path(_resolve_project_path(str(data["runtimeCache"]))) / "torch"))
    os.environ["TEMP"] = temp_dir
    os.environ["TMP"] = temp_dir
    os.environ["PYTHONUTF8"] = "1"
    os.environ["TOKENIZERS_PARALLELISM"] = "false"

    queue_timeout_seconds = int(data["queueTimeoutSeconds"])
    max_upload_bytes = int(data.get("maxUploadBytes", 2 * 1024 * 1024 * 1024))
    upload_chunk_bytes = int(data.get("uploadChunkBytes", 4 * 1024 * 1024))
    forced_aligner_python = _resolve_project_path(str(data.get("forcedAlignerPython", ".venv-qwen3-asr\\Scripts\\python.exe")))
    forced_aligner_model = _resolve_project_path(str(data.get("forcedAlignerModelPath", "models\\qwen3-forced-aligner-0.6b")))
    forced_aligner_script = str((ROOT / "scripts" / "qwen3-forced-align.py").resolve())
    forced_aligner_max_audio_seconds = float(data.get("forcedAlignerMaxAudioSeconds", 300.0))
    alignment_timeout_seconds = int(data.get("alignmentTimeoutSeconds", data.get("requestTimeoutSeconds", 10800)))
    script_match_pass_threshold = float(data.get("scriptMatchPassThreshold", 0.88))
    script_match_fail_threshold = float(data.get("scriptMatchFailThreshold", 0.75))
    if queue_timeout_seconds <= 0:
        raise RuntimeError("queueTimeoutSeconds must be greater than zero.")
    if max_upload_bytes <= 0:
        raise RuntimeError("maxUploadBytes must be greater than zero.")
    if upload_chunk_bytes <= 0:
        raise RuntimeError("uploadChunkBytes must be greater than zero.")
    if forced_aligner_max_audio_seconds <= 0:
        raise RuntimeError("forcedAlignerMaxAudioSeconds must be greater than zero.")
    if alignment_timeout_seconds <= 0:
        raise RuntimeError("alignmentTimeoutSeconds must be greater than zero.")
    if not 0 <= script_match_fail_threshold <= script_match_pass_threshold <= 1:
        raise RuntimeError("Script match thresholds must satisfy 0 <= fail <= pass <= 1.")

    return {
        "root": str(ROOT),
        "host": str(data["host"]),
        "port": int(data["port"]),
        "device": os.environ.get("LOCAL_ASR_DEVICE", "cpu"),
        "model_name": str(data["modelName"]),
        "model_path": model_path,
        "vad_model": vad_model,
        "punc_model": punc_model,
        "max_single_segment_ms": int(data.get("maxSingleSegmentMs", 30000)),
        "temp_dir": temp_dir,
        "queue_timeout_seconds": queue_timeout_seconds,
        "max_upload_bytes": max_upload_bytes,
        "upload_chunk_bytes": upload_chunk_bytes,
        "ffmpeg_path": os.environ.get("LOCAL_ASR_FFMPEG", "ffmpeg"),
        "forced_aligner_python": forced_aligner_python,
        "forced_aligner_model": forced_aligner_model,
        "forced_aligner_script": forced_aligner_script,
        "forced_aligner_max_audio_seconds": forced_aligner_max_audio_seconds,
        "alignment_timeout_seconds": alignment_timeout_seconds,
        "script_match_pass_threshold": script_match_pass_threshold,
        "script_match_fail_threshold": script_match_fail_threshold,
    }


CONFIG = _load_config()
ENGINE = AsrEngine(CONFIG)
APP = FastAPI(title="local-ASR-service", version="0.4.0")
QUEUE = asyncio.Semaphore(1)
STATE_LOCK = asyncio.Lock()
RUNNING = 0
WAITING = 0

SUPPORTED_EXTENSIONS = {".wav", ".mp3", ".flac", ".m4a", ".ogg", ".webm", ".mp4", ".mov", ".mkv"}


async def _queue_snapshot() -> dict[str, int]:
    async with STATE_LOCK:
        return {"running": RUNNING, "waiting": WAITING}


async def _enter_queue() -> None:
    global RUNNING, WAITING
    async with STATE_LOCK:
        WAITING += 1
    try:
        await asyncio.wait_for(QUEUE.acquire(), timeout=CONFIG["queue_timeout_seconds"])
    except TimeoutError as exc:
        raise HTTPException(status_code=503, detail="Timed out waiting for the local ASR queue.") from exc
    finally:
        async with STATE_LOCK:
            WAITING -= 1
    async with STATE_LOCK:
        RUNNING += 1


async def _leave_queue() -> None:
    global RUNNING
    async with STATE_LOCK:
        RUNNING -= 1
    QUEUE.release()


async def _save_upload(file: UploadFile, suffix: str) -> Path:
    """Save an upload incrementally so long media files are never held in RAM."""
    fd, temp_name = tempfile.mkstemp(prefix="local-asr-upload-", suffix=suffix, dir=CONFIG["temp_dir"])
    os.close(fd)
    temp_path = Path(temp_name)
    received = 0

    try:
        with temp_path.open("wb") as destination:
            while chunk := await file.read(CONFIG["upload_chunk_bytes"]):
                received += len(chunk)
                if received > CONFIG["max_upload_bytes"]:
                    raise HTTPException(
                        status_code=413,
                        detail=(
                            "Uploaded media exceeds the configured maximum of "
                            f"{CONFIG['max_upload_bytes']} bytes."
                        ),
                    )
                destination.write(chunk)
        if received == 0:
            raise HTTPException(status_code=400, detail="Uploaded media file is empty.")
        return temp_path
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise


@APP.on_event("startup")
async def startup() -> None:
    await asyncio.to_thread(ENGINE.load)


@APP.get("/health")
async def health() -> dict[str, Any]:
    alignment = forced_aligner_status(
        CONFIG["forced_aligner_python"],
        CONFIG["forced_aligner_model"],
        CONFIG["forced_aligner_script"],
    )
    return {
        "status": "ok" if ENGINE.ready else "starting",
        "service": "local-ASR-service",
        "device": CONFIG["device"],
        "model": CONFIG["model_name"],
        "vad": True,
        "punctuation": True,
        "queue": await _queue_snapshot(),
        "ffmpeg": ENGINE.ffmpeg_ready,
        "forced_alignment": {
            **alignment,
            "model_name": "Qwen3-ForcedAligner-0.6B",
            "max_audio_seconds": CONFIG["forced_aligner_max_audio_seconds"],
        },
    }


@APP.get("/v1/models")
async def models() -> dict[str, Any]:
    return {
        "object": "list",
        "data": [{"id": "custom", "object": "model", "owned_by": "local-ASR-service"}],
    }


@APP.post("/v1/audio/transcriptions")
async def transcribe(
    file: UploadFile = File(...),
    model: str = Form(default="custom"),
    language: str = Form(default="zh"),
    response_format: str = Form(default="verbose_json"),
):
    if model != "custom":
        raise HTTPException(status_code=400, detail="Only model='custom' is supported by local-ASR-service.")

    suffix = Path(file.filename or "audio.wav").suffix.lower() or ".wav"
    if suffix not in SUPPORTED_EXTENSIONS:
        raise HTTPException(status_code=400, detail=f"Unsupported media extension: {suffix}")
    if response_format not in {"text", "json", "verbose_json"}:
        raise HTTPException(status_code=400, detail=f"Unsupported response_format: {response_format}")

    temp_path: Path | None = None
    entered_queue = False
    try:
        temp_path = await _save_upload(file, suffix)
        await _enter_queue()
        entered_queue = True
        try:
            result = await asyncio.to_thread(ENGINE.transcribe, temp_path, language)
        except Exception as exc:
            raise HTTPException(status_code=500, detail=str(exc)) from exc
    finally:
        if entered_queue:
            await _leave_queue()
        if temp_path is not None:
            temp_path.unlink(missing_ok=True)
        await file.close()

    if response_format == "text":
        return PlainTextResponse(result["text"])
    return JSONResponse(result)


@APP.post("/v1/audio/alignments")
async def align_audio(
    file: UploadFile = File(...),
    transcript: str = Form(...),
    language: str = Form(default="zh"),
    preset: str = Form(default="voiceover"),
    allow_script_mismatch: bool = Form(default=False),
):
    transcript = transcript.strip()
    if not transcript:
        raise HTTPException(status_code=400, detail="Transcript must not be empty.")
    if len(transcript) > 100_000:
        raise HTTPException(status_code=400, detail="Transcript is too large for the alignment endpoint.")
    if preset not in PRESETS:
        raise HTTPException(status_code=400, detail=f"Unknown subtitle preset: {preset}")

    suffix = Path(file.filename or "audio.wav").suffix.lower() or ".wav"
    if suffix not in SUPPORTED_EXTENSIONS:
        raise HTTPException(status_code=400, detail=f"Unsupported media extension: {suffix}")

    aligner = forced_aligner_status(
        CONFIG["forced_aligner_python"],
        CONFIG["forced_aligner_model"],
        CONFIG["forced_aligner_script"],
    )
    if not aligner["ready"]:
        raise HTTPException(status_code=503, detail={"message": "Qwen3 Forced Aligner is not ready.", "status": aligner})

    normalized_language = language.strip().casefold()
    asr_language = "zh" if normalized_language in {"chinese", "zh-cn"} else (
        "en" if normalized_language in {"english", "en-us"} else language
    )

    temp_path: Path | None = None
    normalized_cleanup: Path | None = None
    entered_queue = False
    try:
        temp_path = await _save_upload(file, suffix)
        await _enter_queue()
        entered_queue = True
        try:
            asr_result = await asyncio.to_thread(ENGINE.transcribe, temp_path, asr_language)
            match_score = script_match_score(transcript, str(asr_result.get("text") or ""))
            match_status = classify_script_match(
                match_score,
                pass_threshold=CONFIG["script_match_pass_threshold"],
                fail_threshold=CONFIG["script_match_fail_threshold"],
            )
            match_payload = {
                "score": match_score,
                "status": match_status,
                "pass_threshold": CONFIG["script_match_pass_threshold"],
                "fail_threshold": CONFIG["script_match_fail_threshold"],
                "asr_text": asr_result.get("text"),
            }
            if match_status == "fail" and not allow_script_mismatch:
                raise HTTPException(
                    status_code=422,
                    detail={
                        "message": "Transcript differs too much from the spoken audio; forced alignment was not run.",
                        "script_match": match_payload,
                    },
                )

            normalized_audio, normalized_cleanup = await asyncio.to_thread(ENGINE.normalize_media, temp_path)
            alignment_result = await asyncio.to_thread(
                run_forced_alignment,
                audio_path=normalized_audio,
                transcript=transcript,
                language=language,
                python_path=CONFIG["forced_aligner_python"],
                model_path=CONFIG["forced_aligner_model"],
                script_path=CONFIG["forced_aligner_script"],
                temp_dir=CONFIG["temp_dir"],
                max_audio_seconds=CONFIG["forced_aligner_max_audio_seconds"],
                timeout_seconds=CONFIG["alignment_timeout_seconds"],
            )
            cues = segment_aligned_transcript(transcript, alignment_result["items"], preset)
            cue_summary = summarize_cues(cues)
            result = {
                "status": "ok",
                "text": transcript,
                "language": language,
                "duration": alignment_result.get("audio_duration_seconds"),
                "model": "Qwen3-ForcedAligner-0.6B",
                "preset": preset,
                "script_match": match_payload,
                "aligned_units": alignment_result.get("aligned_units"),
                "items": alignment_result["items"],
                "segments": cues,
                "subtitle_summary": cue_summary,
                "srt": format_srt(cues),
                "performance": {
                    "model_load_seconds": alignment_result.get("model_load_seconds"),
                    "alignment_seconds": alignment_result.get("alignment_seconds"),
                    "alignment_total_seconds": alignment_result.get("total_seconds"),
                },
            }
        except HTTPException:
            raise
        except Exception as exc:
            raise HTTPException(status_code=500, detail=str(exc)) from exc
    finally:
        if normalized_cleanup is not None:
            normalized_cleanup.unlink(missing_ok=True)
        if entered_queue:
            await _leave_queue()
        if temp_path is not None:
            temp_path.unlink(missing_ok=True)
        await file.close()

    return JSONResponse(result)


app = APP
