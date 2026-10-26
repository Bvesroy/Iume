#!/usr/bin/env bash
# Compile and run the production spring/ScrollController sources without SwiftUI.
#
# The full SwiftPM test target cannot build on a Command Line Tools-only machine
# (the SwiftUI macro plugin ships with Xcode). This harness compiles the real
# `Physics/SpringState.swift` and `Controller/ScrollController.swift` against a
# minimal SettingsStore stub, then exercises the shipped motion pipeline.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT/.build/audit-harness"
BINARY="$BUILD_DIR/physics-harness"

mkdir -p "$BUILD_DIR" /tmp/swift-module-cache

swiftc \
  -swift-version 6 \
  -O \
  -target arm64-apple-macos14.0 \
  -module-cache-path /tmp/swift-module-cache \
  -o "$BINARY" \
  "$ROOT/scripts/audit/harness/Stubs.swift" \
  "$ROOT/Sources/IumeCore/Physics/SpringState.swift" \
  "$ROOT/Sources/IumeCore/Controller/ScrollController.swift" \
  "$ROOT/scripts/audit/harness/AdversarialStressTests.swift" \
  "$ROOT/scripts/audit/harness/main.swift"

"$BINARY"
