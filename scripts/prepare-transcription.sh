#!/usr/bin/env bash
set -euo pipefail

BUNDLE_DIR="${1:-}"
if [[ -z "$BUNDLE_DIR" ]]; then
  echo "Usage: scripts/prepare-transcription.sh recordings/dual-test" >&2
  exit 2
fi

if [[ ! -d "$BUNDLE_DIR" ]]; then
  echo "Bundle directory not found: $BUNDLE_DIR" >&2
  exit 2
fi

SYSTEM="$BUNDLE_DIR/system.m4a"
if [[ -f "$BUNDLE_DIR/mic.m4a" ]]; then
  MIC="$BUNDLE_DIR/mic.m4a"
else
  MIC="$BUNDLE_DIR/mic.caf"
fi
MANIFEST="$BUNDLE_DIR/manifest.json"
OUT="$BUNDLE_DIR/transcription-input"
mkdir -p "$OUT"

missing=0
for f in "$SYSTEM" "$MIC" "$MANIFEST"; do
  if [[ ! -f "$f" ]]; then
    echo "Missing: $f" >&2
    missing=1
  fi
done
[[ "$missing" -eq 0 ]] || exit 2

cp "$SYSTEM" "$OUT/system.m4a"
case "${MIC##*.}" in
  m4a) cp "$MIC" "$OUT/mic.m4a" ;;
  *) cp "$MIC" "$OUT/mic.caf" ;;
esac
cp "$MANIFEST" "$OUT/manifest.json"

cat > "$OUT/README.md" <<'MD'
# Transcription Input

This folder contains the two-track meeting capture:

- `system.m4a` — system/meeting audio, usually other participants
- `mic.m4a` or `mic.caf` — local microphone, usually the local speaker
- `manifest.json` — capture stats

## Quick manual transcription with MacWhisper

1. Open MacWhisper.
2. Import `system.m4a` and export transcript as `system.txt` plus timestamped `system.vtt` when available.
3. Import `mic.m4a` or `mic.caf` and export transcript as `mic.txt` plus timestamped `mic.vtt` when available.
4. Put the exported files into this folder.
5. Run `scripts/assemble-meeting-notes.sh <this-folder>` to generate `timeline.md` + KI-agent handover, or send the folder to a KI agent.

Keeping tracks separate helps with attribution:

- `system.txt` / `system.vtt` = other speakers / meeting audio
- `mic.txt` / `mic.vtt` = Local speaker

## Alignment note

Both tracks are captured from the same recording start. `scripts/assemble-meeting-notes.sh` merges timestamped `system.vtt` + `mic.vtt` into `timeline.md`; this is still two-source track alignment rather than perfect multi-speaker diarization.
MD

cat > "$OUT/summary-template.md" <<'MD'
# Meeting Summary Draft

## Metadata
- Source bundle:
- Date/time:
- Meeting title:
- Participants:
- Consent/recording notice given: yes/no

## Inputs
- System transcript: `system.txt` / `system.vtt`
- Mic transcript: `mic.txt` / `mic.vtt`

## Summary

## Decisions

## Action Items

| Owner | Task | Due | Approval needed? | task status |
|---|---|---|---|---|

## Open Questions

## Follow-ups for KI-Agent follow-up

MD

printf 'Prepared transcription folder:\n%s\n\n' "$OUT"
printf 'Next: transcribe system + mic, include .vtt timestamps when available, then run assemble-meeting-notes.sh to build timeline.md.\n'
