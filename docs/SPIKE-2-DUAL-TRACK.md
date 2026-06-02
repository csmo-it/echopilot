# Spike 2 — Dual Track Meeting Recording

Goal: record system audio and microphone at the same time, without BlackHole/Loopback and without a meeting bot.

## Run on Mac

```bash
git pull
swift run MeetingRecorder --seconds 30 --output-dir recordings/dual-test
```

During the run:
- play browser/meeting audio
- speak into the microphone

## Expected result

The output folder should contain:

- `system.m4a` — system/meeting audio
- `mic.caf` — microphone audio
- `manifest.json` — capture stats

Open both audio files. They should be audible and separate.

## Permissions

macOS may require both:

- `System Settings → Privacy & Security → Screen & System Audio Recording`
- `System Settings → Privacy & Security → Microphone`

Allow Terminal/iTerm/Xcode depending on where you run the command, then restart that app.

## Why separate files?

Separate tracks are easier to debug and later better for transcription:

- system track = other meeting participants
- mic track = Local speaker

We can mix later if needed, but separate is the right first proof.
