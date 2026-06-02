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
RESOURCES="$APP/Contents/Resources"
ICON_FILE="$RESOURCES/EchoPilot.icns"
ASSETS_CAR="$RESOURCES/Assets.car"

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || echo '<missing>'
}

echo "App: $APP"
echo "Bundle ID: $(plist_value CFBundleIdentifier)"
echo "Executable: $EXE"
echo

echo "Icon metadata:"
echo "  CFBundleIconName: $(plist_value CFBundleIconName)"
echo "  CFBundleIconFile: $(plist_value CFBundleIconFile)"
if [[ -f "$ICON_FILE" ]]; then
  echo "  EchoPilot.icns: present ($(wc -c < "$ICON_FILE" | tr -d ' ') bytes)"
  if command -v iconutil >/dev/null 2>&1; then
    TMP_ICONSET="$(mktemp -d)/EchoPilot.iconset"
    if iconutil -c iconset "$ICON_FILE" -o "$TMP_ICONSET" >/dev/null 2>&1; then
      echo "  iconutil validation: ok"
      find "$TMP_ICONSET" -type f -maxdepth 1 -print | sed 's/^/    /' | sort
    else
      echo "  iconutil validation: FAILED"
    fi
  fi
else
  echo "  EchoPilot.icns: MISSING at $ICON_FILE"
fi
if [[ -f "$ASSETS_CAR" ]]; then
  echo "  Assets.car: present ($(wc -c < "$ASSETS_CAR" | tr -d ' ') bytes)"
else
  echo "  Assets.car: missing"
fi
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

echo
cat <<'HINT'
If the icon metadata is correct but Finder/Dock still show a generic icon, run:
  touch /Applications/EchoPilot.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u /Applications/EchoPilot.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/EchoPilot.app
  killall Dock
HINT
