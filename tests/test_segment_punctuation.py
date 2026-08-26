import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from service.engine import _alignment_key, _map_punctuation_to_segments


def main() -> None:
    full = "第一句话，已经完成。第二句话？也完成了！MiniMax-H3 workflow, works."
    segments = ["第一句话已经完成", "第二句话", "也完成了", "MiniMax-H3 workflow works"]
    mapped = _map_punctuation_to_segments(full, segments)
    assert mapped is not None
    assert len(mapped) == len(segments)
    assert "，" in mapped[0] and "。" in mapped[0]
    assert mapped[1].endswith("？")
    assert mapped[2].endswith("！")
    assert "," in mapped[3] and mapped[3].endswith(".")
    assert "".join(_alignment_key(item) for item in mapped) == _alignment_key(full)

    case_mapped = _map_punctuation_to_segments("Recs，已完成。", ["recs已完成"])
    assert case_mapped == ["Recs，已完成。"]

    mismatch = _map_punctuation_to_segments("完全不同。", ["无法对齐"])
    assert mismatch is None
    print("segment punctuation mapping: passed")


if __name__ == "__main__":
    main()
