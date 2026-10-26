#!/usr/bin/env bash
# Compile and run the standalone WindowController and WindowWriter reliability test harness (D05).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT/.build/audit-harness"
BINARY="$BUILD_DIR/window-harness"

mkdir -p "$BUILD_DIR" /tmp/swift-module-cache

swiftc \
  -swift-version 6 \
  -O \
  -target arm64-apple-macos14.0 \
  -module-cache-path /tmp/swift-module-cache \
  -o "$BINARY" \
  "$ROOT/Sources/IumeCore/Models/CoreModels.swift" \
  "$ROOT/Sources/IumeCore/Diagnostics/Diagnostics.swift" \
  "$ROOT/Sources/IumeCore/Diagnostics/Signposts.swift" \
  "$ROOT/Sources/IumeCore/Controller/WindowController.swift" \
  "$ROOT/scripts/audit/harness/window/main.swift"

"$BINARY"
