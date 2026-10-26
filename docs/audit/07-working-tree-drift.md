# 07 — Working-tree drift during the audit (must read before acting on 01–06)

> **Historical.** This timeline is superseded by `10-phase2-verification.md`, which records the
> Phase 2 fixes, the final harness evidence and the Phase 3 decision. Keep this file for the
> chronology; do not use its "recommended next step" as current status.

**This document records a material event: the scroll core was rewritten by a concurrent
process while Phase 1 was being documented.** The audit snapshot and the current tree are
not the same code.

## 1. Timeline

| time (local) | event |
|---|---|
| 22:47–23:03 | Phase 1 baseline runs; final release artifact run at **23:03**. Source fingerprint `81b51e7873106dbe1d879228d3a6407fde64aa4c`. Prebuilt binaries dated **2026-10-24 20:09**. |
| 23:04–23:09 | `docs/audit/01`–`06` written against that fingerprint. |
| **23:07:20** | New file `Sources/IumeCore/Physics/SpringState.swift` appears (analytic spring). |
| **23:08:41 → 23:11:55** | `Sources/IumeCore/Controller/ScrollController.swift` is rewritten in at least six successive writes: `MotionPhase` state machine, `gestureGeneration`, closed-form coast, `finishSpring`, `queryMaxOffset`, settle rewrite. |
| **23:18:33** | `Sources/IumeCore/Controller/WindowController.swift` is rewritten: settle writes now read the actual AX frame and repair once (`verifyAndRepair`, `readFrame`, `frameMatches`). D05 is partly addressed. |
| 23:11:08 / 23:13 | Snapshot taken for `ScrollController.swift`. `ScrollController.swift` sha256 `ce3ae8ea…`; `SpringState.swift` sha256 `af3799b2…`. |

Both files are still **untracked/modified in the working tree** and were **not** built:
`.build/release/libIumeCore.a` is still the 2026-10-24 artifact. Every number in
`04-baseline.md` therefore describes the **pre-drift** code, not the current tree.

> The tree was still being modified at **23:21:28** (a further display-link screen-id guard in
> `ScrollController`). This document freezes status at the timestamps shown; the status table is
> as of the 23:13/23:18 snapshots. Run `git status` and check mtimes before acting on any row.

This session did not make these edits. It only added `scripts/audit/*` and `docs/audit/*`.
Whoever owns the concurrent process must reconcile the two efforts.

## 2. What the new code changes

`ScrollController.swift` (as of the 23:13 snapshot):

* one private `MotionPhase` (`idle / interactive / tracking / decelerating / springing`);
  `isSwipingInteractively`, `isSpringAnimating`, `isMomentumCoasting`, `isActivelyScrolling`
  are now derived from it — the old independent booleans are gone;
* `SpringState` moved out to `Sources/IumeCore/Physics/SpringState.swift` and its `step` is now
  the **closed-form** solution (under/critically/over-damped), with `maxFrameDelta = 1/30` and
  NaN repair;
* `stepDeceleration` integrates the exponential decay in closed form instead of
  `v *= 0.965; x += v·dt`;
* `finishSpring()` re-queries `onQueryMaxOffset` and re-clamps the destination at rest;
* `settle()` zeroes `springState.position/target/velocity` on **every** exit branch, and bumps
  `gestureGeneration`;
* settle/watchdog callbacks are generation- and phase-guarded;
* `CriticallyDampedSpring` was deleted.

`WindowController.swift` (as of 23:18):

* `WindowWriter` gains a `pendingSettleFrame` path that, on the app's own serial queue,
  reads `kAXPositionAttribute`/`kAXSizeAttribute`, compares against the requested frame
  (1 pt tolerance) and re-writes once if the app rejected or delayed the motion frame
  (`verifyAndRepair`). This is the first read-back path in the app.

## 3. Finding status against the 23:13 snapshot

“Addressed” here means **the source no longer exhibits the defect by inspection**. It does
**not** mean fixed: nothing has been compiled, run, or measured since the rewrite.

