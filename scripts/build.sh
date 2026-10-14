#!/bin/bash
set -e

echo "=== Building Iume (Debug) ==="
swift build -c debug
echo "Build succeeded! Executable at: .build/debug/Iume"
