#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
PRODUCT="EchoPilotApp"
APP_NAME="EchoPilot.app"
OUT_DIR="$ROOT/build/app"
APP_DIR="$OUT_DIR/$APP_NAME"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
PROJECT_FILE="$ROOT/EchoPilot.xcodeproj/project.pbxproj"

app_version() {
  grep -m1 'MARKETING_VERSION = ' "$PROJECT_FILE" | sed -E 's/.*MARKETING_VERSION = "?([^";]+)"?;.*/\1/'
}

build_number() {
  grep -m1 'CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | sed -E 's/.*CURRENT_PROJECT_VERSION = "?([^";]+)"?;.*/\1/'
}

APP_VERSION="${APP_VERSION:-$(app_version)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(build_number)}"

cd "$ROOT"

swift build -c "$CONFIG" --product "$PRODUCT"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$PRODUCT"

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN_PATH" "$MACOS/EchoPilot"
chmod +x "$MACOS/EchoPilot"
cp "$ROOT/Xcode/EchoPilot/EchoPilot.icns" "$RESOURCES/EchoPilot.icns"
mkdir -p "$RESOURCES/scripts"
cp "$ROOT/scripts/transcribe-local-whisper.sh" "$RESOURCES/scripts/transcribe-local-whisper.sh"
cp "$ROOT/scripts/assemble-meeting-notes.sh" "$RESOURCES/scripts/assemble-meeting-notes.sh"
cp "$ROOT/scripts/build-timeline.py" "$RESOURCES/scripts/build-timeline.py"
chmod +x "$RESOURCES/scripts/transcribe-local-whisper.sh" "$RESOURCES/scripts/assemble-meeting-notes.sh"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>EchoPilot</string>
    <key>CFBundleIdentifier</key>
    <string>com.echopilot.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>EchoPilot</string>
    <key>CFBundleDisplayName</key>
    <string>EchoPilot</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIconFile</key>
    <string>EchoPilot</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>EchoPilot records the selected microphone for meeting notes after user consent.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>EchoPilot captures system audio and visible meeting windows after user consent.</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - --entitlements "$ROOT/Xcode/EchoPilot/EchoPilot.entitlements" "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "Built $APP_DIR"
echo "Open with: open '$APP_DIR'"
