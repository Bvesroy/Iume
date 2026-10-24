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

# Copy AppIcon.icns if present
if [ -f "$PROJECT_ROOT/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# Code signing with Iume Local Signer if available, or ad-hoc fallback
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -E "Developer ID Application|Iume Local Signer" | head -n 1 | awk -F '"' '{print $2}' || true)
if [ -z "$SIGN_IDENTITY" ] && security find-certificate -c "Iume Local Signer" >/dev/null 2>&1; then
    SIGN_IDENTITY="Iume Local Signer"
fi

if [ -n "$SIGN_IDENTITY" ]; then
    echo "=== Signing with persistent identity: $SIGN_IDENTITY ==="
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"
else
    echo "=== Ad-hoc Code Signing App Bundle ==="
    codesign --force --deep --sign - "$APP_DIR"
fi

# Install to /Applications
if [ -w "/Applications" ]; then
    echo "=== Installing into /Applications/Iume.app ==="
    pkill -x Iume 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME"
    cp -R "$APP_DIR" "/Applications/$APP_NAME"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP_NAME" 2>/dev/null || true
fi

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
