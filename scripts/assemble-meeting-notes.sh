#!/usr/bin/env bash
set -euo pipefail

INPUT_DIR="${1:-}"
if [[ -z "$INPUT_DIR" ]]; then
  echo "Usage: scripts/assemble-meeting-notes.sh recordings/dual-test/transcription-input" >&2
  exit 2
fi

SYSTEM="$INPUT_DIR/system.txt"
MIC="$INPUT_DIR/mic.txt"
SYSTEM_VTT="$INPUT_DIR/system.vtt"
MIC_VTT="$INPUT_DIR/mic.vtt"
TIMELINE="$INPUT_DIR/timeline.md"
OUT="$INPUT_DIR/meeting-notes-input.md"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for f in "$SYSTEM" "$MIC"; do
  if [[ ! -f "$f" ]]; then
    echo "Missing transcript: $f" >&2
    exit 2
  fi
done

system_vtt_block="Timestamped system transcript not available."
mic_vtt_block="Timestamped mic transcript not available."
if [[ -f "$SYSTEM_VTT" ]]; then
  system_vtt_block="$(cat "$SYSTEM_VTT")"
fi
if [[ -f "$MIC_VTT" ]]; then
  mic_vtt_block="$(cat "$MIC_VTT")"
fi

if [[ -f "$SYSTEM_VTT" || -f "$MIC_VTT" ]]; then
  python3 "$SCRIPT_DIR/build-timeline.py" "$INPUT_DIR" >/dev/null
fi

timeline_block="Timeline not available."
if [[ -f "$TIMELINE" ]]; then
  timeline_block="$(cat "$TIMELINE")"
fi

cat > "$OUT" <<MD
# Meeting Notes Input

## Speaker assumptions

- **Local speaker / microphone** comes from \`mic.txt\` / \`mic.vtt\`.
- **Other participants / system audio** comes from \`system.txt\` / \`system.vtt\`.
- Timestamped files use the same recording start as time base when available. Use timestamps to correlate both tracks, but treat this as two-source aligned input rather than perfect diarization.

## KI-agent output contract

Produce every section below. If the transcript contains no evidence for a section, write \`Keine im Transkript erkennbar\` instead of omitting it.

1. **Kurzfassung** — 5–10 concise German bullet points
2. **Entscheidungen** — decision, context, source/speaker, evidence quote or timestamp
3. **Offene Fragen** — question, context, source/speaker, evidence quote or timestamp
4. **Action Items** — task, owner, due date, status, evidence quote or timestamp
5. **Task-Vorschläge** — task title, risk, automation mode, next step
6. **Approval Gates** — anything external/customer-facing/destructive that needs approval
7. **Unklar / Daten fehlen** — contradictions, missing names, bad transcript spots

Do not invent decisions, questions, or tasks. Preserve uncertainty.

## Primary source: merged timeline

\`\`\`markdown
$timeline_block
\`\`\`

## Timestamped mic transcript — Local speaker/microphone

\`\`\`vtt
$mic_vtt_block
\`\`\`

## Timestamped system transcript — other/system audio

\`\`\`vtt
$system_vtt_block
\`\`\`

## Plain mic transcript — Local speaker/microphone

$(cat "$MIC")

## Plain system transcript — other/system audio

$(cat "$SYSTEM")
MD

printf 'Timeline:\n%s\n' "$TIMELINE"
printf 'Assembled KI-agent input:\n%s\n' "$OUT"
