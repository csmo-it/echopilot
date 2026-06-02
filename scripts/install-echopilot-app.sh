#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="${SCHEME:-EchoPilot}"
CONFIG="${CONFIG:-Release}"
DERIVED_DATA="$ROOT/build/xcode"
STAGING_DIR="$ROOT/build/install"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
APP_NAME="EchoPilot.app"
STAGED_APP="$STAGING_DIR/$APP_NAME"
DEST_APP="$INSTALL_DIR/$APP_NAME"
SIGNING_ENV="$ROOT/.echopilot-signing.env"
ENTITLEMENTS="$ROOT/Xcode/EchoPilot/EchoPilot.entitlements"

cd "$ROOT"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found. Install/open Xcode first." >&2
  exit 2
fi

if [[ -f "$SIGNING_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$SIGNING_ENV"
fi

find_apple_development_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -nE 's/^ *[0-9]+\) ([A-F0-9]{40}) "Apple Development: .+ \(([A-Z0-9]{10})\)".*/\1|\2/p' \
    | head -n 1
}

SIGNING_MATCH="${SIGNING_MATCH:-$(find_apple_development_identity || true)}"
if [[ -n "$SIGNING_MATCH" ]]; then
  SIGNING_IDENTITY="${SIGNING_IDENTITY:-${SIGNING_MATCH%%|*}}"
  DETECTED_TEAM="${SIGNING_MATCH##*|}"
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-$DETECTED_TEAM}"
fi

if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
  cat >&2 <<'NO_CERT'
ERROR: No Apple Development signing identity with private key was found.

Create one in Xcode:
  Xcode → Settings → Accounts → Manage Certificates… → + → Apple Development

Or configure a specific identity hash in .echopilot-signing.env:
  SIGNING_IDENTITY=YOUR_40_CHAR_CERT_SHA1

Find identities with:
  security find-identity -v -p codesigning
NO_CERT
  exit 2
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "Entitlements file not found: $ENTITLEMENTS" >&2
  exit 2
fi

echo "Using DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM:-<unknown>}"
echo "Using manual codesign identity=$SIGNING_IDENTITY"
echo "Installing to $DEST_APP"

# Quit a running copy so Finder/TCC do not keep stale executable handles.
osascript -e 'tell application "EchoPilot" to quit' >/dev/null 2>&1 || true

# Build unsigned, then sign the installed app manually when a local signing
# identity is available. This keeps the install flow stable across machines.
xcodebuild \
  -project EchoPilot.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  build

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIG/$APP_NAME"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "Built app not found: $BUILT_APP" >&2
  exit 3
fi

rm -rf "$STAGED_APP"
mkdir -p "$STAGING_DIR"
/usr/bin/ditto "$BUILT_APP" "$STAGED_APP"

# Remove quarantine if the checkout/download added it; harmless if absent.
xattr -dr com.apple.quarantine "$STAGED_APP" >/dev/null 2>&1 || true

# Sign the staged copy with a stable Apple Development certificate and explicit entitlements.
codesign --force --deep --options runtime --timestamp=none --entitlements "$ENTITLEMENTS" --sign "$SIGNING_IDENTITY" "$STAGED_APP"

install_signed_app() {
  if [[ -w "$INSTALL_DIR" ]]; then
    mkdir -p "$INSTALL_DIR"
    rm -rf "$DEST_APP"
    /usr/bin/ditto "$STAGED_APP" "$DEST_APP"
  else
    echo "Admin permission may be required to install into $INSTALL_DIR"
    sudo mkdir -p "$INSTALL_DIR"
    sudo rm -rf "$DEST_APP"
    sudo /usr/bin/ditto "$STAGED_APP" "$DEST_APP"
  fi
}

install_signed_app

# Refresh LaunchServices so Finder/Dock see the updated bundle metadata and icon.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -u "$DEST_APP" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$DEST_APP" >/dev/null 2>&1 || true
fi

touch "$DEST_APP" "$DEST_APP/Contents" "$DEST_APP/Contents/Info.plist" >/dev/null 2>&1 || true

# Dock caches bundle icons aggressively. Restarting Dock is brief and avoids a
# stale generic icon after reinstall. Set ECHOPILOT_REFRESH_DOCK=0 to skip.
if [[ "${ECHOPILOT_REFRESH_DOCK:-1}" == "1" ]]; then
  killall Dock >/dev/null 2>&1 || true
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED_APP/Contents/Info.plist")"

echo "Installed: $DEST_APP"
echo "Bundle ID: $BUNDLE_ID"
echo
codesign -dv --verbose=4 "$STAGED_APP" 2>&1 | sed -n '1,28p' || true
echo
echo "Entitlements:"
codesign -d --entitlements :- "$STAGED_APP" 2>/dev/null || true
echo

echo "Open with: open '$DEST_APP'"
echo
cat <<RESET_HINT
If macOS permissions are stuck, reset once after installing this stable app path:
  tccutil reset Microphone $BUNDLE_ID
  tccutil reset ScreenCapture $BUNDLE_ID
  open '$DEST_APP'
RESET_HINT
