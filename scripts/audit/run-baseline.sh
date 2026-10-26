#!/usr/bin/env bash
# Phase 2 sliding-engine baseline / after measurement.
#
# Usage: scripts/audit/run-baseline.sh [label]
# Writes scripts/audit/<label>-<timestamp>.md and prints the same report.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="$ROOT/scripts/audit"
LABEL="${1:-baseline}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$OUT_DIR/${LABEL}-${STAMP}.md"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/iume-audit.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$OUT_DIR"

DIRTY_SHA="$(git -C "$ROOT" stash create 2>/dev/null || true)"
if [ -z "$DIRTY_SHA" ]; then
  DIRTY_FINGERPRINT="$(git -C "$ROOT" status --porcelain | shasum -a 256 | awk '{print $1}')"
else
  DIRTY_FINGERPRINT="$DIRTY_SHA"
fi

{
  echo "# Iume sliding-engine measurement — $LABEL"
  echo
  echo "- Timestamp (UTC): $STAMP"
  echo "- Commit: $(git -C "$ROOT" rev-parse HEAD)"
  echo "- Working-tree fingerprint: $DIRTY_FINGERPRINT"
  echo "- macOS: $(sw_vers -productVersion 2>/dev/null || uname -sr)"
  echo "- CPU: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)"
  echo "- Rust: $(rustc --version 2>/dev/null || echo unavailable)"
  echo "- Swift: $(swift --version 2>/dev/null | head -1 || echo unavailable)"
  echo
} > "$OUT"

echo "## Rust unit tests" >> "$OUT"
echo '```' >> "$OUT"
(cd "$ROOT/crates/iume_engine" && cargo test --release 2>&1) | tail -40 >> "$OUT"
RUST_TEST_STATUS=${PIPESTATUS[0]}
echo '```' >> "$OUT"
echo >> "$OUT"
echo "Rust test status: $RUST_TEST_STATUS" >> "$OUT"
echo >> "$OUT"

echo "## Spring benchmark (real crate sources)" >> "$OUT"
# Compile the crate sources directly so the benchmark does not require adding
# a [[bench]] target or touching Cargo.toml.
CARGO_PKG_VERSION="$(awk -F'"' '/^version *=/ {print $2; exit}' "$ROOT/crates/iume_engine/Cargo.toml")" \
rustc --edition 2021 --crate-name iume_engine --crate-type rlib -O \
  "$ROOT/crates/iume_engine/src/lib.rs" -o "$TMP/libiume_engine.rlib" 2>"$TMP/rustc.log"
RUSTC_STATUS=$?
if [ $RUSTC_STATUS -eq 0 ]; then
  rustc --edition 2021 -O "$ROOT/scripts/audit/spring_bench.rs" \
    --extern iume_engine="$TMP/libiume_engine.rlib" -o "$TMP/spring_bench" 2>>"$TMP/rustc.log"
  BENCH_STATUS=$?
  if [ $BENCH_STATUS -eq 0 ]; then
    "$TMP/spring_bench" >> "$OUT"
  else
    echo "benchmark build failed (status $BENCH_STATUS):" >> "$OUT"
    echo '```' >> "$OUT"
    cat "$TMP/rustc.log" >> "$OUT"
    echo '```' >> "$OUT"
  fi
else
  echo "engine build failed (status $RUSTC_STATUS):" >> "$OUT"
  echo '```' >> "$OUT"
  cat "$TMP/rustc.log" >> "$OUT"
  echo '```' >> "$OUT"
fi
echo >> "$OUT"

echo "## Swift tests" >> "$OUT"
# SwiftPM cannot build IumeCore on a CommandLineTools-only machine because the
# SwiftUI macro plugin ships with Xcode. Record the real result; never report a
# skipped suite as passing.
(cd "$ROOT" && swift test --scratch-path "$TMP/swift-build" 2>&1) > "$TMP/swift.log"
SWIFT_STATUS=$?
if [ $SWIFT_STATUS -eq 0 ]; then
  echo "Swift test status: 0 (passed)" >> "$OUT"
  grep -E "Test run with|Executed [0-9]+ test" "$TMP/swift.log" | tail -5 >> "$OUT"
else
  echo "Swift test status: $SWIFT_STATUS (blocked or failed)" >> "$OUT"
  echo '```' >> "$OUT"
  grep -E "error:|warning: .*macro|Build failed" "$TMP/swift.log" | head -20 >> "$OUT"
  echo '```' >> "$OUT"
fi
echo >> "$OUT"

echo "## Standalone Swift physics harness" >> "$OUT"
if [ -x "$ROOT/scripts/audit/run-physics-tests.sh" ]; then
  (cd "$ROOT" && scripts/audit/run-physics-tests.sh 2>&1) >> "$OUT"
  PHYSICS_STATUS=$?
  echo "Physics harness status: $PHYSICS_STATUS" >> "$OUT"
else
  echo "Physics harness not present yet." >> "$OUT"
fi
echo >> "$OUT"

echo "## Environment note" >> "$OUT"
echo "SwiftPM failures caused by a missing Xcode SwiftUI macro plugin are" >> "$OUT"
echo "environment limitations, not product regressions. Rust and the" >> "$OUT"
echo "standalone physics harness still exercise the shipped physics source." >> "$OUT"

cat "$OUT"
echo
echo "Report written to $OUT"
