# 04 — Measured baseline

> **Snapshot notice.** Every number here was produced from the **2026-10-24 20:09**
> `libIumeCore.a`, i.e. the pre-drift source (`81b51e78…`). The scroll core was rewritten at
> 23:07–23:12 and has not been rebuilt. These numbers do not describe the current tree.
> See [`07-working-tree-drift.md`](07-working-tree-drift.md).

Everything here is measured on this machine, from the shipped artifacts, with the harness in
`scripts/audit/`. Nothing is estimated unless it is explicitly labelled `HYPOTHESIS`.

## 1. Environment

| | |
|---|---|
| commit | `9992c80` |
| source fingerprint | `81b51e7873106dbe1d879228d3a6407fde64aa4c` (working tree, includes the uncommitted edits) |
| artifact | `.build/release/libIumeCore.a`, built 2026‑10‑24 20:09 |
| macOS | 27.0.1 (arm64) |
| CPU | Apple M4 |
| Swift | 6.4 (swiftlang‑6.4.0.34.1) |
| Rust | 1.99.1 |
| display | 1470×956 pt, pixel 2940×1912, **60 Hz** (`NSScreen.maximumFramesPerSecond == 60`) |
| `swift test` | **cannot build** — `@State` needs the `SwiftUIMacros` plugin; only Command Line Tools are installed (55 compile errors, `MinimapLoopCarouselView.swift:179` first) |
| `cargo test --release` | **30 passed, 0 failed** |
| `xctrace` | unavailable (requires Xcode) |

Because SwiftPM cannot build here, the benchmark links the prebuilt `.a` directly:

```sh
swiftc -O -I .build/release \
  -Xcc -fmodule-map-file=.build/out/Intermediates.noindex/GeneratedModuleMaps/CIumeEngine.modulemap \
  -L .build/release -lIumeCore -L crates/iume_engine/target/release -liume_engine \
  -o $TMPDIR/iume-scroll-bench/scroll_bench scripts/audit/scroll_bench.swift
```

## 2. Settings in effect during the run

The benchmark mutates `SettingsStore.shared`, so `run_scroll_bench.sh` snapshots and restores the
real `com.iume.Iume` domain and `settings_memory.json` around every run. The durable snapshot
(`~/Library/Application Support/Iume/settings_memory.json`, unchanged since 20:25) is:

```
freezeOnRelease        true
snapToColumn           true
scrollSmoothness       1.0
scrollSensitivity      1.2
momentumScrolling      true
animationDuration      0.22
trackpadNaturalScroll  true
scrollTriggerMode      seamlessHorizontal
freeformScroll         true
loopMode               true
```

**This matters for interpretation.** `WorkspaceManager.swift:712` takes the no-snap branch when
`freezeOnRelease || freeformScroll || !snapToColumn`. Here `freezeOnRelease` and `freeformScroll`
are both true (and `snapToColumn` is true, but the branch is already taken), so on this user's
machine the settle path never runs the projection, the spring, or column snapping: on release it
calls `setOffset(currentOffset)` and stops. The spring/snap findings below are real but
are **latent for this configuration**; the gesture-path findings (D04) are the ones that govern
perceived smoothness here.

## 3. Direct finger tracking

`scroll_bench.swift` → `direct_1to1_120hz`, 60 events of 8 pt at a real-time 120 Hz cadence,
sensitivity 1.2, smoothness 0.75:

| metric | value |
|---|---|
| expected offset | 576.0 pt |
| final offset | 576.0000000000007 pt |
| lag at end | −5.7e‑13 pt |
| per-frame delta | 9.6 pt, sd 1.3e‑14 |
| frozen frames | 0 |

**Verdict: the direct-touch path is exactly 1:1 with zero added lag.** This is the good part of the
design and must be preserved by any fix.

### 3.1 Same mean rate, realistic packet pattern

`direct_bursty_packets`: alternating frames with 0 packets and 2 packets, same 480 pt/s mean:

| metric | value |
|---|---|
| events | 60 (30 frames × 2) |
| frames | 60 |
| frozen frames (Δ < 0.001) | **29 of 59** |
| frames with Δ > 12 pt | **30** |
| per-frame Δ | min 0, p50 19.2, max 19.2, sd 9.60 |
| final offset | 576.0 pt (correct total) |

**Verdict: the total displacement is correct but the distribution is not.** Half the frames do not
move and the other half move twice as far. This is the measured stutter mechanism (finding D04), and
it is the correct behaviour *for a raw 1:1 path* — which is exactly why the raw path is the problem.

### 3.2 Smoothness has no effect during touch

`scrollsmoothness_direct_touch`, three runs at smoothness 0 / 0.75 / 1:

