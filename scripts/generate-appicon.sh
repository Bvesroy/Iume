#!/bin/bash
# Generates the Iume app icon (.icns) from the vector source.
#
#   scripts/AppIconRenderer.swift  -> renders each pixel size
#   iconutil                      -> packs them into an Apple .icns
#
# Output: Resources/AppIcon.icns (checked into the repo so packaging never
# depends on a Swift toolchain being present).
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENDERER="$PROJECT_ROOT/scripts/AppIconRenderer.swift"
ICNS="$PROJECT_ROOT/Resources/AppIcon.icns"

WORK_DIR="$(mktemp -d)"
ICONSET="$WORK_DIR/AppIcon.iconset"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== Rendering Iume app icon ==="
swift "$RENDERER" "$WORK_DIR" 16 32 64 128 256 512 1024

echo "=== Assembling iconset ==="
mkdir -p "$ICONSET"

cp "$WORK_DIR/icon_16x16.png"   "$ICONSET/icon_16x16.png"
cp "$WORK_DIR/icon_32x32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$WORK_DIR/icon_32x32.png"   "$ICONSET/icon_32x32.png"
cp "$WORK_DIR/icon_64x64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$WORK_DIR/icon_128x128.png" "$ICONSET/icon_128x128.png"
cp "$WORK_DIR/icon_256x256.png" "$ICONSET/icon_128x128@2x.png"
cp "$WORK_DIR/icon_256x256.png" "$ICONSET/icon_256x256.png"
cp "$WORK_DIR/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
cp "$WORK_DIR/icon_512x512.png" "$ICONSET/icon_512x512.png"
cp "$WORK_DIR/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"

echo "=== Packing .icns ==="
rm -f "$ICNS"
iconutil -c icns "$ICONSET" -o "$ICNS"

echo "✓ App icon written to $ICNS"
