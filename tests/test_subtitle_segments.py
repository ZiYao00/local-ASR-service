import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from service.subtitles import format_srt, map_alignment_units, segment_aligned_transcript, spoken_key


def _item(text: str, start: float, end: float) -> dict[str, object]:
    return {"text": text, "start": start, "end": end}


def test_hyphenated_name_is_restored_from_transcript() -> None:
    transcript = "项目bili-learning-automation：丢进去。"
    items = [
        _item("项", 0.0, 0.2),
        _item("目", 0.2, 0.4),
        _item("bililearningautomation", 0.4, 1.2),
        _item("丢", 1.5, 1.7),
        _item("进", 1.7, 1.9),
        _item("去", 1.9, 2.1),
    ]
    mapped = map_alignment_units(transcript, items)
    assert len(mapped) == len(items)
    cues = segment_aligned_transcript(transcript, items, "voiceover")
    rendered = "".join(str(cue["text"]) for cue in cues)
    assert "bili-learning-automation" in rendered
    assert spoken_key(rendered) == spoken_key(transcript)


def test_punctuation_and_pause_create_readable_cues() -> None:
    transcript = "今天开始。接着继续，最后结束。"
    chars = [char for char in transcript if spoken_key(char)]
    items = []
    cursor = 0.0
    for char in chars:
        start = cursor
        end = start + 0.18
        items.append(_item(char, start, end))
        cursor = end
        if char in {"始", "续"}:
            cursor += 0.5 if char == "始" else 0.28

    cues = segment_aligned_transcript(transcript, items, "voiceover")
    assert len(cues) >= 2
    assert spoken_key("".join(str(cue["text"]) for cue in cues)) == spoken_key(transcript)
    assert all(float(cue["end"]) >= float(cue["start"]) for cue in cues)
    assert all(float(cues[index]["start"]) >= float(cues[index - 1]["end"]) for index in range(1, len(cues)))


def test_word_boundaries_are_not_split() -> None:
    transcript = "这是可永久存储的Obsidian库，也是重要知识点。"
    spoken = [char for char in transcript if spoken_key(char)]
    items = []
    cursor = 0.0
    index = 0
    while index < len(spoken):
        if "".join(spoken[index:index + 8]).casefold() == "obsidian":
            items.append(_item("Obsidian", cursor, cursor + 0.56))
            cursor += 0.56
            index += 8
            continue
        items.append(_item(spoken[index], cursor, cursor + 0.18))
        cursor += 0.18
        index += 1

    cues = segment_aligned_transcript(transcript, items, "voiceover")
    rendered = [str(cue["text"]) for cue in cues]
    assert not any(text.endswith("存") for text in rendered)
    assert not any(text.endswith("知") or text.endswith("知识") for text in rendered)
    assert not any(text.endswith("Obsidian") for text in rendered)
    assert spoken_key("".join(rendered)) == spoken_key(transcript)


def test_surface_mismatch_is_rejected() -> None:
    transcript = "正确文稿。"
    items = [_item("错", 0.0, 0.2), _item("误", 0.2, 0.4)]
    try:
        map_alignment_units(transcript, items)
    except ValueError as exc:
        assert "do not exactly cover" in str(exc)
    else:
        raise AssertionError("Expected transcript/alignment mismatch to fail.")


def test_srt_format() -> None:
    srt = format_srt([
        {"start": 1.04, "end": 2.32, "text": "第一条"},
        {"start": 2.4, "end": 3.6, "text": "第二条"},
    ])
    assert "00:00:01,040 --> 00:00:02,320" in srt
    assert "\r\n\r\n2\r\n" in srt


def main() -> None:
    test_hyphenated_name_is_restored_from_transcript()
    test_punctuation_and_pause_create_readable_cues()
    test_word_boundaries_are_not_split()
    test_surface_mismatch_is_rejected()
    test_srt_format()
    print("subtitle segmentation: passed")


if __name__ == "__main__":
    main()