| smoothness | final offset | ideal | lag at end | Δ per frame |
|---:|---:|---:|---:|---|
| 0.00 | 345.6 | 345.6 | 3.4e‑13 | 7.2 (sd 6.5e‑15) |
| 0.75 | 345.6 | 345.6 | 3.4e‑13 | 7.2 (sd 6.5e‑15) |
| 1.00 | 345.6 | 345.6 | 3.4e‑13 | 7.2 (sd 6.5e‑15) |

**Verdict: identical.** The `smoothness` slider is inert for finger-driven motion
(`ScrollController.swift:492-499` bypasses the filter). It only affects wheel/momentum and the
settle spring.

## 4. Smoothness *does* work on the wheel/coast path

30 notched-wheel events of 20 pt at 120 Hz:

| smoothness | first-frame offset | target lag p50 | target lag p95 | final offset after 30 frames |
|---:|---:|---:|---:|---:|
| 0.0 | 24.00 | 0.00 | 0.00 | 720.00 |
| 0.5 | 11.15 | 26.53 | 27.11 | 693.27 |
| 1.0 | 6.07 | 67.01 | 68.85 | 651.09 |

**Verdict: the control is real and monotonic on this path** — it trades first-frame response
(24 → 6 pt) for lag (0 → 68 pt). At smoothness 1 the strip is ~68 pt behind the input at the end of
a 30-event burst; that is ~3.5 wheel notches of lag. Whether that is acceptable is a product
decision, but it is a *large* value for a control labelled "smoothness".

## 5. Spring settle

`spring_settle`, target 1200 pt, `animationDuration = 0.22`, smoothness 0.75:

| initial velocity | frame 0 offset | frames | time to rest | max overshoot | path length |
|---:|---:|---:|---:|---:|---:|
| 0 | 45.70 | 50 | **420.48 ms** | 0.651 | 1149.5 |
| +800 | 50.18 | 49 | 416.55 ms | 0.643 | 1144.5 |
| −800 | 41.22 | 50 | 420.94 ms | 0.646 | 1154.5 |

Observed facts:

1. **The labelled 0.22 s produces 0.421 s of motion** (1.9×). `duration` is used as the oscillator
   *period*, not as a settle time (D12).
2. **Initial velocity has almost no effect**: ±800 pt/s moves frame 0 by ±4.5 pt and changes the
   duration by ≤ 4.4 ms. The finger-lift velocity is therefore not perceptually continuous (D07).
3. Overshoot is 0.65 pt against a theoretical 0.75 pt for ζ = 0.92 — the integrator is accurate;
   the spring is simply slow.

### 5.1 Frame-rate dependence

Same settle, synthetic timestamps at four rates:

| rate | frames | time to rest | pos @50 ms | pos @100 ms | pos @200 ms |
|---:|---:|---:|---:|---:|---:|
| 60 Hz | 22 | 350 ms | 579.1 | 951.3 | 1177.6 |
| 80 Hz | 34 | 412 ms | 709.5 | 1024.5 | 1188.9 |
| 120 Hz | 50 | 408 ms | 685.3 | 1025.0 | 1191.7 |
| 240 Hz | 96 | 396 ms | 657.6 | 1026.1 | 1194.6 |

**The same animation is 58 ms faster at 60 Hz and is 106 pt behind at the 50 ms mark.** Frame-rate
dependence is real (D13). At 200 ms the spread is ~17 pt; by 350 ms it converges.

## 6. State-integrity failures

### 6.1 `maxOffset` shrinking mid-spring

```
scrollTo(target: 1200, maxOffset: 20_000) → 6 frames → maxOffset = 100 → run to rest
result: finalOffset = 1200, maxOffset = 100, exceedsMaxOffsetBy = 1100, isMoving = false
```

**The viewport is left 1100 pt out of range and reports itself stopped.** No callback will fire to
correct it (finding D01).

### 6.2 `settle()` with snapping disabled

```
offsetBeforeSettle           576
currentVelocityBeforeSettle  1152
isMovingImmediatelyAfter     true
springVelocityAfterSettle    1152
springIsAtRest               false
isMovingAfter1sIdle          true
callbacksDuring1sIdle        0
```

**`isMoving` never returns to false.** Because `WorkspaceManager` gates window adoption,
reconciliation and the event-tap restart on `!isMoving` (`:385-392`), the app stops managing new
windows until the user scrolls again (finding D02).

### 6.3 Settle projection horizon

```
offset 576.0, velocity 1152.0  →  projectedOffset 783.36
(783.36 − 576.0) / 1152.0 = 0.180000 s
```

**Exactly 0.18 s**, hard-coded at `ScrollController.swift:1075`. Velocity at the callback is the full
1152 pt/s, so the projection is the only place the hand-off velocity survives.

## 7. Layout cost (the one thing that is not the bottleneck)

