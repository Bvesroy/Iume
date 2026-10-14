#!/bin/bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=== Building Iume for Packaging ==="
swift build -c release

APP_NAME="Iume.app"
BUNDLE_DIR="$PROJECT_ROOT/.build/bundle"
APP_DIR="$BUNDLE_DIR/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "=== Creating macOS App Bundle ==="
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy binary
cp "$PROJECT_ROOT/.build/release/Iume" "$MACOS_DIR/Iume"
chmod +x "$MACOS_DIR/Iume"

# Copy Info.plist
cp "$PROJECT_ROOT/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

# Ad-hoc code signing for local execution without paid developer account
echo "=== Ad-hoc Code Signing App Bundle ==="
codesign --force --deep --sign - "$APP_DIR"

echo "=== Packaging Distribution Archive ==="
mkdir -p "$PROJECT_ROOT/dist"
DIST_ZIP="$PROJECT_ROOT/dist/Iume-macOS.zip"
rm -f "$DIST_ZIP"
(cd "$BUNDLE_DIR" && zip -r -y "$DIST_ZIP" "$APP_NAME")

echo "=========================================================="
echo " Packaging complete!"
echo " App Bundle:  $APP_DIR"
echo " Dist Archive: $DIST_ZIP"
echo "=========================================================="
