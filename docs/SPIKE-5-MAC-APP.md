# Spike 5 — Native macOS App

Goal: stop using Terminal as the product surface.

## What this adds

`EchoPilotApp` is a minimal SwiftUI macOS app target inside the Swift Package.

It provides:

- Start Recording / Stop Recording buttons
- recording status and elapsed timer
- live audio level meters for system + mic tracks with faster refresh and calibrated dBFS mapping
- microphone/input device selector
- automatic preparation into `transcription-input/` after Stop
- visible preparation/conversion progress
- GUI `Transkribieren` button that runs local Whisper scripts and assembles `meeting-notes-input.md`
- meeting library/sidebar with previous recordings
- meeting metadata fields: title, participants, customer/project, consent checkbox, with autosave for existing meetings
- Whisper model/language settings with installed-model detection from `~/.cache/whisper`
- local summary draft and AI-agent export package buttons
- `Neue Aufnahme` flow so users can prepare metadata before recording
- optional call suggestion banner for likely meeting windows
- output folder button
- consent reminder
- default output under `~/Documents/EchoPilot/meeting-<timestamp>/`

Each recording creates:

```text
system.m4a
mic.m4a
manifest.json
```

## Run in Xcode

```bash
open Package.swift
```

In Xcode:

1. Select scheme `EchoPilotApp`.
2. Press Run.
3. Grant permissions if prompted:
   - Microphone
   - Screen & System Audio Recording
4. Choose the desired microphone/input device.
5. Click **Start Recording**.
6. Play meeting/browser audio and speak into the mic.
7. Click **Stop Recording**.
8. Watch the post-processing progress.
9. Click **Output-Ordner öffnen** or **Transcription-Input öffnen**.

If permissions are missing:

- `System Settings → Privacy & Security → Microphone`
- `System Settings → Privacy & Security → Screen & System Audio Recording`

Allow Xcode, then restart Xcode and rerun.

## Current limitations

- This stays an internal development app for now; running from Xcode is acceptable, no signing/DMG milestone currently planned.
- No menu bar mode yet.
- Built-in `Transkribieren` button requires `ffmpeg`, Python, and first-run model/dependency download.
- Tracks remain separate, intentionally, for debugging and attribution.
- Direct notes/task management writes are not embedded in the Mac app yet; **Für KI-Agent exportieren** creates a local handoff file instead, so AI agent can create notes/task management objects with proper approvals.
- **Zusammenfassung erstellen** creates a structured local draft/template from the transcript. Final semantic summary/action extraction should happen through AI agent/export until a local LLM backend is chosen.

## Next app steps

1. Add a real local/remote LLM backend for semantic summary/action extraction, or wire the export flow to AI-agent ingestion.
2. Add menu bar mode if the internal app becomes a daily driver.
3. Improve detailed Whisper progress reporting beyond latest log line.
4. Keep internal/Xcode workflow for now; revisit packaging only if external distribution becomes necessary.


## Transcription button

After recording stops, the app prepares `transcription-input/` quickly. This is not transcription yet.

To transcribe inside the app:

1. Ensure `ffmpeg` is installed (`brew install ffmpeg`).
2. Click **Transkribieren**.
3. First run may take longer because Python dependencies and the Whisper model are installed/downloaded.
4. When finished, `meeting-notes-input.md` is rewritten with the transcript content via the existing local scripts.

If it fails, the GUI status should show the shell/script error. Common causes:

- `ffmpeg` missing
- no internet on first model/dependency install
- Python/venv creation failed
- Xcode app cannot access the repo path after moving the checkout


## Meeting/call detection

EchoPilot can suggest a recording when it sees a likely meeting/call window from Teams, Zoom, Webex, Slack, or browser-based Meet. For Microsoft Teams on macOS, it also checks local Teams log markers when available.

Important:

- This is heuristic: local Teams log markers first, then visible app/window titles via ScreenCaptureKit.
- macOS/Teams do not expose a reliable public local "Teams call started" API for normal desktop apps; Teams logs are best-effort and may change.
- EchoPilot never starts recording automatically.
- The user still has to confirm consent and click Start Recording.
