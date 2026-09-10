import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from service.alignment import (
    classify_script_match,
    normalize_aligner_language,
    script_match_score,
)


def main() -> None:
    assert script_match_score("B站学习笔记", "B站学习笔记") == 1.0
    assert script_match_score("Obsidian学习笔记。", "obsidian 学习笔记") == 1.0
    assert script_match_score("完全不同的原稿", "另一段无关内容") < 0.5

    assert classify_script_match(0.95) == "pass"
    assert classify_script_match(0.80) == "warning"
    assert classify_script_match(0.20) == "fail"

    assert normalize_aligner_language("zh") == "Chinese"
    assert normalize_aligner_language("Chinese") == "Chinese"
    assert normalize_aligner_language("en") == "English"
    assert normalize_aligner_language("Japanese") == "Japanese"
    print("alignment QA helpers: passed")


if __name__ == "__main__":
    main()
