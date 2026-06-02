#!/usr/bin/env python3
from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ICON = ROOT / "Xcode" / "EchoPilot" / "EchoPilot.icns"
XCODE_PLIST = ROOT / "Xcode" / "EchoPilot" / "Info.plist"
BUILD_SCRIPT = ROOT / "scripts" / "build-echopilot-app.sh"
PROJECT = ROOT / "EchoPilot.xcodeproj" / "project.pbxproj"

REQUIRED_CHUNKS = {"icp4", "icp5", "icp6", "ic07", "ic08", "ic09", "ic10"}


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


if not ICON.exists():
    fail(f"missing icon file: {ICON}")

data = ICON.read_bytes()
if data[:4] != b"icns":
    fail("EchoPilot.icns does not start with icns magic")

declared_size = int.from_bytes(data[4:8], "big")
if declared_size != len(data):
    fail(f"icns declared size {declared_size} != actual size {len(data)}")

chunks: list[str] = []
pos = 8
while pos + 8 <= len(data):
    typ = data[pos : pos + 4].decode("latin1")
    size = int.from_bytes(data[pos + 4 : pos + 8], "big")
    if size < 8:
        fail(f"invalid icns chunk {typ!r} size {size}")
    chunks.append(typ)
    pos += size

if pos != len(data):
    fail(f"icns parsing ended at {pos}, expected {len(data)}")

missing = sorted(REQUIRED_CHUNKS - set(chunks))
if missing:
    fail(f"EchoPilot.icns is missing expected chunks: {', '.join(missing)}")

plist_root = ET.parse(XCODE_PLIST).getroot()
values = plist_root.find("dict")
if values is None:
    fail("Info.plist has no dict")
items = list(values)
plist: dict[str, str] = {}
for idx, item in enumerate(items[:-1]):
    if item.tag == "key" and item.text:
        nxt = items[idx + 1]
        if nxt.tag == "string" and nxt.text is not None:
            plist[item.text] = nxt.text

if plist.get("CFBundleIconName") != "AppIcon":
    fail(f"CFBundleIconName should be AppIcon, got {plist.get('CFBundleIconName')!r}")
if plist.get("CFBundleIconFile") != "EchoPilot":
    fail(f"CFBundleIconFile should be EchoPilot (without .icns), got {plist.get('CFBundleIconFile')!r}")

build_script = BUILD_SCRIPT.read_text()
if 'cp "$ROOT/Xcode/EchoPilot/EchoPilot.icns" "$RESOURCES/EchoPilot.icns"' not in build_script:
    fail("build-echopilot-app.sh does not copy EchoPilot.icns into Contents/Resources")

project = PROJECT.read_text()
if "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;" not in project:
    fail("Xcode project does not set ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon")
if "EchoPilot.icns in Resources" not in project:
    fail("Xcode project does not include EchoPilot.icns in Resources")

print("Icon configuration OK")
print("ICNS chunks:", ", ".join(chunks))
