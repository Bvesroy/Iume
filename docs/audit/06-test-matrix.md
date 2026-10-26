# 06 — Feature verification, regression risks, and test matrix

> **Snapshot notice.** The “today” column describes fingerprint `81b51e78…` / the
> 2026-10-24 artifact. The scroll core changed at 23:07–23:12 (D01, D02, D09, D13 addressed in
> source, D21 deleted; D04 unchanged) and has not been rebuilt. See
> [`07-working-tree-drift.md`](07-working-tree-drift.md).

Test status on this machine: `swift test` **cannot build** (no Xcode → no `SwiftUIMacros` plugin),
so the Swift suite was **read, not executed**. `cargo test --release` = **30 passed**. All behavioural
evidence in this document comes from `scripts/audit/scroll_bench.swift` (headless, release
`libIumeCore.a`) and `scripts/audit/window_sampler.swift`.

---

## 1. Existing features vs verified functionality

| # | documented feature | where documented | verified how | result | verdict |
|---|---|---|---|---|---|
| 1 | Physical spring physics | `ARCHITECTURE.md:151,198`, `CHANGELOG:28` | headless `spring_settle`, rate sweep; code read | Monotone, accurate overshoot (0.65 pt vs 0.75 theoretical), settles in 420 ms, but 1.9× the labelled duration and frame-rate dependent | **works, mislabelled (D12, D13)** |
| 2 | Rust layout engine | `CHANGELOG:41` | `grep RustEngine` in `LayoutEngine.swift` | zero references | **not wired (D23)** |
| 3 | Rust spring on every frame | `CHANGELOG:43` | `grep RustEngine` in `ScrollController.swift`; `RustEngine.step` callers | zero references, zero callers | **not wired (D23)** |
| 4 | Viewport-aware window updates | `ARCHITECTURE.md`, `IUME_INVENTORY §3` | code read of `computeLayout` / `applyPhysicalWindowPositions` | `computeLayout` takes `viewportOffset` and is cheap (p95 43.5 µs); `computeSnapTarget` ignores loop mode; five `maxOffset` formulas | **partial (D08, D18)** |
| 5 | Magnetic snapping | `IUME_INVENTORY §7` | code read | `MagneticWindowEngine` (Rust-backed) is used for drag/chained frames, **not** by the scroll settle path; scroll snapping is `LayoutEngine.computeSnapTarget` | **different feature than documented** |
| 6 | Smoothness control | settings UI, `CHANGELOG` | headless 3-point sweep on touch and wheel | touch: **identical** at 0 / 0.75 / 1; wheel: first frame 24 → 11 → 6 pt, lag 0 → 27 → 68 pt | **partial (D04)** |
| 7 | Live preview | settings UI | not exercised (no UI automation) | code uses the same `computeLayout`; preview is not on the hot path | **unverified** |
| 8 | Freeze on release | `CHANGELOG:24` | code read + 3-setting matrix | implemented; fresh-install default contradicts the changelog; it silently overrides snap + momentum + boundary spring | **works, over-broad (D14, D15)** |
| 9 | Column snapping | settings, `CHANGELOG` | code read + headless projection | projection horizon exactly 0.18 s; **unreachable when freeze/freeform is on**; loop-blind | **partial (D07, D08, D14)** |
| 10 | Momentum scrolling | settings | headless momentum path + code read | native momentum is 1:1; custom coast uses `0.965^(dt·60)` and can double-integrate; **dropped entirely under freeze-on-release** | **partial (D14)** |
| 11 | Keyboard scrolling | `SHORTCUTS.md` | code read | implemented, but loop-blind and margin-blind; clamps against a different `maxOffset` | **partial (D17)** |
| 12 | 120 Hz ProMotion | code `:347`, `:361` | display capability check | this machine is 60 Hz — **cannot verify** | **unverified** |
| 13 | Async non-blocking window writes during motion | `IUME_INVENTORY §5.2` | code read | per-PID queue with latest-wins coalescing is real; but the 0.5 pt cache compares intent, not reality | **partial (D05)** |
| 14 | Offscreen parking / 12 pt sliver | `IUME_INVENTORY §7` | code read | implemented (`WindowController:266-296`), z-order signature-cached; two engines use different right edges | **works (minor inconsistency)** |

**Net:** of 14 documented behaviours, 3 are fully verified, 7 are partial/mislabelled, 2 are not
wired at all, and 2 cannot be verified on this hardware.

---

## 2. Defect → proving test matrix

`H` = headless harness (`scroll_bench.swift`, runs here), `X` = XCTest (`Tests/IumeCoreTests`,
needs Xcode), `S` = live sampler capture (needs A0).

