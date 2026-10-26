#!/bin/bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

SDK_FLAG=""
BUILD_PATH=""
RELEASE_BIN="$PROJECT_ROOT/.build/release/Iume"
if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]; then
    SDK_FLAG="--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    BUILD_PATH="--build-path .build-sdk265"
    RELEASE_BIN="$PROJECT_ROOT/.build-sdk265/release/Iume"
fi

if [ "${1:-}" != "--skip-build" ]; then
    echo "=== Building Iume for Packaging ==="
    mkdir -p /tmp/swift-module-cache
    CLANG_MODULE_CACHE_PATH=/tmp/swift-module-cache \
    swift build --disable-sandbox -c release $SDK_FLAG $BUILD_PATH \
      -Xswiftc -module-cache-path -Xswiftc /tmp/swift-module-cache \
      -Xcc -fmodules-cache-path=/tmp/swift-module-cache
fi

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
cp "$RELEASE_BIN" "$MACOS_DIR/Iume"
chmod +x "$MACOS_DIR/Iume"

# Copy Info.plist
cp "$PROJECT_ROOT/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

# Copy AppIcon.icns if present
if [ -f "$PROJECT_ROOT/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# Code signing — must use stable identity, never ad-hoc (§13.5, §19.4).
# Ad-hoc cdhash changes per build => TCC treats each build as a new app => permission loop.
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -E "Developer ID Application|Iume Local Signer" | head -n 1 | awk -F '"' '{print $2}' || true)
if [ -z "$SIGN_IDENTITY" ] && security find-certificate -c "Iume Local Signer" >/dev/null 2>&1; then
    SIGN_IDENTITY="Iume Local Signer"
fi

if [ -z "$SIGN_IDENTITY" ]; then
    echo "ERROR: No stable code-signing identity found." >&2
    echo "Create one: Keychain Access > Certificate Assistant > Create Certificate > 'Iume Local Signer' (Code Signing, login keychain)," >&2
    echo "or install a Developer ID Application certificate. Refusing ad-hoc sign (would break TCC)." >&2
    exit 1
fi
echo "=== Signing with persistent identity: $SIGN_IDENTITY ==="
xattr -cr "$APP_DIR"
codesign --force --options runtime --entitlements "$PROJECT_ROOT/Resources/Iume.entitlements" --sign "$SIGN_IDENTITY" "$APP_DIR"
echo "=== Verifying signature ==="
codesign --verify --deep --strict --verbose=2 "$APP_DIR" 2>&1 || true

# Install to /Applications — cleanly replace to avoid invalid page hashes
if [ -w "/Applications" ]; then
    echo "=== Installing into /Applications/Iume.app ==="
    pkill -9 -x Iume 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME"
    ditto "$APP_DIR" "/Applications/$APP_NAME"
    xattr -cr "/Applications/$APP_NAME"
    codesign --force --options runtime --entitlements "$PROJECT_ROOT/Resources/Iume.entitlements" --sign "$SIGN_IDENTITY" "/Applications/$APP_NAME"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP_NAME" 2>/dev/null || true
    # Gate check
    spctl -a -vvv -t install "/Applications/$APP_NAME" 2>&1 || echo "spctl: not notarized or ad-hoc — expected for local builds"
fi

echo "=== Packaging Distribution Archive ==="
mkdir -p "$PROJECT_ROOT/dist"
DIST_ZIP="$PROJECT_ROOT/dist/Iume-macOS.zip"
DIST_DMG="$PROJECT_ROOT/dist/Iume-macOS.dmg"
rm -f "$DIST_ZIP" "$DIST_DMG"
(cd "$BUNDLE_DIR" && zip -r -y "$DIST_ZIP" "$APP_NAME")

# DMG with Applications shortcut (best-effort; requires hdiutil)
if command -v hdiutil >/dev/null 2>&1; then
    echo "=== Creating DMG ==="
    DMG_TMP="$PROJECT_ROOT/dist/dmg_tmp"
    rm -rf "$DMG_TMP"
    mkdir -p "$DMG_TMP"
    ditto "$APP_DIR" "$DMG_TMP/$APP_NAME"
    ln -s /Applications "$DMG_TMP/Applications" 2>/dev/null || true
    hdiutil create -volname "Iume" -srcfolder "$DMG_TMP" -ov -format UDZO "$DIST_DMG" 2>&1 || echo "DMG creation failed (non-fatal)"
    rm -rf "$DMG_TMP"
    if [ -f "$DIST_DMG" ]; then
        echo "DMG: $DIST_DMG"
        shasum -a 256 "$DIST_DMG" | tee "$DIST_DMG.sha256" 2>/dev/null || true
    fi
fi
if [ -f "$DIST_ZIP" ]; then
    shasum -a 256 "$DIST_ZIP" | tee "$DIST_ZIP.sha256" 2>/dev/null || true
fi

echo "=========================================================="
echo " Packaging complete!"
echo " App Bundle:  $APP_DIR"
echo " Dist Archive: $DIST_ZIP"
[ -f "$DIST_DMG" ] && echo " DMG: $DIST_DMG"
echo "=========================================================="
