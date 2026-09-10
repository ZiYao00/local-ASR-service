from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from typing import Any, Iterable


_STRONG_PUNCTUATION = set("。！？!?")
_MEDIUM_PUNCTUATION = set("，,；;：:")
_WEAK_PUNCTUATION = set("、")
_LEFT_ATTACH_PARTICLES = set("的地得了着过成到")


@dataclass(frozen=True)
class SubtitlePreset:
    name: str
    target_width: float
    max_width: float
    min_width: float
    min_duration: float
    target_duration: float
    max_duration: float
    soft_pause: float
    strong_pause: float


PRESETS: dict[str, SubtitlePreset] = {
    "voiceover": SubtitlePreset(
        name="voiceover",
        target_width=12.0,
        max_width=18.0,
        min_width=5.0,
        min_duration=0.75,
        target_duration=2.2,
        max_duration=4.0,
        soft_pause=0.20,
        strong_pause=0.45,
    ),
    "tutorial": SubtitlePreset(
        name="tutorial",
        target_width=16.0,
        max_width=24.0,
        min_width=6.0,
        min_duration=0.9,
        target_duration=2.8,
        max_duration=5.0,
        soft_pause=0.24,
        strong_pause=0.5,
    ),
}


@dataclass(frozen=True)
class MappedUnit:
    text: str
    start: float
    end: float
    source_start: int
    source_end: int


def _is_spoken_char(char: str) -> bool:
    if char == "'":
        return True
    category = unicodedata.category(char)
    return category.startswith("L") or category.startswith("N")


def spoken_key(text: str) -> str:
    """Return the surface used by Qwen3 Forced Aligner for transcript matching."""
    return "".join(char for char in text if _is_spoken_char(char)).casefold()


def display_width(text: str) -> float:
    """Approximate subtitle visual width in CJK-character units."""
    width = 0.0
    for char in text:
        if char.isspace():
            width += 0.25
        elif unicodedata.east_asian_width(char) in {"W", "F"}:
            width += 1.0
        elif _is_spoken_char(char):
            width += 0.55
        else:
            width += 0.4
    return width


def _clean_display_text(text: str) -> str:
    text = re.sub(r"\s+", " ", text).strip()
    return text


def _protected_word_boundaries(transcript: str) -> set[int]:
    """Return source offsets where a subtitle must not split a lexical token."""
    try:
        import jieba
    except ImportError:
        return set()

    protected: set[int] = set()
    for word, start, end in jieba.tokenize(transcript, mode="default"):
        if len(spoken_key(word)) <= 1:
            continue
        for offset in range(start + 1, end):
            protected.add(offset)
    return protected


def _preferred_word_boundaries(transcript: str) -> set[int]:
    """Return source offsets that end a tokenizer word and are safe soft-cut candidates."""
    try:
        import jieba
    except ImportError:
        return set()

    preferred: set[int] = set()
    for word, _start, end in jieba.tokenize(transcript, mode="default"):
        if spoken_key(word):
            preferred.add(end)
    return preferred


def _is_latin_token(text: str) -> bool:
    key = spoken_key(text)
    return bool(key) and any("a" <= char <= "z" for char in key)


def _is_cjk_singleton(text: str) -> bool:
    key = spoken_key(text)
    return len(key) == 1 and unicodedata.east_asian_width(key) in {"W", "F"}


def _boundary_is_protected(
    transcript: str,
    units: list[MappedUnit],
    index: int,
    protected_offsets: set[int],
    preset: SubtitlePreset,
) -> bool:
    if index + 1 >= len(units):
        return False
    current = units[index]
    following = units[index + 1]
    boundary_offset = following.source_start
    if boundary_offset in protected_offsets:
        return True

    trailer = transcript[current.source_end:following.source_start]
    punctuation = _STRONG_PUNCTUATION | _MEDIUM_PUNCTUATION | _WEAK_PUNCTUATION
    if any(char in punctuation for char in trailer):
        return False
    pause = max(0.0, following.start - current.end)
    following_key = spoken_key(following.text)
    if following_key in _LEFT_ATTACH_PARTICLES and pause < preset.soft_pause:
        return True
    # Keep common mixed-language compounds such as "Obsidian库" together when
    # the audio itself does not mark a boundary.
    return _is_latin_token(current.text) and _is_cjk_singleton(following.text) and pause < preset.soft_pause


