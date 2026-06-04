# EchoPilot

EchoPilot is a native macOS meeting-capture app for recording system audio and microphone audio into separate local tracks, preparing transcripts, and exporting structured handoff notes for AI-assisted review.

It is designed for local-first meeting workflows: record only after consent, transcribe locally, review transcripts in-app, then export summaries, decisions, questions, and action items.

## Features

- Native macOS system-audio capture via ScreenCaptureKit
- Selected microphone recording
- Separate `system` and `mic` audio tracks
- Startup setup overlay for microphone, Screen/System Audio Recording, Homebrew, and FFmpeg
- AppKit-backed live level meters for both tracks, isolated from the main SwiftUI refresh loop
- Meeting history sidebar
- Meeting status panel with app-agnostic mic/camera activity detection
- Best-effort meeting context detection for Teams, Zoom, Webex, Meet, Slack, and browser meetings
- Microsoft Teams title/visible-participant detection via local Accessibility data when permission is granted
- Transcript status indicators and archive/unarchive controls in the meeting sidebar
- Local Whisper transcription with Apple Silicon/MPS auto-detect and CPU fallback
- Batch transcription for all untranscribed meetings, with manual, idle-time, and daily scheduled triggers
- Timestamped transcript outputs (`txt`, `vtt`, `srt`, `tsv`, `json`)
- Merged two-track `timeline.md`
- Lightweight in-app transcript viewer for timeline, AI handoff, system transcript, and microphone transcript
- Local summary draft generation
- AI-agent export package for downstream review/task extraction
- Shared AI-agent export collection folder at `~/Documents/EchoPilot/AI Agent Exports`
- macOS Share Sheet actions for summaries, AI exports, and transcript files
- App icon and menu bar status item

## Requirements

- macOS with ScreenCaptureKit support
- Xcode for building from source
- Homebrew and `ffmpeg` for local transcription
- Python 3 for the Whisper helper environment

EchoPilot checks Homebrew and FFmpeg at startup. If either tool is missing, the in-app setup panel offers install buttons that open the matching Homebrew commands in Terminal so the user can review and approve the installation.

Manual FFmpeg install:

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

## Batch transcription and exports

EchoPilot can transcribe every untranscribed meeting from the meeting library in one serial batch. Batch transcription uses the same local Whisper settings as a single meeting and includes archived meetings, because archive status only hides meetings from the default sidebar view.

Available modes:

- click **Alle offenen transkribieren** / **Transcribe All Open** to start immediately
- enable idle mode to run once the Mac has had no keyboard/mouse activity for the configured number of minutes
- enable the daily schedule to run once per day at the selected local time

Automatic batch runs do not start while EchoPilot is recording, already transcribing, post-processing a recording, or when local mic/camera signals suggest an active call. A running batch can be cancelled from the transcription controls.

For downstream agent work, **KI-Exports sammeln** / **Collect AI Exports** creates or refreshes AI-agent exports for transcribed meetings and copies them into:

```text
~/Documents/EchoPilot/AI Agent Exports
```

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

EchoPilot shows meeting status when local device signals suggest an active call. It uses microphone and camera activity as the primary app-agnostic signal, then enriches that status with best-effort context from Teams, Zoom, Webex, Slack, browser-based Meet, visible window titles, and local Teams log markers.

For Microsoft Teams on macOS, EchoPilot can also use Accessibility data when the user has granted permission. In that mode it tries to read the current meeting title and visible participant names from the local Teams window and pre-fill the recording metadata. If Accessibility is not trusted, unavailable, or Teams does not expose the relevant fields, EchoPilot falls back to the lower-level device/window/log signals.

Important:

- Detection is heuristic: device activity is reliable for "something is using mic/camera", while app names, titles, and participants are best effort.
- macOS/Teams do not expose a reliable public local "call started with full meeting metadata" API for normal desktop apps.
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
