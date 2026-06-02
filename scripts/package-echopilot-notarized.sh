#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="${SCHEME:-EchoPilot}"
CONFIG="${CONFIG:-Release}"
VERSION="${1:-}"
DERIVED_DATA="$ROOT/build/xcode-release"
STAGING_DIR="$ROOT/build/notarized-release"
APP_NAME="EchoPilot.app"
STAGED_APP="$STAGING_DIR/$APP_NAME"
DIST_DIR="$ROOT/dist"
ENTITLEMENTS="$ROOT/Xcode/EchoPilot/EchoPilot.entitlements"
SIGNING_ENV="$ROOT/.echopilot-signing.env"

cd "$ROOT"

if [[ -f "$SIGNING_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$SIGNING_ENV"
fi

if [[ -z "$VERSION" ]]; then
  VERSION="$(grep -m1 'MARKETING_VERSION = ' EchoPilot.xcodeproj/project.pbxproj | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/')"
fi
if [[ -z "$VERSION" ]]; then
  VERSION="0.0.0"
fi

DMG_PATH="$DIST_DIR/EchoPilot-$VERSION.dmg"
ZIP_PATH="$DIST_DIR/EchoPilot-$VERSION.zip"

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required tool not found: $1" >&2
    exit 2
  fi
}

require_tool xcodebuild
require_tool codesign
require_tool hdiutil
require_tool xcrun
require_tool ditto

if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "Entitlements file not found: $ENTITLEMENTS" >&2
  exit 2
fi

find_developer_id_application_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -nE 's/^ *[0-9]+\) ([A-F0-9]{40}) "Developer ID Application: .+ \(([A-Z0-9]{10})\)".*/\1/p' \
    | head -n 1
}

SIGNING_IDENTITY="${DEVELOPER_ID_APPLICATION_IDENTITY:-${SIGNING_IDENTITY:-$(find_developer_id_application_identity || true)}}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  cat >&2 <<'NO_DEVELOPER_ID'
ERROR: No Developer ID Application signing identity with private key was found.

Create/download it on the Mac that builds releases:
  Xcode → Settings → Accounts → Manage Certificates… → + → Developer ID Application

Or configure one in .echopilot-signing.env:
  DEVELOPER_ID_APPLICATION_IDENTITY="Developer ID Application: Your Name (TEAMID)"

Find identities with:
  security find-identity -v -p codesigning
NO_DEVELOPER_ID
  exit 2
fi

if [[ -z "${NOTARY_PROFILE:-}" ]]; then
  cat >&2 <<'NO_NOTARY_PROFILE'
ERROR: NOTARY_PROFILE is not set.

Create a local notarytool keychain profile once, for example:
  xcrun notarytool store-credentials echopilot-notary \
    --apple-id "YOUR_APPLE_ID@example.com" \
    --team-id "YOUR_TEAM_ID" \
    --password "APP_SPECIFIC_PASSWORD"

Then run:
  NOTARY_PROFILE=echopilot-notary scripts/package-echopilot-notarized.sh

Alternatively put this non-secret profile name in .echopilot-signing.env:
  NOTARY_PROFILE=echopilot-notary
NO_NOTARY_PROFILE
  exit 2
fi

echo "Building EchoPilot $VERSION for signed/notarized release"
echo "Signing identity: $SIGNING_IDENTITY"
echo "Notary profile: $NOTARY_PROFILE"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR" "$DIST_DIR"

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

/usr/bin/ditto "$BUILT_APP" "$STAGED_APP"
xattr -dr com.apple.quarantine "$STAGED_APP" >/dev/null 2>&1 || true

codesign --force --deep --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGNING_IDENTITY" \
  "$STAGED_APP"

codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
spctl --assess --type execute --verbose=4 "$STAGED_APP" || true

rm -f "$ZIP_PATH" "$DMG_PATH"
ditto -c -k --keepParent "$STAGED_APP" "$ZIP_PATH"
hdiutil create \
  -volname "EchoPilot $VERSION" \
  -srcfolder "$STAGED_APP" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

# Signing the DMG is optional for notarization, but useful for integrity checks.
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG_PATH"

xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --verbose=4 "$DMG_PATH" || true

cat <<DONE

Signed + notarized release assets:
  $DMG_PATH
  $ZIP_PATH

Upload the DMG to the GitHub Release. Prefer the DMG for public users because it carries the stapled notarization ticket.
DONE
