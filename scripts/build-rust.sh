#!/bin/bash
# Builds the Rust strip engine (crates/iume_engine) into the static library that
# Package.swift links into IumeCore. Run this before any `swift build`; the Swift
# build scripts already do it for you.
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="$PROJECT_ROOT/crates/iume_engine"
LIB_PATH="$CRATE_DIR/target/release/libiume_engine.a"

if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo not found. Install the Rust toolchain (https://rustup.rs) to build iume_engine." >&2
    exit 1
fi

if [ ! -f "$CRATE_DIR/Cargo.toml" ]; then
    echo "error: missing crate manifest at $CRATE_DIR/Cargo.toml" >&2
    exit 1
fi

# Match the Swift package's macOS 14 deployment target. Forced rather than
# defaulted: developer shells often export a newer global value (and cargo looks
# for .cargo/config.toml from the working directory, not the crate).
export MACOSX_DEPLOYMENT_TARGET=14.0

echo "=== Building iume_engine (Rust, release, macOS ${MACOSX_DEPLOYMENT_TARGET}) ==="
cargo build --release --manifest-path "$CRATE_DIR/Cargo.toml"

if [ ! -f "$LIB_PATH" ]; then
    echo "error: cargo finished but $LIB_PATH is missing" >&2
    exit 1
fi

echo "Rust engine ready: $LIB_PATH"