| id | severity | proving test | type | scenario / assertion | today |
|---|---|---|---|---|---|
| D01 | P0 | `maxOffsetShrinkMidSpringKeepsOffsetInRange` | H+X | `scrollTo(1200)`, shrink `maxOffset` to 100 mid-flight → `0 ≤ offset ≤ 100` at rest | **fails** (1200) |
| D02 | P0 | `settleWithoutSnapStopsMotion` | H+X | `snapToColumn=false`, `freeze=false`, scroll, `settle()` → 1 idle frame later `isMoving == false`, spring velocity 0 | **fails** (`true`, 1152) |
| D03 | P0 | `loopDisabledWhenSingleColumn` | X | 1 column + `loopMode=true` → controller loop flag false; over-scroll clamps | untested |
| D04 | P1 | `burstyPacketsDoNotFreezeFrames` | H | 0/2 packet pattern → `frozenFrames ≤ 3`, `max Δ < 12 pt`, total within 1 pt | **fails** (29 / 19.2) |
| D05 | P1 | `failedWriteIsRetried` | X | writer returns `.cannotComplete` on first call → frame re-sent next tick and at settle | untested |
| D06 | P1 | `diagonalGestureHandsBackToApp` | H+X | 6 horizontal then 6 vertical packets → tap returns `false` for vertical, owner `.app` | untested |
| D07 | P1 | `settleVelocityIsContinuous` | H | first two deltas after settle within 25% of `v·dt` | **fails** (≈5%) |
| D08 | P1 | `snapTargetUsesLoopPeriod` | X | `loopMode=true`, `projected = period + 120` → target near `period + nearest` | untested |
| D09 | P1 | `settleTimerDoesNotFireDuringGesture` | X | arm wheel timer, deliver `phase 1`, advance run loop → `pendingDelta` survives | untested |
| D10 | P1 | `multitouchRegistrationIsIdempotent` | X | call `startMultitouchMonitoring()` twice → same device count | untested |
| D11 | P1 | `noObservablePublishDuringMotion` | X+S | 120-frame gesture → ≤ 2 `objectWillChange`, HUD ≤ 4 Hz | untested |
| D12 | P2 | `animationDurationMatchesSettleTime` | H | 0.15/0.22/0.30 → rest within ±15% of the label | **fails** (420 ms) |
| D13 | P2 | `springTrajectoryIsFrameRateIndependent` | H | 60/80/120/240 Hz positions at 50/100/200 ms spread < 5 pt | **fails** (106 pt) |
| D14 | P2 | `releaseModeMatrix` | X | (freeze, snap, momentum) → exactly one release behaviour; UI reports dependencies | untested |
| D15 | P2 | `freshInstallDefaultIsStable` | X | empty defaults and empty snapshot agree | **fails** (false vs true) |
| D16 | P2 | `singleWideColumnCanScroll` | X | 2000 pt column on 1400 pt screen → `maxOffset > 0` | untested |
| D17 | P2 | `keyboardCenteringMatchesScrollLimits` | X | keyboard and gesture agree on `maxOffset`; loop mode honoured | untested |
| D18 | P2 | `maxOffsetIsConsistentAcrossPaths` | X | 3 columns, 12 pt gap, 8 pt margins → all 5 paths equal | untested |
| D19 | P2 | `settleAppliesOncePerFrame` | X | count `applyPhysicalWindowPositions` per tick during settle → ≤ 1 | untested |
| D20 | P2 | `tapCallbackIsMainActorIsolated` | X | callback body asserts `Thread.isMainThread` | untested |
| D21 | P3 | — | — | dead code; remove | n/a |
| D22 | P3 | — | — | dead callback; remove or wire | n/a |
| D23 | P3 | doc check | H | `grep RustEngine Sources/IumeCore/LayoutEngine Sources/IumeCore/Controller` is empty | **fails the doc claim** |
| D24 | P3 | `signpostsEmit` | S | `log stream` shows `scroll.frame` at 60/120 Hz during a gesture | untested |

---

## 3. Existing Swift tests at risk (must be updated deliberately, not deleted)

