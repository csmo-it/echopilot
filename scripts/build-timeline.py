#!/usr/bin/env python3
"""Build a simple two-track meeting timeline from Whisper VTT files.

Input files are expected to share the same recording start time:
- mic.vtt    -> local microphone / Local speaker
- system.vtt -> system audio / other participants

This intentionally does not perform diarization. It labels by track only.
"""
from __future__ import annotations

import argparse
import html
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

TIMING_RE = re.compile(
    r"(?P<start>\d{2}:\d{2}:\d{2}[.,]\d{3})\s+-->\s+(?P<end>\d{2}:\d{2}:\d{2}[.,]\d{3})"
)
TAG_RE = re.compile(r"<[^>]+>")


@dataclass(order=True)
class Segment:
    start_seconds: float
    end_seconds: float
    track: str
    speaker: str
    text: str


def parse_timestamp(value: str) -> float:
    value = value.replace(",", ".")
    hours, minutes, seconds = value.split(":")
    return int(hours) * 3600 + int(minutes) * 60 + float(seconds)


def format_timestamp(seconds: float) -> str:
    total_ms = max(0, int(round(seconds * 1000)))
    hours, rem = divmod(total_ms, 3_600_000)
    minutes, rem = divmod(rem, 60_000)
    secs, ms = divmod(rem, 1000)
    if hours:
        return f"{hours:02d}:{minutes:02d}:{secs:02d}.{ms:03d}"
    return f"{minutes:02d}:{secs:02d}.{ms:03d}"


def clean_text(lines: Iterable[str]) -> str:
    text = " ".join(line.strip() for line in lines if line.strip())
    text = TAG_RE.sub("", text)
    text = html.unescape(text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def parse_vtt(path: Path, track: str, speaker: str) -> list[Segment]:
    if not path.exists():
        return []

    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    segments: list[Segment] = []
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        match = TIMING_RE.search(line)
        if not match:
            i += 1
            continue

        start = parse_timestamp(match.group("start"))
        end = parse_timestamp(match.group("end"))
        i += 1
        text_lines: list[str] = []
        while i < len(lines) and lines[i].strip():
            text_lines.append(lines[i])
            i += 1
        text = clean_text(text_lines)
        if text:
            segments.append(Segment(start, end, track, speaker, text))
        i += 1
    return segments


def build_timeline(input_dir: Path) -> tuple[str, int]:
    segments = []
    segments.extend(parse_vtt(input_dir / "mic.vtt", "mic", "Local speaker"))
    segments.extend(parse_vtt(input_dir / "system.vtt", "system", "Andere"))
    segments.sort(key=lambda item: (item.start_seconds, item.end_seconds, item.track))

    out: list[str] = [
        "# EchoPilot Timeline",
        "",
        "## Hinweis",
        "",
        "- Diese Timeline merged `mic.vtt` und `system.vtt` nach Zeitstempeln.",
        "- `mic/Local speaker` ist lokale Mikrofonspur; `system/Andere` ist Systemaudio mit allen anderen Teilnehmern.",
        "- Keine echte Multi-Speaker-Diarization: mehrere Personen auf der Systemspur bleiben zusammengefasst.",
        "",
        "## Timeline",
        "",
    ]

    if not segments:
        out.append("_Keine timestamped VTT-Segmente gefunden. Bitte erst transkribieren._")
        return "\n".join(out) + "\n", 0

    for segment in segments:
        out.append(
            f"- `{format_timestamp(segment.start_seconds)}–{format_timestamp(segment.end_seconds)}` "
            f"**[{segment.track}/{segment.speaker}]** {segment.text}"
        )

    return "\n".join(out) + "\n", len(segments)


def main() -> int:
    parser = argparse.ArgumentParser(description="Build timeline.md from mic.vtt + system.vtt")
    parser.add_argument("input_dir", help="transcription-input directory")
    parser.add_argument("--output", help="output timeline path; defaults to <input_dir>/timeline.md")
    args = parser.parse_args()

    input_dir = Path(args.input_dir).expanduser().resolve()
    output = Path(args.output).expanduser().resolve() if args.output else input_dir / "timeline.md"
    timeline, count = build_timeline(input_dir)
    output.write_text(timeline, encoding="utf-8")
    print(f"Timeline written: {output} ({count} segments)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
