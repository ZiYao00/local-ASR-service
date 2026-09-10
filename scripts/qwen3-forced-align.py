"""Run one local Qwen3 Forced Aligner CPU feasibility test.

This Phase-A runner is intentionally local-only: the model argument must point to
an existing local directory. It never accepts a remote model id, so running the
script cannot silently download model weights.
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import soundfile as sf


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, help="Local Qwen3-ForcedAligner model directory.")
    parser.add_argument("--audio", required=True, help="Audio/media file to align.")
    parser.add_argument("--transcript", required=True, help="UTF-8 transcript file.")
    parser.add_argument("--result-json", required=True, help="New JSON output path; existing files are not overwritten.")
    parser.add_argument("--language", default="Chinese")
    parser.add_argument("--max-audio-seconds", type=float, default=300.0)
    return parser.parse_args()


def main() -> None:
    args = _parse_args()

    model_path = Path(args.model).resolve()
    audio_path = Path(args.audio).resolve()
    transcript_path = Path(args.transcript).resolve()
    result_path = Path(args.result_json).resolve()

    if not model_path.is_dir():
        raise FileNotFoundError(
            "Local Qwen3-ForcedAligner model directory was not found: "
            f"{model_path}. This runner does not download models automatically."
        )
    if not audio_path.is_file():
        raise FileNotFoundError(f"Audio file was not found: {audio_path}")
    if not transcript_path.is_file():
        raise FileNotFoundError(f"Transcript file was not found: {transcript_path}")
    if result_path.exists():
        raise FileExistsError(f"Refusing to overwrite existing result: {result_path}")

    transcript = transcript_path.read_text(encoding="utf-8-sig").strip()
    if not transcript:
        raise ValueError("Transcript is empty.")

    audio_duration = float(sf.info(str(audio_path)).duration)
    if args.max_audio_seconds > 0 and audio_duration > args.max_audio_seconds:
        raise ValueError(
            f"Audio is {audio_duration:.3f}s, which exceeds the Phase-A limit of "
            f"{args.max_audio_seconds:.3f}s."
        )

    import torch
    from qwen_asr import Qwen3ForcedAligner

    total_started = time.perf_counter()
    load_started = time.perf_counter()
    aligner = Qwen3ForcedAligner.from_pretrained(
        str(model_path),
        dtype=torch.float32,
        device_map="cpu",
    )
    load_seconds = time.perf_counter() - load_started

    align_started = time.perf_counter()
    results = aligner.align(
        audio=str(audio_path),
        text=transcript,
        language=args.language,
    )
    align_seconds = time.perf_counter() - align_started

    if len(results) != 1 or not results[0].items:
        raise RuntimeError("Qwen3 Forced Aligner returned no usable alignment items.")

    items = [
        {
            "text": item.text,
            "start": round(float(item.start_time), 3),
            "end": round(float(item.end_time), 3),
        }
        for item in results[0].items
    ]

    previous_end = 0.0
    non_monotonic_items = 0
    invalid_items = 0
    for item in items:
        start = float(item["start"])
        end = float(item["end"])
        if start < previous_end:
            non_monotonic_items += 1
        if start < 0 or end < start or end > audio_duration + 0.25:
            invalid_items += 1
        previous_end = max(previous_end, end)

    payload = {
        "status": "ok",
        "model": "Qwen3-ForcedAligner-0.6B",
        "model_path": str(model_path),
        "runtime": "cpu",
        "dtype": "float32",
        "language": args.language,
        "audio": str(audio_path),
        "transcript_file": str(transcript_path),
        "audio_duration_seconds": round(audio_duration, 3),
        "transcript_characters": len(transcript),
        "aligned_units": len(items),
        "model_load_seconds": round(load_seconds, 3),
        "alignment_seconds": round(align_seconds, 3),
        "total_seconds": round(time.perf_counter() - total_started, 3),
        "qa": {
            "non_monotonic_items": non_monotonic_items,
            "invalid_items": invalid_items,
            "first_start": items[0]["start"],
            "last_end": items[-1]["end"],
        },
        "items": items,
    }

    result_path.parent.mkdir(parents=True, exist_ok=True)
    with result_path.open("x", encoding="utf-8", newline="\n") as output:
        json.dump(payload, output, ensure_ascii=False, indent=2)
        output.write("\n")

    print(json.dumps({key: payload[key] for key in (
        "status",
        "audio_duration_seconds",
        "transcript_characters",
        "aligned_units",
        "model_load_seconds",
        "alignment_seconds",
        "total_seconds",
        "qa",
    )}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
