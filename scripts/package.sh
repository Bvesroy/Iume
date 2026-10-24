#!/bin/bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

INSTALL=1
BACKUP=0
for arg in "$@"; do
    case "$arg" in
        --no-install) INSTALL=0 ;;
        --with-backup) BACKUP=1 ;;
        *) ;;
    esac
done

"$PROJECT_ROOT/scripts/build-rust.sh"

echo "=== Building Iume for Packaging (Release) ==="
swift build -c release --disable-sandbox

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

ENTITLEMENTS_FLAG=""
if [ -f "$PROJECT_ROOT/Resources/Iume.entitlements" ]; then
    ENTITLEMENTS_FLAG="--entitlements $PROJECT_ROOT/Resources/Iume.entitlements"
fi

echo "=== Code Signing App Bundle with Designated Requirement ==="
xattr -cr "$APP_DIR" 2>/dev/null || true
codesign --force --deep --options runtime \
    ${ENTITLEMENTS_FLAG} \
    --identifier "com.iume.Iume" \
    --requirements '=designated => identifier "com.iume.Iume"' \
    --sign - "$APP_DIR"

codesign --verify --deep --strict "$APP_DIR"
echo "✓ App bundle verified: $APP_DIR"

if [ "$INSTALL" -eq 1 ]; then
    echo "=== Installing into /Applications/$APP_NAME ==="
    pkill -x Iume 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME"
    cp -R "$APP_DIR" "/Applications/$APP_NAME"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP_NAME" 2>/dev/null || true
    echo "✓ Successfully installed to /Applications/$APP_NAME"
fi

echo "=== Packaging Distribution Archive ==="
mkdir -p "$PROJECT_ROOT/dist"
DIST_ZIP="$PROJECT_ROOT/dist/Iume-macOS.zip"
rm -f "$DIST_ZIP"
(cd "$BUNDLE_DIR" && zip -r -y "$DIST_ZIP" "$APP_NAME" > /dev/null)

if [ "$BACKUP" -eq 1 ]; then
    MEGA_BACKUP="/Users/bves/MEGA/Projects/Iume"
    if [ -d "$MEGA_BACKUP" ]; then
        echo "=== Syncing Backup to MEGA ==="
        rsync -av --delete --exclude='.build' "$PROJECT_ROOT/" "$MEGA_BACKUP/"
    fi
fi

echo "=========================================================="
echo " Packaging & Installation complete!"
echo " App Bundle:  $APP_DIR"
if [ "$INSTALL" -eq 1 ]; then
    echo " Installed to: /Applications/$APP_NAME"
fi
echo " Dist Archive: $DIST_ZIP"
echo "=========================================================="
