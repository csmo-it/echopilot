# Spike 4 — Local Transcription Without MacWhisper Export

Goal: avoid the MacWhisper export paywall by transcribing the recorded tracks directly from the repo.

## Local backend

The first backend uses `openai-whisper` locally via Python.

Tradeoffs:
- ✅ simple and proven
- ✅ works offline after model download
- ✅ German supported
- ⚠️ requires `ffmpeg`
- ⚠️ speed depends on Mac model/model size

Later we can add Apple-Silicon-optimized backends:
- MLX Whisper
- WhisperKit
- whisper.cpp

## Install prerequisite

```bash
brew install ffmpeg
```

## Transcribe a recording bundle

```bash
git pull
scripts/transcribe-local-whisper.sh recordings/dual-test
```

Default model is `small`, language is German.

Optional:

```bash
WHISPER_MODEL=base scripts/transcribe-local-whisper.sh recordings/dual-test
WHISPER_MODEL=medium scripts/transcribe-local-whisper.sh recordings/dual-test
```

Outputs:

```text
recordings/dual-test/transcription-input/system.txt
recordings/dual-test/transcription-input/mic.txt
```

## Assemble for AI agent

```bash
scripts/assemble-meeting-notes.sh recordings/dual-test/transcription-input
```

Output:

```text
recordings/dual-test/transcription-input/meeting-notes-input.md
```

Send that file to AI agent, or paste its contents.
