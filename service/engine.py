from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import threading
import unicodedata
from pathlib import Path
from typing import Any


def _alignment_key(text: str) -> str:
    """Remove whitespace and punctuation while preserving spoken surface characters."""
    return "".join(
        char
        for char in text
        if not char.isspace() and not unicodedata.category(char).startswith("P")
    )


def _map_punctuation_to_segments(full_text: str, segment_texts: list[str]) -> list[str] | None:
    """Project punctuation from full_text back onto VAD segments without changing timing."""
    if not full_text or not segment_texts:
        return None

    segment_keys = [_alignment_key(text) for text in segment_texts]
    if any(not key for key in segment_keys):
        return None

    full_key = _alignment_key(full_text)
    if "".join(segment_keys).casefold() != full_key.casefold():
        return None

    content_positions = [
        index
        for index, char in enumerate(full_text)
        if not char.isspace() and not unicodedata.category(char).startswith("P")
    ]
    if len(content_positions) != len(full_key):
        return None

    mapped: list[str] = []
    content_offset = 0
    slice_start = 0
    for segment_key in segment_keys:
        content_offset += len(segment_key)
        if content_offset < len(content_positions):
            slice_end = content_positions[content_offset]
        else:
            slice_end = len(full_text)
        piece = full_text[slice_start:slice_end].strip()
        if not piece:
            return None
        mapped.append(piece)
        slice_start = slice_end

    return mapped


class AsrEngine:
    def __init__(self, config: dict[str, Any]) -> None:
        self.root = Path(config["root"])
        self.device = str(config["device"])
        self.model_name = str(config["model_name"])
        self.model_path = str(config["model_path"])
        self.vad_model = str(config["vad_model"])
        self.punc_model = str(config["punc_model"])
        self.max_single_segment_ms = int(config.get("max_single_segment_ms", 30000))
        self.ffmpeg_path = str(config.get("ffmpeg_path", "ffmpeg"))
        self.temp_dir = Path(config["temp_dir"])
        self.temp_dir.mkdir(parents=True, exist_ok=True)
        self._model = None
        self._model_lock = threading.Lock()

    @property
    def ready(self) -> bool:
        return self._model is not None

    def load(self) -> None:
        with self._model_lock:
            if self._model is not None:
                return
            from funasr import AutoModel

            self._model = AutoModel(
                model=self.model_path,
                vad_model=self.vad_model,
                vad_kwargs={"max_single_segment_time": self.max_single_segment_ms},
                punc_model=self.punc_model,
                device=self.device,
                hub="ms",
                disable_update=True,
                disable_pbar=True,
            )

    @property
    def ffmpeg_ready(self) -> bool:
        candidate = Path(self.ffmpeg_path)
        return candidate.is_file() if candidate.is_absolute() else shutil.which(self.ffmpeg_path) is not None

    def normalize_media(self, input_path: Path) -> tuple[Path, Path | None]:
        """Normalize supported media to a temporary 16 kHz mono PCM WAV."""
        return self._normalize_media(input_path)

    def _normalize_media(self, input_path: Path) -> tuple[Path, Path | None]:
        candidate = Path(self.ffmpeg_path)
        ffmpeg = str(candidate) if candidate.is_absolute() and candidate.is_file() else shutil.which(self.ffmpeg_path)
        if not ffmpeg:
            raise RuntimeError("ffmpeg was not found; media cannot be normalized.")

        fd, temp_name = tempfile.mkstemp(prefix="local-asr-", suffix=".wav", dir=self.temp_dir)
        os.close(fd)
        temp_path = Path(temp_name)
        try:
            subprocess.run(
                [
                    ffmpeg,
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-y",
                    "-i",
                    str(input_path),
                    "-vn",
                    "-ac",
                    "1",
                    "-ar",
                    "16000",
                    "-c:a",
                    "pcm_s16le",
                    str(temp_path),
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
            return temp_path, temp_path
        except subprocess.CalledProcessError as exc:
            temp_path.unlink(missing_ok=True)
            detail = (exc.stderr or "").strip()
            raise RuntimeError(f"ffmpeg could not normalize media: {detail}") from exc

    def transcribe(self, input_path: Path, language: str = "zh") -> dict[str, Any]:
        self.load()
        normalized, cleanup_path = self._normalize_media(input_path)
        try:
            result_list = self._model.generate(
                input=str(normalized),
                language=language,
                batch_size=1,
                sentence_timestamp=True,
                return_raw_text=True,
            )
            if not result_list:
                raise RuntimeError("ASR returned no result.")
            result = result_list[0]
            text = str(result.get("text") or "").strip()
            if not text:
                raise RuntimeError("ASR returned empty text.")

            raw_text = str(result.get("raw_text") or text).strip()
            raw_text = re.sub(r"<\|[^|]*\|>", "", raw_text).strip()
            sentence_info = result.get("sentence_info") or []
            segments: list[dict[str, Any]] = []
            for item in sentence_info:
                segment_text = str(item.get("text") or item.get("sentence") or "").strip()
                if not segment_text:
                    continue
                start_ms = float(item.get("start") or 0.0)
                end_ms = float(item.get("end") or start_ms)
                segment: dict[str, Any] = {
                    "start": round(start_ms / 1000.0, 3),
                    "end": round(end_ms / 1000.0, 3),
                    "text": segment_text,
                }
                if item.get("raw_text"):
                    segment["raw_text"] = re.sub(r"<\|[^|]*\|>", "", str(item["raw_text"])).strip()
                segments.append(segment)

            segments_punctuated = False
            if segments:
                mapped_texts = _map_punctuation_to_segments(
                    text,
                    [str(segment["text"]) for segment in segments],
                )
                if mapped_texts is not None:
                    for segment, mapped_text in zip(segments, mapped_texts):
                        segment["text"] = mapped_text
                    segments_punctuated = True
                elif len(segments) == 1:
                    segments[0]["text"] = text
                    segments_punctuated = True

            try:
                import soundfile as sf

                duration = round(float(sf.info(str(normalized)).duration), 3)
            except Exception:
                duration = max((float(segment["end"]) for segment in segments), default=None)

            return {
                "status": "ok",
                "text": text,
                "raw_text": raw_text,
                "language": language,
                "duration": duration,
                "model": self.model_name,
                "segments": segments,
                "segments_punctuated": segments_punctuated,
            }
        finally:
            if cleanup_path is not None:
                cleanup_path.unlink(missing_ok=True)
