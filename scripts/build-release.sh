#!/bin/bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

"$PROJECT_ROOT/scripts/build-rust.sh"

echo "=== Building Iume (Release) ==="
SDK_FLAG=""
BUILD_PATH=""
if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]; then
    SDK_FLAG="--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    BUILD_PATH="--build-path .build-sdk265"
fi
mkdir -p /tmp/swift-module-cache
CLANG_MODULE_CACHE_PATH=/tmp/swift-module-cache \
swift build --disable-sandbox -c release $SDK_FLAG $BUILD_PATH \
  -Xswiftc -module-cache-path -Xswiftc /tmp/swift-module-cache \
  -Xcc -fmodules-cache-path=/tmp/swift-module-cache
echo "Release build succeeded! Executable at: ${BUILD_PATH:-.build}/release/Iume"