def map_alignment_units(transcript: str, aligned_items: Iterable[dict[str, Any]]) -> list[MappedUnit]:
    items = list(aligned_items)
    if not transcript.strip():
        raise ValueError("Transcript is empty.")
    if not items:
        raise ValueError("Alignment contains no items.")

    content_positions = [index for index, char in enumerate(transcript) if _is_spoken_char(char)]
    transcript_key = "".join(transcript[index] for index in content_positions).casefold()

    unit_keys: list[str] = []
    for item in items:
        key = spoken_key(str(item.get("text") or ""))
        if not key:
            raise ValueError("Alignment contains an empty/non-spoken item.")
        unit_keys.append(key)

    aligned_key = "".join(unit_keys)
    if aligned_key != transcript_key:
        raise ValueError(
            "Forced-alignment items do not exactly cover the transcript surface. "
            f"transcript_chars={len(transcript_key)}, aligned_chars={len(aligned_key)}"
        )

    mapped: list[MappedUnit] = []
    offset = 0
    previous_end = -1.0
    for item, key in zip(items, unit_keys):
        key_length = len(key)
        source_start = content_positions[offset]
        source_end = content_positions[offset + key_length - 1] + 1
        start = float(item["start"])
        end = float(item["end"])
        if start < 0 or end < start:
            raise ValueError(f"Invalid alignment time range: {start} -> {end}")
        if start < previous_end - 1e-6:
            raise ValueError("Alignment times are not monotonic.")
        mapped.append(
            MappedUnit(
                text=str(item.get("text") or ""),
                start=start,
                end=end,
                source_start=source_start,
                source_end=source_end,
            )
        )
        previous_end = end
        offset += key_length

    return mapped


def _boundary_metadata(transcript: str, units: list[MappedUnit], index: int) -> tuple[int, float]:
    unit = units[index]
    next_start = units[index + 1].source_start if index + 1 < len(units) else len(transcript)
    trailer = transcript[unit.source_end:next_start]
    pause = max(0.0, units[index + 1].start - unit.end) if index + 1 < len(units) else 0.0

    if any(char in _STRONG_PUNCTUATION for char in trailer) or "\n\n" in trailer or "\r\n\r\n" in trailer:
        punctuation_strength = 3
    elif any(char in _MEDIUM_PUNCTUATION for char in trailer) or "\n" in trailer:
        punctuation_strength = 2
    elif any(char in _WEAK_PUNCTUATION for char in trailer):
        punctuation_strength = 1
    else:
        punctuation_strength = 0
    return punctuation_strength, pause


def _slice_text(transcript: str, units: list[MappedUnit], start_index: int, end_index: int) -> str:
    source_start = units[start_index].source_start
    source_end = units[end_index + 1].source_start if end_index + 1 < len(units) else len(transcript)
    return _clean_display_text(transcript[source_start:source_end])


def _candidate_score(
    transcript: str,
    units: list[MappedUnit],
    start_index: int,
    end_index: int,
    preset: SubtitlePreset,
) -> tuple[float, float, float, int, float]:
    text = _slice_text(transcript, units, start_index, end_index)
    width = display_width(text)
    duration = units[end_index].end - units[start_index].start
    punctuation_strength, pause = _boundary_metadata(transcript, units, end_index)

    natural = punctuation_strength * 3.0
    if pause >= preset.strong_pause:
        natural += 5.0
    elif pause >= preset.soft_pause:
        natural += 2.5

    width_fit = max(0.0, 2.5 - abs(width - preset.target_width) / max(preset.target_width, 1.0) * 2.5)
    duration_fit = max(
        0.0,
        1.5 - abs(duration - preset.target_duration) / max(preset.target_duration, 0.1) * 1.5,
    )
    score = natural + width_fit + duration_fit
    return score, width, duration, punctuation_strength, pause


def _make_cue(
    transcript: str,
    units: list[MappedUnit],
    start_index: int,
    end_index: int,
) -> dict[str, Any]:
    return {
        "start": round(units[start_index].start, 3),
        "end": round(units[end_index].end, 3),
        "text": _slice_text(transcript, units, start_index, end_index),
        "unit_start": start_index,
        "unit_end": end_index,
    }


def _choose_best(candidates: list[tuple[float, int]]) -> int | None:
    if not candidates:
        return None
    return max(candidates, key=lambda entry: (entry[0], entry[1]))[1]


