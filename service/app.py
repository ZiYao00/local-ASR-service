from __future__ import annotations

import asyncio
import json
import os
import shutil
import tempfile
from pathlib import Path
from typing import Any

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse

from .engine import AsrEngine


ROOT = Path(__file__).resolve().parents[1]
LOCAL_CONFIG = ROOT / "config" / "local.json"


def _resolve_project_path(value: str) -> str:
    path = Path(value)
    if path.is_absolute():
        raise RuntimeError(f"Machine-local paths must be relative to project root: {value}")
    return str((ROOT / path).resolve())


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

    model_path = _resolve_project_path(str(data["modelPath"]))
    vad_value = str(data["vadModel"])
    vad_model = _resolve_project_path(vad_value) if (ROOT / vad_value).exists() else vad_value
    punc_value = str(data["puncModel"])
    punc_model = _resolve_project_path(punc_value) if (ROOT / punc_value).exists() else punc_value
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
    if queue_timeout_seconds <= 0:
        raise RuntimeError("queueTimeoutSeconds must be greater than zero.")
    if max_upload_bytes <= 0:
        raise RuntimeError("maxUploadBytes must be greater than zero.")
    if upload_chunk_bytes <= 0:
        raise RuntimeError("uploadChunkBytes must be greater than zero.")

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
    }


CONFIG = _load_config()
ENGINE = AsrEngine(CONFIG)
APP = FastAPI(title="local-ASR-service", version="0.2.0")
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
    return {
        "status": "ok" if ENGINE.ready else "starting",
        "service": "local-ASR-service",
        "device": CONFIG["device"],
        "model": CONFIG["model_name"],
        "vad": True,
        "punctuation": True,
        "queue": await _queue_snapshot(),
        "ffmpeg": shutil.which("ffmpeg") is not None,
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


app = APP
