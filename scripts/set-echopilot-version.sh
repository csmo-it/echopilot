#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT/EchoPilot.xcodeproj/project.pbxproj"
VERSION="${1:-}"
BUILD="${2:-}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/set-echopilot-version.sh <marketing-version> [build-number]

Examples:
  scripts/set-echopilot-version.sh 0.1.1
  scripts/set-echopilot-version.sh 0.1.1 2

This updates the Xcode project values:
  MARKETING_VERSION        -> CFBundleShortVersionString, shown as app version
  CURRENT_PROJECT_VERSION  -> CFBundleVersion, internal build number
USAGE
}

if [[ -z "$VERSION" || "$VERSION" == "-h" || "$VERSION" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}([-+][A-Za-z0-9.-]+)?$ ]]; then
  echo "Invalid marketing version: $VERSION" >&2
  echo "Expected something like 0.1.1 or 1.0.0" >&2
  exit 2
fi

if [[ -z "$BUILD" ]]; then
  BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | sed -E 's/.*CURRENT_PROJECT_VERSION = "?([^";]+)"?;.*/\1/')"
  if [[ "$BUILD" =~ ^[0-9]+$ ]]; then
    BUILD="$((BUILD + 1))"
  else
    BUILD="1"
  fi
fi

if [[ ! "$BUILD" =~ ^[0-9]+$ ]]; then
  echo "Invalid build number: $BUILD" >&2
  echo "Expected an integer like 2" >&2
  exit 2
fi

python3 - "$PROJECT_FILE" "$VERSION" "$BUILD" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
version = sys.argv[2]
build = sys.argv[3]
text = path.read_text()
text, marketing_count = re.subn(r'MARKETING_VERSION = [^;]+;', f'MARKETING_VERSION = {version};', text)
text, build_count = re.subn(r'CURRENT_PROJECT_VERSION = [^;]+;', f'CURRENT_PROJECT_VERSION = {build};', text)
if marketing_count == 0 or build_count == 0:
    raise SystemExit(f'Failed to update version fields: MARKETING_VERSION={marketing_count}, CURRENT_PROJECT_VERSION={build_count}')
path.write_text(text)
print(f'Updated {path}: MARKETING_VERSION={version}, CURRENT_PROJECT_VERSION={build}')
PY

grep -n "MARKETING_VERSION\|CURRENT_PROJECT_VERSION" "$PROJECT_FILE" | sed -n '1,20p'
