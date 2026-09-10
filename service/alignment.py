from __future__ import annotations

import json
import os
import subprocess
import tempfile
import uuid
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any

from .subtitles import spoken_key


_LANGUAGE_MAP = {
    "zh": "Chinese",
    "zh-cn": "Chinese",
    "chinese": "Chinese",
    "en": "English",
    "en-us": "English",
    "english": "English",
}


def normalize_aligner_language(language: str) -> str:
    key = language.strip().casefold()
    if not key:
        return "Chinese"
    return _LANGUAGE_MAP.get(key, language.strip())


def script_match_score(reference: str, recognized: str) -> float:
    reference_key = spoken_key(reference)
    recognized_key = spoken_key(recognized)
    if not reference_key or not recognized_key:
        return 0.0
    return round(
        SequenceMatcher(None, reference_key, recognized_key, autojunk=False).ratio(),
        4,
    )


def classify_script_match(score: float, pass_threshold: float = 0.88, fail_threshold: float = 0.75) -> str:
    if score >= pass_threshold:
        return "pass"
    if score >= fail_threshold:
        return "warning"
    return "fail"


def forced_aligner_status(
    python_path: str | Path,
    model_path: str | Path,
    script_path: str | Path,
) -> dict[str, Any]:
    python_file = Path(python_path)
    model_dir = Path(model_path)
    script_file = Path(script_path)
    weight_file = model_dir / "model.safetensors"
    ready = python_file.is_file() and model_dir.is_dir() and weight_file.is_file() and script_file.is_file()
    return {
        "ready": ready,
        "python": python_file.is_file(),
        "model": model_dir.is_dir() and weight_file.is_file(),
        "runner": script_file.is_file(),
    }


def run_forced_alignment(
    *,
    audio_path: str | Path,
    transcript: str,
    language: str,
    python_path: str | Path,
    model_path: str | Path,
    script_path: str | Path,
    temp_dir: str | Path,
    max_audio_seconds: float = 300.0,
    timeout_seconds: int = 10800,
) -> dict[str, Any]:
    audio_file = Path(audio_path).resolve()
    python_file = Path(python_path).resolve()
    model_dir = Path(model_path).resolve()
    runner = Path(script_path).resolve()
    temp_root = Path(temp_dir).resolve()
    temp_root.mkdir(parents=True, exist_ok=True)

    status = forced_aligner_status(python_file, model_dir, runner)
    if not status["ready"]:
        raise RuntimeError(f"Qwen3 Forced Aligner is not ready: {status}")
    if not audio_file.is_file():
        raise FileNotFoundError(f"Prepared audio file was not found: {audio_file}")
    if not transcript.strip():
        raise ValueError("Transcript is empty.")

    fd, transcript_name = tempfile.mkstemp(prefix="local-asr-align-text-", suffix=".txt", dir=temp_root)
    os.close(fd)
    transcript_file = Path(transcript_name)
    result_file = temp_root / f"local-asr-align-result-{uuid.uuid4().hex}.json"
    transcript_file.write_text(transcript.strip() + "\n", encoding="utf-8")

    command = [
        str(python_file),
        str(runner),
        "--model",
        str(model_dir),
        "--audio",
        str(audio_file),
        "--transcript",
        str(transcript_file),
        "--result-json",
        str(result_file),
        "--language",
        normalize_aligner_language(language),
        "--max-audio-seconds",
        str(max_audio_seconds),
    ]
    environment = os.environ.copy()
    environment["HF_HUB_OFFLINE"] = "1"
    environment["TRANSFORMERS_OFFLINE"] = "1"
    environment["PYTHONUTF8"] = "1"
    environment["TEMP"] = str(temp_root)
    environment["TMP"] = str(temp_root)

    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout_seconds,
            env=environment,
        )
        if completed.returncode != 0:
            detail = (completed.stderr or completed.stdout or "").strip()
            raise RuntimeError(
                f"Qwen3 Forced Aligner failed with exit code {completed.returncode}: {detail[-4000:]}"
            )
        if not result_file.is_file():
            raise RuntimeError("Qwen3 Forced Aligner did not write its result JSON.")
        payload = json.loads(result_file.read_text(encoding="utf-8"))
        if payload.get("status") != "ok" or not payload.get("items"):
            raise RuntimeError("Qwen3 Forced Aligner returned no usable items.")
        return payload
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(
            f"Qwen3 Forced Aligner exceeded the timeout of {timeout_seconds} seconds."
        ) from exc
    finally:
        transcript_file.unlink(missing_ok=True)
        result_file.unlink(missing_ok=True)