`layout_compute_cost_24_columns`, release, 600 iterations, 24 single-window columns:

| metric | µs |
|---|---:|
| mean | 21.61 |
| p50 | 15.33 |
| p95 | 43.54 |
| max | 2089.04 |
| budget at 120 Hz | 8333 |

**`computeLayout` uses ~0.52% of a 120 Hz frame at p95.** The 2.09 ms max is a scheduler outlier
(single sample), not layout work. Optimising layout math is not the path to
smoother scrolling. The remaining per-frame cost is window application (AX), the `@Published`
workspace write and the HUD (D11), none of which is measurable without the app running.

## 8. Rust spring (not on the app's scroll path)

`spring_bench.rs`, real `crates/iume_engine` sources, settle to 0.4 pt:

| distance | 60 Hz | 80 Hz | 120 Hz | 240 Hz |
|---|---:|---:|---:|---:|
| 100 pt | 333 ms / 0.00 pt | 312 / 0.00 | 292 / 0.00 | 271 / 0.00 |
| 500 pt | 367 / 0.00 | 350 / 0.05 | 325 / 0.10 | 296 / 0.17 |
| 2000 pt | 400 / 0.22 | 363 / 0.30 | 433 / 0.52 | 421 / 0.79 |
| 20000 pt | 583 / 2.39 | 562 / 3.45 | 542 / 5.16 | 512 / 7.92 |

(format: elapsed / overshoot)

Also measured in that harness:

* position spread at 100 ms across 60→240 Hz: **24.9 pt**;
* max single-frame displacement on a direction reversal: **165.5 pt**;
* rapid retarget every 16 ms: max single-frame displacement **61.1 pt**, final error **−21.3 pt**;
* a 10 s stall leaves the spring at 245 pt of a 1000 pt target (the `dt` clamp means it does not
  jump, but it also does not catch up in wall-clock time).

**The Rust spring is frame-rate dependent too** (D13 applies to both implementations), so switching
to it is not a fix for D13 by itself.

## 9. Live window sampler

Validated on this machine (app not running; sampling all on-screen windows):

```
99 samples in 4.853 s → 20.2 Hz achieved (requested 20)
5 distinct windows, 495 rows
CGWindowList call cost: p50 0.610 ms, p95 0.934 ms, max 5.784 ms
deadline overruns: 1
display: 1470×956 pt, pixel 2940×1912, 60.00 Hz
```

`analyze.py` consumed the file and produced interval stats, per-window deltas and gap/overlap
series. **No Iume motion was captured** — the app was not launched (it retiles every window and
needs Accessibility; see approval §A0).

## 10. What is NOT measured (do not infer)

* Input-to-*photon* latency, true dropped frames, present timing — requires Instruments, which
  requires Xcode (absent).
* 120 Hz ProMotion behaviour — this panel is 60 Hz.
* Per-app AX write latency, Electron behaviour, many-window behaviour — requires the app running.
* Window overlap/gap and oscillation in a real strip — sampler is ready, no capture taken.
* Main-thread cost of `objectWillChange`, `recordExpectedFrame`, HUD update — D11 magnitude.
* Whether multitouch and synthetic scroll events double-apply on one physical gesture.

## 11. Harness failures found and corrected (so they are not repeated)

1. **Synthetic clock faster than wall time.** The first run injected timestamps at exactly 1/120 s
   without sleeping. `ScrollController` compares event timestamps to `CACurrentMediaTime()`, so
   every later event looked "stale" and the direct-touch branch was never taken; the harness
   reported a 183 pt lag that does not exist. Fixed by pacing injection against
   `CACurrentMediaTime()`. **Any future harness must do the same.**
2. **Settings leakage into the real app domain.** The first run wrote `SettingsStore.shared` values
   straight into `com.iume.Iume`. Fixed by snapshotting `defaults export` and `settings_memory.json`
   and restoring on `EXIT/INT/TERM`. The durable snapshot was verified unchanged after the runs.
3. **Release vs debug artifact.** The first results came from `libIumeCore.a` (debug) while the
   header said `release`. Fixed by parameterising `IUME_BENCH_BUILD` and reporting
   `buildConfiguration` in every record.

## 12. Reproduction

```sh
cd /Users/bves/projects/Iume
./scripts/audit/run_scroll_bench.sh          # ~90 s, restores settings on exit
# results: $TMPDIR/iume-scroll-bench/results-release.jsonl
```

Raw logs: `$TMPDIR/iume-audit/swift-test.log` (55 macro errors, first at
`MinimapLoopCarouselView.swift:179`), `$TMPDIR/iume-audit/cargo-test.log`,
`$TMPDIR/iume-audit/sample.csv` + `sample-analysis.txt` (sampler validation), and
`scripts/audit/baseline-before-*.md` (timestamped environment report).
