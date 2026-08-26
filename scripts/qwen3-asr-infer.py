"""Run one local Qwen3-ASR CPU inference and write a non-overwriting JSON result."""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import torch
from qwen_asr import Qwen3ASRModel


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--audio", required=True)
    parser.add_argument("--result-json", required=True)
    parser.add_argument("--language", default="Chinese")
    args = parser.parse_args()

    model_path = Path(args.model)
    audio_path = Path(args.audio)
    result_path = Path(args.result_json)
    if not model_path.is_dir():
        raise FileNotFoundError(f"Local model directory was not found: {model_path}")
    if not audio_path.is_file():
        raise FileNotFoundError(f"Prepared audio file was not found: {audio_path}")
    if result_path.exists():
        raise FileExistsError(f"Refusing to overwrite existing result: {result_path}")

    total_started = time.perf_counter()
    load_started = time.perf_counter()
    model = Qwen3ASRModel.from_pretrained(
        str(model_path),
        dtype=torch.float32,
        device_map="cpu",
        max_inference_batch_size=1,
        max_new_tokens=512,
    )
    load_seconds = time.perf_counter() - load_started

    transcribe_started = time.perf_counter()
    results = model.transcribe(str(audio_path), language=args.language)
    transcribe_seconds = time.perf_counter() - transcribe_started
    if len(results) != 1 or not results[0].text or not results[0].text.strip():
        raise RuntimeError("Qwen3-ASR returned no usable text.")

    payload = {
        "model": "Qwen/Qwen3-ASR-0.6B",
        "model_path": str(model_path),
        "runtime": "cpu",
        "dtype": "float32",
        "language": results[0].language,
        "text": results[0].text.strip(),
        "model_load_seconds": round(load_seconds, 3),
        "transcription_seconds": round(transcribe_seconds, 3),
        "python_total_seconds": round(time.perf_counter() - total_started, 3),
    }
    with result_path.open("x", encoding="utf-8", newline="\n") as output:
        json.dump(payload, output, ensure_ascii=False, indent=2)
        output.write("\n")


if __name__ == "__main__":
    main()
