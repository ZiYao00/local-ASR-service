"""Prepare optional, locally cached ASR model snapshots (no weights in Git).

The main ASR uses the identical ModelScope cache as FunASR AutoModel.
Qwen modes download only after the user explicitly enables those features.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE_MODELS = (
    "iic/SenseVoiceSmall",
    "iic/speech_fsmn_vad_zh-cn-16k-common-pytorch",
    "iic/punc_ct-transformer_cn-en-common-vocab471067-large",
)
QWEN_MODELS = {
    "aligner": ("Qwen/Qwen3-ForcedAligner-0.6B", ROOT / "models/qwen3-forced-aligner-0.6b"),
    "qwen-asr": ("Qwen/Qwen3-ASR-0.6B", ROOT / "models/qwen3-asr-0.6b"),
}


def valid_safetensors_layout(weights: Path) -> bool:
    """Check header and exact payload extent without loading model tensors.

    SafeTensors headers contain byte offsets for all tensors. This catches
    truncated and malformed weight files even when their size exceeds 100 MB.
    It is a structural check, not a cryptographic checksum.
    """
    try:
        total_size = weights.stat().st_size
        if total_size < 16:
            return False
        with weights.open("rb") as file:
            prefix = file.read(8)
            if len(prefix) != 8:
                return False
            header_size = int.from_bytes(prefix, "little")
            if header_size < 2 or header_size > min(total_size - 8, 16 * 1024 * 1024):
                return False
            raw_header = file.read(header_size)
            if len(raw_header) != header_size:
                return False
        header = json.loads(raw_header)
        if not isinstance(header, dict):
            return False
        spans: list[tuple[int, int]] = []
        for name, metadata in header.items():
            if name == "__metadata__":
                continue
            if not isinstance(metadata, dict):
                return False
            pair = metadata.get("data_offsets")
            if (
                not isinstance(pair, list)
                or len(pair) != 2
                or any(type(offset) is not int or offset < 0 for offset in pair)
            ):
                return False
            spans.append((pair[0], pair[1]))
        if not spans:
            return False
        current_end = 0
        for start, end in sorted(spans):
            if start != current_end or end < start:
                return False
            current_end = end
        return current_end == total_size - 8 - header_size
    except (OSError, ValueError, TypeError, UnicodeError):
        return False


def complete_qwen(path: Path) -> bool:
    # Both supported Qwen3 0.6B snapshots use these tokenizer/audio files.
    necessary = (
        "config.json",
        "tokenizer_config.json",
        "vocab.json",
        "merges.txt",
        "preprocessor_config.json",
        "model.safetensors",
    )
    try:
        for name in necessary:
            item = path / name
            if not item.is_file() or item.stat().st_size <= 0:
                return False
        for name in ("config.json", "tokenizer_config.json", "preprocessor_config.json"):
            if not isinstance(json.loads((path / name).read_text(encoding="utf-8")), dict):
                return False
        config = json.loads((path / "config.json").read_text(encoding="utf-8"))
        if config.get("model_type") != "qwen3_asr":
            return False
        return valid_safetensors_layout(path / "model.safetensors")
    except (OSError, ValueError, TypeError, UnicodeError):
        return False


def prepare_base(offline: bool) -> None:
    import json
    from modelscope import snapshot_download

    # Keep cache locations consistent with service.app and environment.ps1.
    settings = json.loads((ROOT / "config/local.json").read_text(encoding="utf-8-sig"))
    selected = (settings["modelPath"], settings["vadModel"], settings["puncModel"])
    cache = ROOT / settings["modelScopeCache"]
    cache.mkdir(parents=True, exist_ok=True)
    os.environ["MODELSCOPE_CACHE"] = str(cache)
    for model_id in selected:
        relative = model_id.replace("\\", "/")
        manual_dir = ROOT / relative
        if relative.startswith("models/"):
            if not (manual_dir / "model.pt").is_file():
                raise RuntimeError(f"Configured local model directory is incomplete: {manual_dir}")
            print(f"[OK] Local model: {manual_dir}", flush=True)
            continue
        if offline:
            location = snapshot_download(model_id, cache_dir=str(cache), local_files_only=True)
        else:
            try:
                location = snapshot_download(model_id, cache_dir=str(cache), local_files_only=True)
            except Exception:
                print(f"[Download] {model_id}", flush=True)
                location = snapshot_download(model_id, cache_dir=str(cache))
        folder = Path(location)
        if not (folder / "model.pt").is_file():
            raise RuntimeError(f"ModelScope snapshot missing model.pt: {folder}")
        print(f"[OK] {model_id} => {folder}", flush=True)


def prepare_qwen(mode: str, offline: bool) -> None:
    repo_id, folder = QWEN_MODELS[mode]
    if complete_qwen(folder):
        print(f"[OK] Existing complete {repo_id}: {folder}", flush=True)
        return
    if offline:
        raise RuntimeError(f"{repo_id} is not complete at {folder}; import full snapshot manually.")
    print(f"[Download] {repo_id} => {folder}", flush=True)
    from huggingface_hub import snapshot_download
    snapshot_download(repo_id=repo_id, local_dir=str(folder))
    if not complete_qwen(folder):
        raise RuntimeError(
            f"Model download incomplete: {folder}. Existing files were preserved; "
            "verify the official snapshot and its cache metadata before retrying."
        )
    print(f"[OK] {repo_id}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("base", "aligner", "qwen-asr"), required=True)
    parser.add_argument("--offline", action="store_true", help="Verify locally available snapshots without network")
    opts = parser.parse_args()
    if opts.mode == "base":
        prepare_base(opts.offline)
    else:
        prepare_qwen(opts.mode, opts.offline)


if __name__ == "__main__":
    main()
