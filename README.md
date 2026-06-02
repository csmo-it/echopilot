# EchoPilot

EchoPilot is a native macOS meeting-capture app for recording system audio and microphone audio into separate local tracks, preparing transcripts, and exporting structured handoff notes for AI-assisted review.

It is designed for local-first meeting workflows: record only after consent, transcribe locally, review transcripts in-app, then export summaries, decisions, questions, and action items.

## Features

- Native macOS system-audio capture via ScreenCaptureKit
- Selected microphone recording
- Separate `system` and `mic` audio tracks
- Startup permission overlay for microphone and Screen/System Audio Recording
- Live level meters for both tracks
- Meeting history sidebar
- Conservative meeting/call suggestion banner for Teams, Zoom, Webex, Meet, and similar services
- Local Whisper transcription with Apple Silicon/MPS auto-detect and CPU fallback
- Timestamped transcript outputs (`txt`, `vtt`, `srt`, `tsv`, `json`)
- Merged two-track `timeline.md`
- In-app transcript viewer for timeline, AI handoff, system transcript, and microphone transcript
- Local summary draft generation
- AI-agent export package for downstream review/task extraction
- macOS Share Sheet actions for summaries, AI exports, and transcript files
- App icon and menu bar status item

## Requirements

- macOS with ScreenCaptureKit support
- Xcode for building from source
- Homebrew `ffmpeg` for local transcription
- Python 3 for the Whisper helper environment

Install ffmpeg:

```bash
brew install ffmpeg
```

## Run from source

Open the Xcode project:

```bash
open EchoPilot.xcodeproj
```

Select scheme `EchoPilot`, destination `My Mac`, and press Run. Use the target's **Signing & Capabilities** tab to select a Team if Xcode asks for signing.

For reliable macOS permissions/TCC testing, use a stable installed app copy instead of launching from Xcode/DerivedData:

```bash
scripts/install-echopilot-app.sh
open "/Applications/EchoPilot.app"
```

The app installs into `/Applications` by default and refreshes LaunchServices so Finder/Dock can pick up updated bundle metadata and icons. It also has a menu bar status item; use **EchoPilot anzeigen** from that menu to bring a minimized/hidden window back.

## CLI helpers

The Swift Package (`Package.swift`) is still available for low-level CLI diagnostics and capture tests.

Probe buffer capture:

```bash
swift run SystemAudioProbe --seconds 10
```

Record system audio to a file:

```bash
swift run SystemAudioRecorder --seconds 30
```

Dual-track recording:

```bash
swift run MeetingRecorder --seconds 30 --output-dir recordings/dual-test
```

Prepare a dual-track recording for transcription:

```bash
scripts/prepare-transcription.sh recordings/dual-test
```

Run local transcription:

```bash
scripts/transcribe-local-whisper.sh recordings/dual-test
scripts/assemble-meeting-notes.sh recordings/dual-test/transcription-input
```

Build a `.app` bundle for local/internal use:

```bash
scripts/build-echopilot-app.sh
open build/app/EchoPilot.app
```

## Apple Silicon transcription performance

EchoPilot assumes Apple Silicon for local transcription optimization:

- default model for new installs is `turbo`
- `scripts/transcribe-local-whisper.sh` auto-detects PyTorch MPS and passes `--device mps`
- MPS uses `fp16=False` by default for better stability
- if MPS fails once, the current and remaining tracks switch to CPU fallback
- dependency installation is skipped on normal runs once the Whisper virtual environment exists
- set `ECHOPILOT_UPDATE_WHISPER_DEPS=1` only when intentionally updating Whisper dependencies
- set `WHISPER_DEVICE=cpu` to force CPU fallback

`large-v3` is still available for difficult audio, but it is expected to be slower because EchoPilot transcribes both `system` and `mic` tracks.

## macOS permissions

EchoPilot needs both permissions:

- **Microphone**
- **Screen & System Audio Recording** / Screen Recording

On startup, EchoPilot shows a permission overlay that checks both permissions and offers request/settings actions before recording starts. The app also has a **Berechtigungen prüfen** button to reopen this check.

The Xcode app target signs with `Xcode/EchoPilot/EchoPilot.entitlements`, including `com.apple.security.device.audio-input`, so microphone TCC can attach to the app under Hardened Runtime.

If recording start says TCC was declined, reset the screen-capture decision and launch EchoPilot again:

```bash
tccutil reset ScreenCapture com.echopilot.app
```

If you run directly from Xcode and the prompt still does not appear, reset all ScreenCapture decisions once and retry:

```bash
tccutil reset ScreenCapture
```

Then open the stable installed app (`/Applications/EchoPilot.app`), start a recording, and approve the macOS permission prompt. Avoid switching between Xcode Run, `build/app`, and the installed app while testing permissions because macOS TCC stores permissions against the app identity/signature.

Bundle identifier: `com.echopilot.app`.

Diagnostics:

```bash
scripts/diagnose-echopilot-app.sh "/Applications/EchoPilot.app"
```

## Meeting/call detection

EchoPilot can suggest a recording when it sees a likely meeting/call window from Teams, Zoom, Webex, Slack, or browser-based Meet. For Microsoft Teams on macOS, it also checks local Teams log markers when available.

Important:

- Detection is heuristic: local Teams log markers first, then visible app/window titles via ScreenCaptureKit.
- macOS/Teams do not expose a reliable public local “call started” API for normal desktop apps.
- EchoPilot never starts recording automatically.
- The user still has to confirm consent and click Start Recording.

## Update notifications

On startup, EchoPilot checks the public GitHub Releases endpoint for the latest non-draft release:

```text
https://api.github.com/repos/csmo-it/echopilot/releases/latest
```

If the latest release tag, for example `v0.1.1`, is newer than the installed app version, EchoPilot shows an in-app banner with a link to the GitHub Release page. Dismissing the banner stores only the dismissed version in local `UserDefaults`, so the same release does not nag repeatedly. A newer release will show again.

This is an update notification only; EchoPilot does not download, install, or run updates automatically.

## Versioning

EchoPilot reads its installed app version from `CFBundleShortVersionString`, which is generated from Xcode's `MARKETING_VERSION`. The internal build number comes from `CURRENT_PROJECT_VERSION`.

Use the helper script instead of editing the Xcode project by hand:

```bash
scripts/set-echopilot-version.sh 0.1.1
```

This updates `MARKETING_VERSION` and increments `CURRENT_PROJECT_VERSION`. You can also set the build number explicitly:

```bash
scripts/set-echopilot-version.sh 0.1.1 2
```

For GitHub Releases, tag releases with the same public version, usually prefixed with `v`, for example `v0.1.1`. EchoPilot's startup update check compares that release tag against the installed app version.

## Publishing and releases

- See [`docs/PUBLICATION.md`](docs/PUBLICATION.md) before making a repository public.
- See [`docs/RELEASES.md`](docs/RELEASES.md) for build/release distribution guidance.
