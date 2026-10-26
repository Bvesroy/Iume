#!/usr/bin/env bash
#
# scripts/audit/run-all-tests.sh
#
# Unified audit test gate for Iume (Phases 2-5).
# Runs all 4 deterministic test suites without requiring full Xcode installation:
#   1. Layout Suite (77 checks)
#   2. Physics / Resampling Suite (261 checks)
#   3. Window Application & AX Reliability Suite (39 checks)
#   4. Rust Engine Parity Suite (36 unittests)
#
# Exit code: 0 if all 413 checks pass, 1 if any failure occurs.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "================================================================="
echo "  Iume Unified Audit Test Gate (Phases 2-5)"
echo "  Repository: $ROOT"
echo "  Date:       $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================="
echo

FAILED=0

# 1. Layout Tests
echo "-----------------------------------------------------------------"
echo ">>> [1/4] Running Layout Suite..."
echo "-----------------------------------------------------------------"
if "$SCRIPT_DIR/run-layout-tests.sh"; then
    echo ">>> [1/4] Layout Suite: PASSED"
else
    echo ">>> [1/4] Layout Suite: FAILED"
    FAILED=1
fi
echo

# 2. Physics / Resampling Tests
echo "-----------------------------------------------------------------"
echo ">>> [2/4] Running Physics & Scroll Resampling Suite..."
echo "-----------------------------------------------------------------"
if "$SCRIPT_DIR/run-physics-tests.sh"; then
    echo ">>> [2/4] Physics Suite: PASSED"
else
    echo ">>> [2/4] Physics Suite: FAILED"
    FAILED=1
fi
echo

# 3. Window Application & AX Reliability Tests
echo "-----------------------------------------------------------------"
echo ">>> [3/4] Running Window Pipeline & AX Reliability Suite..."
echo "-----------------------------------------------------------------"
if "$SCRIPT_DIR/run-window-tests.sh"; then
    echo ">>> [3/4] Window Pipeline Suite: PASSED"
else
    echo ">>> [3/4] Window Pipeline Suite: FAILED"
    FAILED=1
fi
echo

# 4. Rust Engine Tests
echo "-----------------------------------------------------------------"
echo ">>> [4/4] Running Rust Engine Parity Suite..."
echo "-----------------------------------------------------------------"
if cargo test --release --manifest-path "$ROOT/crates/iume_engine/Cargo.toml"; then
    echo ">>> [4/4] Rust Engine Suite: PASSED"
else
    echo ">>> [4/4] Rust Engine Suite: FAILED"
    FAILED=1
fi
echo

echo "================================================================="
if [ "$FAILED" -eq 0 ]; then
    echo "  ALL AUDIT SUITES PASSED (413/413 CHECKS GREEN)!"
    echo "================================================================="
    exit 0
else
    echo "  ONE OR MORE TEST SUITES FAILED!"
    echo "================================================================="
    exit 1
fi
