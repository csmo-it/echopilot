#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"

cd "$ROOT"

if [[ -z "$VERSION" ]]; then
  VERSION="$(grep -m1 'MARKETING_VERSION = ' EchoPilot.xcodeproj/project.pbxproj | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/')"
fi

if [[ -z "$VERSION" ]]; then
  VERSION="0.0.0"
fi

APP_DIR="$ROOT/build/app/EchoPilot.app"
DIST_DIR="$ROOT/dist"
ZIP_PATH="$DIST_DIR/EchoPilot-$VERSION.zip"

scripts/build-echopilot-app.sh

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

if command -v ditto >/dev/null 2>&1; then
  ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
else
  (cd "$(dirname "$APP_DIR")" && zip -qr "$ZIP_PATH" "$(basename "$APP_DIR")")
fi

printf 'Packaged release asset:\n  %s\n' "$ZIP_PATH"
printf 'Attach this file to a GitHub Release. For public production builds, prefer Developer ID signing and notarization.\n'