| id | status in new tree | evidence |
|---|---|---|
| D01 spring completion leaves offset out of range | **addressed in source, unverified** | `stepSpring` re-clamps target each frame (`ScrollController.swift:626-632`); `finishSpring` re-queries max and clamps (`:662-688`) |
| D02 `settle()` leaves `springState.velocity` set | **addressed in source, unverified** | `settle()` `:1152-1217` zeroes position/target/velocity in freeze, boundary, snap and no-snap branches |
| D03 controller loop mode vs layout eligibility | **open** | `WorkspaceManager.swift:3052` still sets the controller flag from the setting alone; `LayoutEngine` predicate unchanged |
| D04 direct touch is raw 1:1, packet jitter passes through | **open — unchanged** | `stepTracking` `:537-543`: `if isDirectTouch … currentOffset = smoothTargetOffset` |
| D05 write-intent cache never reads actual frames | **partially addressed in source, unverified** | motion writes still use the 0.5 pt intent cache; settle now verifies the real AX frame and repairs once (`verifyAndRepair` `WindowController.swift:181-211`, `settleFrameAsync` `:626-643`) |
| D06 gesture ownership one-way latch | **partially addressed** | `.app → .strip` breakout added (`:1277-1286`); `.strip → .app` hand-back still absent (`:1252-1265` returns `true` unconditionally) |
| D07 hard-coded 0.18 s projection | **open** | `settle()` `:1207-1209` still `base + velocityAtSettle * 0.18` |
| D08 `computeSnapTarget` called without `loopMode:` | **open** | `WorkspaceManager.swift:746` unchanged |
| D09 settle/watchdog timers not phase-guarded | **addressed in source, unverified** | `gestureGeneration` guards at `:1086`, `:1102`, `:1118`; `phase == .tracking` check |
| D10 unretained tap pointer / duplicate MT registration | **open** | `passUnretained(self)` still at `:1318` |
| D11 per-frame `@Published` + expected-frame + HUD | **open** | `WorkspaceManager.swift:688-704` unchanged; `publish` still calls `onViewportOffsetChanged` every frame |
| D12 `animationDuration` is a period | **open** | `:816-817` unchanged |
| D13 frame-rate-dependent spring | **addressed in source, unverified** | closed-form `SpringState.step`; still `dt`-clamped at 1/30 |
| D14 `freezeOnRelease` overrides snap/momentum | **open** | settings untouched |
| D15 fresh-install default contradiction | **open** | settings untouched |
| D16 single-column `maxScrollOffset == 0` | **open** | `LayoutEngine.swift:94` now `guard columns.count > 1` (same behaviour) |
| D17 keyboard centring loop/margin blind | **open** | `WorkspaceManager.swift:1600-1612` unchanged |
| D18 five `maxOffset` formulas | **partially addressed** | scrub path now uses `maxScrollOffset` with usable width (`WorkspaceManager.swift:352-356`); the other four sites remain |
| D19 settle applies windows synchronously in the tick | **open** | `onSettleRequested` unchanged |
| D20 `shouldInterceptScroll` off-main-actor call | **open** | tap body still calls it before any marshalling |
| D21 dead `CriticallyDampedSpring` | **addressed (deleted)** | no longer in the tree |
| D22 `onSwipeSettled` has no consumer | **open** | still fired in `settle()`; still no assignment in `Sources/` |
| D23 Rust engine not on the scroll path (docs false) | **open** | `LayoutEngine`/`ScrollController` still do not reference `RustEngine` |
| D24 no signposts/OSLog | **open** | zero matches |

Net: **4 defects (D01, D02, D09, D13) plus one dead-code removal (D21) are addressed in
source; 3 are partially addressed (D05, D06, D18); 16 remain fully open.** The top
user-visible issue for this machine’s settings — D04, raw 1:1 touch with no jitter absorption —
is untouched.

## 4. New risks introduced by the rewrite

1. **Unbuilt, untested core.** The last `.a` predates the rewrite. `swift test` cannot build
   here (no Xcode), so the new state machine has **zero** execution evidence. Do not ship it on
   inspection alone.
2. **`swift test` line references in `06-test-matrix.md` may no longer match** the rewritten
   `ScrollController` (e.g. `testDirectManipulationZeroInputLag` still asserts the old 1:1
   equality; it will pass against the new code only because D04 is unchanged).
3. **`isMoving` gained a new condition** (`abs(smoothTargetOffset - currentOffset) > 0.05`).
   That is reasonable, but it means the idle gate now depends on filter convergence; a filter
   that stalls (e.g. `dt == 0` or non-finite input) keeps `isMoving == true` and therefore keeps
   window adoption and reconciliation disabled. Needs a test.
4. **`stepTracking` still assigns `springState.velocity = currentVelocity` every frame** while
   `phase == .tracking`; a later `settle()` now clears it, but a direct `scrollTo()` during
   tracking must reset it too — verify.
5. **`finishSpring()` can return early after retargeting** (`:672-676`) without publishing the
   corrected target; if the display link pauses in that window the strip can sit one frame
   before the new destination. Low risk, worth a test.
6. **No parity check with the Rust spring.** The Swift spring is now a third distinct
   integrator (after the old Swift one and the Rust one); the Rust crate still has its own
   frame-rate-dependent implementation. `cargo test` still passes but proves nothing about the
   new Swift code.

## 5. What to do with 01–06

* **01–04** remain a valid record of the **pre-drift** baseline. Read them as “what the shipped
  artifact does”, not “what the tree does now”.
* **05 (phase plan)** still applies, but Phase 2 items 2.1, 2.2 and 2.7, Phase 3 item 3.3 and
  part of Phase 4 item 4.2 are already in the new source; the plan should be re-based on the new
  tree before implementation starts.
* **06 (test matrix)** still applies; its “today” column is the pre-drift behaviour. The new
  code needs the same gates run after a build.

## 6. Recommended next step (before any further implementation)

1. Stop concurrent edits to the scroll core; freeze a commit or a patch of the current tree.
2. Build it on a machine with Xcode (`swift build` / `swift test`) — this machine cannot.
3. Re-run `./scripts/audit/run_scroll_bench.sh` against the **rebuilt** artifact and diff every
   scenario against `04-baseline.md`.
4. Only then decide whether the rewrite is the new baseline or should be rebased onto the
   Phase 2–5 plan.

Until step 3 is done, the honest statement is: **the pre-drift system is measured and
defective; the current tree is unmeasured.**
