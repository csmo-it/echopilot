#!/usr/bin/env bash
set -euo pipefail

APP="${1:-/Applications/EchoPilot.app}"

if [[ ! -d "$APP" ]]; then
  echo "App not found: $APP" >&2
  echo "Usage: scripts/diagnose-echopilot-app.sh [/path/to/EchoPilot.app]" >&2
  exit 2
fi

PLIST="$APP/Contents/Info.plist"
EXE="$APP/Contents/MacOS/EchoPilot"

echo "App: $APP"
echo "Bundle ID: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || echo '<missing>')"
echo "Executable: $EXE"
echo

echo "Info.plist privacy strings:"
/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$PLIST" 2>/dev/null | sed 's/^/  Microphone: /' || echo "  Microphone: <missing>"
/usr/libexec/PlistBuddy -c 'Print :NSScreenCaptureUsageDescription' "$PLIST" 2>/dev/null | sed 's/^/  Screen: /' || echo "  Screen: <missing>"
echo

echo "Code signature:"
codesign -dv --verbose=4 "$APP" 2>&1 | sed -n '1,30p' || true
echo

echo "Designated requirement:"
codesign -dr - "$APP" 2>&1 || true
echo

echo "Entitlements:"
codesign -d --entitlements :- "$APP" 2>/dev/null || true
