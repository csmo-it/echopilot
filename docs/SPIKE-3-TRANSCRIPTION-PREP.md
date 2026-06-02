# Spike 3 — Transcription Prep

Goal: turn a dual-track capture folder into a clean handoff for transcription and AI agent post-processing.

## Why this step

The recorder now creates:

- `system.m4a`
- `mic.caf`
- `manifest.json`

Before building full automatic transcription, we want a reliable manual path:

1. Capture meeting.
2. Prepare transcription folder.
3. Transcribe both tracks with MacWhisper.
4. Feed transcripts to AI agent for summary/action extraction.

## Run

```bash
scripts/prepare-transcription.sh recordings/dual-test
```

This creates:

```text
recordings/dual-test/transcription-input/
  README.md
  manifest.json
  mic.caf
  system.m4a
  summary-template.md
```

## Manual transcription path

Use MacWhisper:

- import `system.m4a` → export `system.txt`
- import `mic.caf` → export `mic.txt`

Put both files into `transcription-input/`.

## Next automation steps

- add optional local CLI transcription backend
- likely candidates:
  - WhisperKit
  - whisper.cpp
  - mlx-whisper on Apple Silicon
- create a merged, time-aware transcript
- summarize into notes/task management format
