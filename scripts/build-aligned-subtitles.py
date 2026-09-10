from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from service.subtitles import format_srt, segment_aligned_transcript, summarize_cues


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--alignment-json", required=True)
    parser.add_argument("--transcript", required=True)
    parser.add_argument("--output-srt", required=True)
    parser.add_argument("--output-json", required=True)
    parser.add_argument("--preset", default="voiceover")
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    alignment_path = Path(args.alignment_json).resolve()
    transcript_path = Path(args.transcript).resolve()
    srt_path = Path(args.output_srt).resolve()
    json_path = Path(args.output_json).resolve()

    for path, label in ((alignment_path, "alignment JSON"), (transcript_path, "transcript")):
        if not path.is_file():
            raise FileNotFoundError(f"{label} was not found: {path}")
    for output_path in (srt_path, json_path):
        if output_path.exists():
            raise FileExistsError(f"Refusing to overwrite existing output: {output_path}")

    alignment = json.loads(alignment_path.read_text(encoding="utf-8"))
    items = alignment.get("items") or []
    transcript = transcript_path.read_text(encoding="utf-8-sig").strip()
    cues = segment_aligned_transcript(transcript, items, args.preset)
    summary = summarize_cues(cues)

    srt_path.parent.mkdir(parents=True, exist_ok=True)
    srt_path.write_text(format_srt(cues), encoding="utf-8-sig", newline="")

    payload = {
        "status": "ok",
        "preset": args.preset,
        "source_alignment": str(alignment_path),
        "source_transcript": str(transcript_path),
        "summary": summary,
        "cues": cues,
    }
    json_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(payload["summary"], ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