def segment_aligned_transcript(
    transcript: str,
    aligned_items: Iterable[dict[str, Any]],
    preset: str | SubtitlePreset = "voiceover",
) -> list[dict[str, Any]]:
    if isinstance(preset, str):
        if preset not in PRESETS:
            raise ValueError(f"Unknown subtitle preset: {preset}")
        selected = PRESETS[preset]
    else:
        selected = preset

    units = map_alignment_units(transcript, aligned_items)
    protected_offsets = _protected_word_boundaries(transcript)
    preferred_offsets = _preferred_word_boundaries(transcript)
    cues: list[dict[str, Any]] = []
    start_index = 0

    while start_index < len(units):
        natural_candidates: list[tuple[float, int]] = []
        lexical_candidates: list[tuple[float, int]] = []
        cut_index: int | None = None

        for end_index in range(start_index, len(units)):
            score, width, duration, punctuation_strength, pause = _candidate_score(
                transcript, units, start_index, end_index, selected
            )
            protected = _boundary_is_protected(
                transcript, units, end_index, protected_offsets, selected
            )
            word_boundary = units[end_index].source_end in preferred_offsets
            readable = width >= selected.min_width or duration >= selected.min_duration
            natural_boundary = punctuation_strength > 0 or pause >= selected.soft_pause

            if readable and not protected and natural_boundary:
                natural_candidates.append((score, end_index))
            if readable and not protected and word_boundary:
                lexical_candidates.append((score, end_index))

            if not protected and punctuation_strength >= 3 and duration >= 0.5:
                cut_index = end_index
                break
            if not protected and pause >= selected.strong_pause and duration >= 0.6:
                cut_index = end_index
                break

            reached_target = width >= selected.target_width or duration >= selected.target_duration
            if reached_target and natural_candidates:
                best = _choose_best(natural_candidates)
                if best is not None:
                    _, _, _, best_punctuation, best_pause = _candidate_score(
                        transcript, units, start_index, best, selected
                    )
                    if best_punctuation >= 2 or best_pause >= selected.soft_pause:
                        cut_index = best
                        break

            if width >= selected.max_width or duration >= selected.max_duration:
                best = _choose_best(natural_candidates)
                if best is None:
                    best = _choose_best(lexical_candidates)
                if best is not None:
                    cut_index = best
                    break
                if not protected:
                    cut_index = end_index
                    break
                # A protected word may exceed the soft maximum. Give it a small
                # emergency window so we can finish the word instead of cutting it.
                if width >= selected.max_width * 1.35 or duration >= selected.max_duration * 1.3:
                    cut_index = end_index
                    break

        if cut_index is None:
            cut_index = len(units) - 1

        cues.append(_make_cue(transcript, units, start_index, cut_index))
        start_index = cut_index + 1

    return _merge_tiny_cues(cues, selected)


def _merge_tiny_cues(cues: list[dict[str, Any]], preset: SubtitlePreset) -> list[dict[str, Any]]:
    if len(cues) < 2:
        return cues

    merged: list[dict[str, Any]] = []
    index = 0
    while index < len(cues):
        cue = dict(cues[index])
        duration = float(cue["end"]) - float(cue["start"])
        width = display_width(str(cue["text"]))
        tiny = duration < preset.min_duration * 0.7 or width < preset.min_width * 0.6

        if tiny and index + 1 < len(cues):
            following = cues[index + 1]
            combined_text = _clean_display_text(f"{cue['text']} {following['text']}")
            combined_duration = float(following["end"]) - float(cue["start"])
            if display_width(combined_text) <= preset.max_width * 1.25 and combined_duration <= preset.max_duration * 1.2:
                cue["end"] = following["end"]
                cue["text"] = combined_text
                cue["unit_end"] = following["unit_end"]
                merged.append(cue)
                index += 2
                continue

        merged.append(cue)
        index += 1

    return merged


def _format_timestamp(seconds: float) -> str:
    milliseconds = max(0, int(round(seconds * 1000.0)))
    hours, remainder = divmod(milliseconds, 3_600_000)
    minutes, remainder = divmod(remainder, 60_000)
    secs, millis = divmod(remainder, 1000)
    return f"{hours:02d}:{minutes:02d}:{secs:02d},{millis:03d}"


def format_srt(cues: Iterable[dict[str, Any]]) -> str:
    blocks: list[str] = []
    for index, cue in enumerate(cues, start=1):
        start = _format_timestamp(float(cue["start"]))
        end = _format_timestamp(float(cue["end"]))
        text = str(cue["text"]).strip()
        blocks.append(f"{index}\r\n{start} --> {end}\r\n{text}")
    return "\r\n\r\n".join(blocks) + "\r\n"


def summarize_cues(cues: Iterable[dict[str, Any]]) -> dict[str, Any]:
    cue_list = list(cues)
    if not cue_list:
        return {"cue_count": 0}
    durations = [float(cue["end"]) - float(cue["start"]) for cue in cue_list]
    widths = [display_width(str(cue["text"])) for cue in cue_list]
    return {
        "cue_count": len(cue_list),
        "min_duration": round(min(durations), 3),
        "max_duration": round(max(durations), 3),
        "average_duration": round(sum(durations) / len(durations), 3),
        "max_display_width": round(max(widths), 2),
        "average_display_width": round(sum(widths) / len(widths), 2),
    }
