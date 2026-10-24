#!/bin/bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

"$PROJECT_ROOT/scripts/build-rust.sh"

echo "=== Building Iume (Release) ==="
swift build -c release
echo "Release build succeeded! Executable at: .build/release/Iume"
