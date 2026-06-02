# Spike 1 — System Audio Recording

Goal: prove that ScreenCaptureKit audio sample buffers can be written to a playable local file.

## Run on Mac

```bash
swift run SystemAudioRecorder --seconds 30
```

Or choose a file:

```bash
swift run SystemAudioRecorder --seconds 30 --output recordings/youtube-test.m4a
```

While it runs, play audio from a browser or meeting app.

## Expected result

- Terminal prints `buffers` and `appended` counts increasing.
- A `.m4a` file appears under `recordings/`.
- Opening that file in QuickTime/Music should play the system audio.

## If output file is silent or missing

Check:

1. macOS permission: `System Settings → Privacy & Security → Screen & System Audio Recording`
2. Terminal/iTerm/Xcode is allowed.
3. Restart the terminal after granting permission.
4. Audio was actually playing through the Mac during capture.

## Limitations

- System audio only.
- Microphone track comes in the next spike.
- No transcript yet.
