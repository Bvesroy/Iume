#!/bin/bash
set -e

echo "=== Building Iume (Release) ==="
swift build -c release
echo "Release build succeeded! Executable at: .build/release/Iume"