| test | file:line | why it is at risk |
|---|---|---|
| `testDirectManipulationZeroInputLag` | `WorkspaceAndStateTests.swift:648` | asserts `currentOffset == smoothTargetOffset` **exactly** during touch. Phase 3.1 intentionally breaks that equality. Replace with: `|currentOffset − smoothTargetOffset| < 8.3 ms × |velocity|` and `frozenFrames ≤ 3` under bursty input. **Do not delete — the 1:1 displacement contract is the product.** |
| `testVelocityContinuityAcrossSettle` | `:631` | asserts `springState.velocity != 0` after hand-off. D07 may change the hand-off shape; the assertion should become "velocity at settle is within 20% of the pre-settle velocity" (it currently only checks non-zero). |
| `testIsMovingStates` | `:517` | drives `displayLinkFired` with synthetic timestamps at 120 Hz; with D13's sub-stepping the frame count changes but the assertion (`isMoving == false` at 500 pt) still holds. Keep as a canary. |
| `testMomentumDecoupling` | `:580` | depends on the 0.09 s watchdog and `isMomentumCoasting` transitions; D09 adds a phase guard, which must not change this path (phase is 4, not 1/2). Re-run. |
| `testAnimationCompletedCallback` | `:545` | depends on settle duration; D12 changes the mapping from `duration` to `response`. Update the expected duration in the same commit. |
| `ScrollLoopTests` (15 tests) | `ScrollLoopTests.swift` | only exercises `normalizedOffset` / `crossedLoopSeam`; no protection for D03/D08. Add the two loop tests there. |
| `ZOrderSignatureTests` (6) | `ZOrderSignatureTests.swift` | protects `enforceStripZOrder` caching; Phase 4 must keep them green. |
| `LayoutEngineTests` (18) | `LayoutEngineTests.swift` | pins layout geometry; D16/D18 change `maxScrollOffset`. Extend, don't weaken. |

**Coverage gap:** there is **no test** for `settle()` + `freezeOnRelease`, `maxOffset` shrinking,
loop eligibility, or `maxOffset` consistency. Those are the P0s.

---

## 4. Regression risk by change

| change | blast radius | existing tests that would catch a regression | manual check |
|---|---|---|---|
| 2.1 clamp at rest | spring only | none | harness `max_offset_shrink_midspring` |
| 2.2 zero spring on settle | `isMoving`, window adoption, reconcile, event tap | `testIsMovingStates` | new headless scenario |
| 2.3 loop eligibility | loop mode, all layout modes | `LoopLayoutTests` (13) | one-column live |
| 2.5 one `maxOffset` | scrolling, snapping, keyboard, scrub | `LayoutEngineTests`, `WorkspaceAndStateTests` | keyboard nav + drag |
| 3.1 touch resampling | **every gesture** | `testDirectManipulationZeroInputLag` must be rewritten | 10 min live feel test |
| 3.2 slider semantics | settings UX, wheel, settle | none | settings parity |
| 3.3 sub-stepped spring | all snap/keyboard motion | `testAnimationCompletedCallback` | harness rate sweep |
| 4.1–4.2 write retry | every window write | `ZOrderSignatureTests`, `WorkspaceAndStateTests` | Electron app |
| 4.4 de-`@Published` | HUD, status bar, settings observers | `MinimapHUDAndDialTests` (27) | HUD during scroll |

---

## 5. Proposed CI gate (works without Xcode)

`scripts/audit/run_scroll_bench.sh` already emits JSON lines. Phase 5 turns it into a pass/fail gate:

```
gate 1  direct_1to1_120hz            |final − expected| < 1 pt, frozenFrames == 0
gate 2  direct_bursty_packets        frozenFrames ≤ 3, max Δ < 12 pt, |final − expected| < 1 pt
gate 3  max_offset_shrink_midspring  0 ≤ final ≤ maxOffset
gate 4  settle_snap_disabled         isMoving == false, springVelocity == 0
gate 5  spring_settle_rate_sweep     spread < 5 pt at 50/100/200 ms
gate 6  layout_compute_cost_24_columns  p95 < 2000 µs on this class of machine
gate 7  spring_settle                |elapsedMs − animationDuration·1000| < 20%   (after D12)
```

Gates 1 and 2 encode the two halves of the contract: **exact total displacement, bounded frame
jitter**. Any change that satisfies 2 by losing 1 is rejected.

`cargo test --release` (30 tests) stays as-is; it already pins Swift↔Rust layout parity and should
not be extended for Swift-only changes.

---

## 6. Interactive test script (for when A0 is approved)

Run once per build, 5 minutes, one Space:

1. Launch Iume (no `--kickstart`), grant Accessibility, close all other apps.
2. Open 6 windows across 3 apps, including one Electron app (Slack/VS Code).
3. `window_sampler --pid $(pgrep -x Iume) --hz 60 --duration 15 --out scroll.csv` while:
   * slow 2-finger drag right for 3 s (the D04 case);
   * one fast flick (momentum + settle);
   * three rapid alternating flicks (retarget/cancel);
   * keyboard `Ctrl+Opt+→` five times;
   * one diagonal gesture (D06);
   * then idle 5 s.
4. `python3 analyze.py scroll.csv` → check: interval p95, frozen-frame ratio, direction reversals
   per moving step, adjacent gap/overlap, settle duration, idle CPU fall to < 1%.
5. Repeat on a 120 Hz display when one is available (this machine cannot).

Expected signatures to look for: reversal ratio > 0.15 on a monotonic gesture = D04/oscillation;
a gap > configured gap + 2 pt after a settle = D05; CPU staying > 3% while idle = D02 (display link
awake).
