# Measurement scripts — Iume sliding audit

Everything here is read-only with respect to `Sources/`, `crates/`, and `Tests/`.
Nothing in this directory ships in the app.

| file | what it does |
|---|---|
| `scroll_bench.swift` | Headless harness that drives the **real** `ScrollController` and `LayoutEngine` from the prebuilt `libIumeCore.a` at a real-time 120 Hz cadence. Emits one JSON object per scenario. |
| `run_scroll_bench.sh` | Compiles and runs `scroll_bench.swift`, and snapshots/restores the real `com.iume.Iume` defaults domain plus `settings_memory.json` around the run. |
| `window_sampler.swift` | Standalone `swiftc` CLI. Samples `CGWindowListCopyWindowInfo` + process CPU/RSS at 1–240 Hz into CSV. Used to observe *real on-screen window positions*. |
| `analyze.py` | stdlib-only analyser for the sampler CSV: interval stats, motion episodes, per-window deltas, direction reversals, adjacent gaps/overlaps. |
| `spring_bench.rs` | Standalone bench of the **Rust** spring (`iume_spring_step`), which the app currently does not call. Kept to prove parity and frame-rate behaviour of the Rust implementation. |
| `run-layout-tests.sh` | Compiles and executes layout parity checks (75 checks) covering bounds, sliver clamps, loops, and margins. |
| `run-physics-tests.sh` | Compiles and executes physics checks (261 checks) covering closed-form springs, direct-touch resampling, gestures, and clamps. |
| `run-window-tests.sh` | Compiles and executes window pipeline checks (39 checks) covering D05 AX reliability, bounded retries, and settle verification. |
| `run-all-tests.sh` | Unified test gate executing all 4 test suites back-to-back (411 checks total), exiting 0 on all-pass or 1 on failure. |
| `run-baseline.sh` | Wraps the above into a timestamped `baseline-before-*.md` report. |

## Quick start

Headless controller/layout benchmark (works without Xcode):

```sh
./scripts/audit/run_scroll_bench.sh
# JSON lines, plus a copy at $TMPDIR/iume-scroll-bench/results-release.jsonl
```

Live window sampler (needs a logged-in GUI session; **does not** need Accessibility):

```sh
cd scripts/audit
swiftc -O -parse-as-library window_sampler.swift -o .build/window_sampler
./.build/window_sampler --duration 10 --hz 60 --out /tmp/iume.csv          # all windows
./.build/window_sampler --pid $(pgrep -x Iume) --duration 10 --hz 60 --out /tmp/iume.csv
python3 analyze.py /tmp/iume.csv
```

## Compiling against prebuilt artifacts (no Xcode)

`swift test` cannot build on a Command-Line-Tools-only machine: `@State` requires the
`SwiftUIMacros` plugin that ships with Xcode. The checked-in `.build/` artifacts can still
be linked, which is what `run_scroll_bench.sh` does:

```sh
swiftc -O \
  -I .build/release \
  -Xcc -fmodule-map-file=.build/out/Intermediates.noindex/GeneratedModuleMaps/CIumeEngine.modulemap \
  -L .build/release -lIumeCore \
  -L crates/iume_engine/target/release -liume_engine \
  -o /tmp/bench scripts/audit/scroll_bench.swift
```

## Permissions

* **Window sampler** — `CGWindowListCopyWindowInfo` returns bounds, PID and layer without any
  permission. `kCGWindowName` (not used here) needs Screen Recording. If owner names come back
  empty, grant Screen Recording to the terminal, but the geometry is still valid.
* **Scroll benchmark** — none. It never opens a window, an event tap, or a display link.
* **Instruments / `xctrace`** — requires Xcode. Not available on this machine
  (`xcode-select -p` → `/Library/Developer/CommandLineTools`).

## Caveats you must keep in mind when reading numbers

1. **Intent ≠ write ≠ pixels.** `WindowController` caches the frame it *meant* to write
   (`lastAppliedFrames`, `WindowController.swift:205`) and suppresses writes within 0.5 pt of that
   intent. A window that drops or times out a write is not retried until the intent moves >0.5 pt.
   Only `CGWindowListCopyWindowInfo` sees the result.
2. **`CGWindowList` is composited state, not vsync.** It is a synchronous WindowServer round-trip
   (cost grows with window count), it returns committed geometry, and its timestamps are absent.
   Deltas are quantized to the display refresh. A "dropped frame" derived from it is an
   estimate with a stated sampling floor, never a true hitch count.
3. **Coordinate space.** Iume works in top-left-origin Quartz coordinates (`DisplayManager`
   flips the AppKit origin). `CGWindowList` bounds are also top-left global, but they exclude
   menu-bar/Dock offsets that `NSScreen.visibleFrame` accounts for. Normalise before diffing.
4. **The benchmark uses the harness clock.** `displayLinkFired(timestamp:)` accepts an injected
   timestamp; the harness paces it against `CACurrentMediaTime()` so event-timestamp comparisons
   inside the controller stay honest. Synthetic time that runs faster than wall time changes the
   direct-touch detection and produces wrong results (this bit us once — see `04-baseline.md`).
