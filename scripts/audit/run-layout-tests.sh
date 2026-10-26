#!/usr/bin/env bash
# Compile and run the production layout engine without SwiftUI / Xcode.
#
# The full SwiftPM test target needs Xcode's SwiftUI macro plugin. This harness
# compiles the real geometry sources and exercises the shared scroll-bounds
# authority (D03 / D08 / D16 / D18) as executable evidence.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT/.build/audit-harness"
BINARY="$BUILD_DIR/layout-harness"

mkdir -p "$BUILD_DIR" /tmp/swift-module-cache

swiftc \
  -swift-version 6 \
  -O \
  -target arm64-apple-macos14.0 \
  -module-cache-path /tmp/swift-module-cache \
  -o "$BINARY" \
  "$ROOT/Sources/IumeCore/Models/CoreModels.swift" \
  "$ROOT/Sources/IumeCore/Models/ManagedWindow.swift" \
  "$ROOT/Sources/IumeCore/LayoutEngine/BoxTilingEngine.swift" \
  "$ROOT/Sources/IumeCore/LayoutEngine/LayoutEngine.swift" \
  "$ROOT/scripts/audit/harness/layout/main.swift"

"$BINARY"
