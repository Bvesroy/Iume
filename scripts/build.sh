#!/bin/bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

"$PROJECT_ROOT/scripts/build-rust.sh"

echo "=== Building Iume (Debug) ==="
swift build -c debug
echo "Build succeeded! Executable at: .build/debug/Iume"
