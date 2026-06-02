# Architecture Notes

## Capture strategy

Preferred route: native macOS capture using ScreenCaptureKit for system audio.

Why:
- avoids BlackHole/Loopback/OBS routing
- no meeting bot joins the call
- matches the UX direction of tools like notes/Granola

Initial split:

```text
System audio ── ScreenCaptureKit ─┐
                                  ├─ local recording/transcription pipeline
Microphone ─── AVAudioEngine ─────┘
```

Keep tracks separate first. Mixing can come later.

## Pipeline target

```text
recording
  → transcript
  → meeting summary
  → decisions
  → action items
  → task management / notes app
```

## Privacy posture

- User-controlled Start/Stop only.
- No covert recording.
- Local storage first.
- Explicit export/sync step.
- Task actions still obey approval gates.
