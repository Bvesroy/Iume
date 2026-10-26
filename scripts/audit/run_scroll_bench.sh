#!/bin/zsh
# Build and run the headless scroll benchmark against prebuilt SwiftPM artifacts.
# Requires a prior `swift build`. On a CLT-only machine the checked-in .build
# artifacts are reused, because the SwiftUI macro plugin ships with Xcode.

set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD="${IUME_BENCH_BUILD:-.build/release}"
CONFIG="release"
[[ "${BUILD}" == *debug* ]] && CONFIG="debug"
MODULEMAP="$(find .build/out/Intermediates.noindex -name 'CIumeEngine.modulemap' 2>/dev/null | head -1 || true)"
if [[ -z "${MODULEMAP}" ]]; then
  echo "error: CIumeEngine.modulemap not found; run swift build first" >&2
  exit 1
fi
if [[ ! -f "${BUILD}/libIumeCore.a" ]]; then
  echo "error: ${BUILD}/libIumeCore.a not found; run swift build first" >&2
  exit 1
fi

OUT="${TMPDIR:-/tmp}/iume-scroll-bench"
mkdir -p "${OUT}"

# The benchmark mutates SettingsStore.shared, which writes UserDefaults and may
# schedule a settings-memory save. Snapshot the real domain and JSON, restore on exit.
# If a snapshot cannot be taken, abort rather than leak benchmark settings into the app.
PREFS_BACKUP="${OUT}/com.iume.Iume.backup.plist"
SETTINGS_JSON="${HOME}/Library/Application Support/Iume/settings_memory.json"
SETTINGS_JSON_BACKUP="${OUT}/settings_memory.backup.json"

PREFS_EXISTED=0
if defaults read com.iume.Iume >/dev/null 2>&1; then
  PREFS_EXISTED=1
  if ! defaults export com.iume.Iume - > "${PREFS_BACKUP}" 2>/dev/null; then
    echo "error: could not back up com.iume.Iume; aborting without running" >&2
    exit 1
  fi
else
  rm -f "${PREFS_BACKUP}"
fi

SETTINGS_EXISTED=0
rm -f "${SETTINGS_JSON_BACKUP}"
if [[ -f "${SETTINGS_JSON}" ]]; then
  SETTINGS_EXISTED=1
  cp "${SETTINGS_JSON}" "${SETTINGS_JSON_BACKUP}"
fi

restore() {
  if (( PREFS_EXISTED )); then
    defaults import com.iume.Iume "${PREFS_BACKUP}" >/dev/null 2>&1 || true
  else
    defaults delete com.iume.Iume >/dev/null 2>&1 || true
  fi
  if (( SETTINGS_EXISTED )); then
    cp "${SETTINGS_JSON_BACKUP}" "${SETTINGS_JSON}"
  fi
}
trap restore EXIT INT TERM HUP

swiftc -O \
  -I "${BUILD}" \
  -Xcc -fmodule-map-file="${MODULEMAP}" \
  -L "${BUILD}" -lIumeCore \
  -L "crates/iume_engine/target/release" -liume_engine \
  -o "${OUT}/scroll_bench" \
  scripts/audit/scroll_bench.swift

IUME_BENCH_CONFIG="${CONFIG}" "${OUT}/scroll_bench" | tee "${OUT}/results-${CONFIG}.jsonl"
