# 10 — Phase 2 verification and Phase 3 go/no-go

**Date:** 2026-10-26
**Status:** Phase 2 P0 changes are present and pass the executable audit harness; the full
SwiftPM target and the live app remain unverified on this machine.
**Supersedes:** `07-working-tree-drift.md` (historical timeline only).

> `08-phase3-direct-touch.md` and `09-phase4-triage.md` are the concurrent writer's Phase 3/4
> documents. This file is the independent Phase 2 gate and does not overwrite them. The
> `08` name originally proposed for this report was already in use, so the report is `10`.

---

## 1. Verdict

| question | answer |
|---|---|
| Are the Phase 2 P0 code changes in the working tree? | **Yes** — D01, D02, D03 and D09 are implemented in `ScrollController`, `LayoutEngine`, `WorkspaceManager` and `StatusBarController`. |
| Are they proven by executable checks? | **Yes, at harness level** — 411/411 in the unified gate; see §3–§5. The harness compiles the real `ScrollController`, `SpringState`, `LayoutEngine` and models. |
| Are they proven by the real test target? | **No** — `swift test` cannot build without Xcode's `SwiftUIMacros` plugin. |
| Is the live app verified? | **No** — the app was not launched, Accessibility permission was not granted, and the only display is 60 Hz. |
| Phase 3 decision | **NO-GO for sign-off or release; conditional GO only for a bounded verification pass.** The Phase 3 code is already present in the tree from the concurrent writer, but it is a candidate, not a delivered phase. |

The honest summary: **Phase 2 correctness is green in the harness and unverified in the product.**
No correctness check in this report proves that scrolling feels smooth in the app.

---

## 2. Snapshot and environment

| item | value |
|---|---|
| repository | `/Users/bves/projects/Iume` |
| branch | `main` |
| HEAD | `9992c8054f58f24e83e8a342f131d6719254c898` |
| checkpoint | `afde63f` on `checkpoint/phase2-20261025T182303Z` (byte-exact snapshot taken before Phase 2 edits) |
| working tree | dirty; Phase 2 edits are uncommitted and mixed with concurrent-writer Phase 3/4 edits |
| OS | macOS 27.0.1 (26A434) |
| Swift | 6.4 (swiftlang-6.4.0.34.1, clang-2100.3.34.1), target `arm64-apple-macosx27.0.0` |
| toolchain path | `/Library/Developer/CommandLineTools` (no full Xcode) |
| display | 1470×956 pt, 2940×1912 px, **60 Hz** (`NSScreen.maximumFramesPerSecond == 60`) |

The tree is shared with a concurrent writer. During this verification it changed
`ScrollController.swift`, `SettingsView.swift`, `scripts/audit/harness/main.swift` and added
`scripts/audit/harness/AdversarialStressTests.swift`. Commands below were run against a
hash-stable snapshot; any run that overlapped a write was discarded.

### Final verified snapshot

| file | SHA-1 | note |
|---|---|---|
| `Sources/IumeCore/Controller/ScrollController.swift` | `0296dd7a887a256e5e4a51b2cf604ee1c19d7246` | the controller used for every motion result below |
| `Sources/IumeCore/Physics/SpringState.swift` | `d0015ea177532a6f64b1143c811281d88c83912b` | analytic solver |
| `scripts/audit/harness/main.swift` | `bac113797632165c5d446de74377d7ed374d5a9e` | 261-check suite |
| `scripts/audit/harness/AdversarialStressTests.swift` | `4452221dfeee411faf8cdf8229895826d2412bc6` | 89-check stress suite |
| `scripts/audit/harness/Stubs.swift` | `697604087d2b9ad83f2436a9886e565b1956561d` | settings stub |
| `Sources/IumeCore/LayoutEngine/LayoutEngine.swift` | `3b693c6f2202e8fb3641a73cc80672a23586ed09` | geometry gate, including the single-column snap fix below |

The writer's final scroll-core change (`f4b11fe…` → `3fa1abc…` → `0296dd7a…`) extended the
stray-lift guard from `.idle` to `.idle || .springing` and added the D06 diagonal-intent resets.
The final runs below include those changes. `LayoutEngine` was then corrected in this review so a
single wide column's snap target no longer erases its own range; the physics harness does not
compile `LayoutEngine`, so its result is unaffected.

---

## 3. Commands and exit codes

Raw output is in `docs/audit/logs/`.

| command | result | exit |
|---|---|---|
| `./scripts/audit/run-physics-tests.sh` | **261 checks pass** | 0 |
| same harness with `runAdversarialStressTests()` injected | **350 checks pass** | 0 |
| `./scripts/audit/run-layout-tests.sh` | **75 checks pass** | 0 |
| `./scripts/audit/run-all-tests.sh` | **411 checks pass** (75 layout + 261 physics + 39 window/AX + 36 Rust) | 0 |
| `cargo test --release --manifest-path crates/iume_engine/Cargo.toml` | 36 pass, 0 failed | 0 |
| `swift build` | fails: `SwiftUIMacros.StateMacro` plugin not found | 1 |
| `swift test` | fails for the same missing macro plugin | 1 |
| `swiftc -parse` on both new test files | both parse | 0 |
| Testing-stripped `swiftc -typecheck` on both new test files | both typecheck against the real sources | 0 |

The default physics runner compiles `AdversarialStressTests.swift` but `main.swift` no longer
calls `runAdversarialStressTests()` (the writer removed the call during recovery). The 350-check
row is an independent run of the same snapshot with the call injected before the result print;
the 261-check row is the literal default command. Both exit 0.


The typecheck row is not a substitute for `swift test`: it strips `@Test`, `@Suite` and converts
`#expect` to a no-op function, then compiles the file against a module built from the production
sources. It catches API/signature mistakes; it does not execute the expectations.

---

## 4. P0 changes and where they live

### D01 — clamp after a geometry change and at completion
- `ScrollController.finishSpring()` re-queries the maximum offset before writing the final
  position and clamps a linear strip to `[0, maxOffset]`.
- `cancelAnimation()` and the freeze branch call `clampRestingOffsetIfNeeded()`; the linear
  overshoot branches re-target through `scrollTo`, which clamps to `[0, maxOffset]`; the
  snap/no-snap branches run after loop normalization and leave the controller idle.
- `WorkspaceManager` re-publishes bounds through `refreshScrollBounds(for:)`; the controller's
  parked offset is repaired after a shrink.

### D02 — every settle exit agrees with `isMoving`
- `settle()` sets `phase = .idle`, zeroes `springState.position/target/velocity`, and zeroes
  `currentVelocity` on every branch.
- The non-snap branch and the freeze branch both leave `isMoving == false` and
  `springState.isAtRest == true`.
- `settleVelocity` is deliberately **not** cleared in the snap branch: it is the documented
  handoff consumed by the next `scrollTo` (`testVelocityContinuityAcrossSettle`). It is not a
  motion flag; `isMoving` no longer reads it.
- `finishUnclaimedSettle()` clears the handoff only after an interactive lift whose callbacks
  started no spring.

### D03 — one loop-eligibility predicate
- `LayoutEngine.isLoopEligible(columns:visibleWidth:layoutMode:gap:)` is the single predicate:
  strip layout, at least two columns, period at least the visible width.
- `LayoutEngine.ScrollBounds` carries `loopEligible`; `WorkspaceManager.refreshScrollBounds` sets
  `scrollController.isLoopModeEnabled` from it, never from the raw setting.
- `computeViewportOffset`, `computeSnapTarget` and the keyboard/scrub paths receive the same
  `loopEligible` value; `computeLayout` is position-only and does not wrap.

### D08 — loop-aware snap target
- `WorkspaceManager` passes `loopMode: bounds.loopEligible` to `computeSnapTarget`.
- `computeSnapTarget` wraps candidates across the cycle seam instead of pinning them to the
  linear end.

### D16 / D18 — one bounds authority
- `LayoutEngine.maxScrollOffset` returns a real range for a single wide column and `0` when the
  column fits.
- `LayoutEngine.computeSnapTarget` keeps a single column's projected offset inside that range
  instead of returning `0`, so snapping cannot erase the range on the next lift.
- `LayoutEngine.scrollBounds(...)` resolves margins, smart-margin collapse, gap, usable width,
  max offset and loop eligibility once.
- `WorkspaceManager` uses that result for scroll, settle, snap, scrub, keyboard and delta paths;
  `StatusBarController` routes centering through `centerFocusedColumn()`.

### D09 — deferred callbacks are phase/generation safe
- Settle, momentum-grace and freeze-watchdog timers are installed in `.common` mode and carry the
  `gestureGeneration` they belong to.
- Every handler checks generation, momentum phase and motion phase before acting.
- `cancelAnimation()` and `handBackGestureToApp()` bump the generation, invalidating a timer whose
  `Task` is already queued on the main actor.

---

## 5. Regression coverage

### New executable-adjacent tests

`Tests/IumeCoreTests/SlidingPhysicsTests.swift` — 13 Phase 2 tests added to the existing motion
suite (42 test functions total):

1. spring lands on a shrunken max offset;
2. deferred max-offset query retargets the finishing spring;
3. freeze settle clamps before callbacks;
4. cancel after a shrink cannot park outside the range;
5. freeze-on-release preserves the released offset;
6. unclaimed lift clears residual spring velocity;
7. snap-disabled settle leaves zero residual velocity;
8. no-op snap settle stays idle (handoff contract preserved);
9. stale wheel settle after cancel is inert;
10. stale freeze watchdog after cancel is inert;
11. freeze watchdog is inert while tracking;
12. retargeted spring lands exactly once;
13. a new gesture during a settle owns the motion for good.

`Tests/IumeCoreTests/ScrollBoundsAuthorityTests.swift` — 9 geometry tests:

1. single wide column has a range and never loops;
2. single wide column's snap target preserves that range (new in this review);
3. single narrow column has no range;
4. strip shorter than the viewport never loops (viewport and snap agree);
5. loop mode is inert outside strip layouts;
6. loop snap wraps across the cycle seam;
7. `ScrollBounds` resolves margins, gap, range and loop once;
8. smart margins collapse once;
9. viewport, layout and snap agree on the same bounds.

Both files pass `swiftc -parse`. Both also pass a Testing-stripped `swiftc -typecheck` against a
module built from the production sources, which proves the API calls compile even though the
expectations cannot run here.

### Harness mirrors

The audit harness contains executable equivalents of the Phase 2 checks and, deliberately, the
five at-risk legacy tests:

- `testIsMovingStates`
- `testAnimationCompletedCallback`
- `testMomentumDecoupling`
- `testVelocityContinuityAcrossSettle`
- `testDirectManipulationZeroInputLag`

They are **not deleted or edited**. The harness mirrors them to prove the Phase 2 edits did not
change their contracts. All five mirrors pass at the final stable run.

### Executable counts

| run | checks | failures | exit | log |
|---|---|---|---|---|
| default physics harness | 261 | 0 | 0 | `logs/phase2-physics-final.txt` |
| physics + adversarial stress | 350 | 0 | 0 | `logs/phase2-physics-adversarial.txt` |

The 350-check run includes the writer's stress suite (ledger fuzzing, direction reversals,
duplicate lifts, cancellation, keyboard retargeting, epoch timeout, sub-epsilon accumulation).
It reported no `FAIL` and no `[FINDING]` line against `0296dd7a…`.

The unified gate `./scripts/audit/run-all-tests.sh` also passes **411/411** across layout (75),
physics (261), window/AX (39) and Rust (36); see `logs/phase2-all-suites.txt`.

---

## 6. D01–D24 status

Status vocabulary: **fixed** = changed and covered by an executable check; **partial** = code
exists but the acceptance path is not verified; **open** = not changed in Phase 2;
**non-goal** = explicitly out of Phase 2 scope.

| ID | Phase | Status | Evidence / note |
|---|---|---|---|
| D01 | P0 | **fixed** | completion, cancel and freeze paths clamp; spring-shrink test |
| D02 | P0 | **fixed** | all settle branches idle; snap-disabled and unclaimed-lift tests |
| D03 | P0 | **fixed** | `isLoopEligible` + `ScrollBounds.loopEligible`; layout harness |
| D04 | P1 | **implemented outside Phase 2** | direct-touch reservoir; 0 frozen frames at 60/80/120 Hz, 2/119 at 240 Hz; live feel unverified |
| D05 | P1 | **partial** | read-back, single retry, failure invalidation and AX signposts are present; live AX and parked-window paths unverified |
| D06 | P1 | **partial** | diagonal hand-back exists behind a default-off default; live ownership unverified |
| D07 | P1 | **open** | the 0.18 s settle projection is still hard-coded |
| D08 | P1 | **fixed** | loop-aware snap; seam test |
| D09 | P0 | **fixed** | common-mode timers + generation/phase guards; stale-callback tests |
| D10 | P1 | **open** | `passUnretained` registration/re-registration unchanged |
| D11 | P1 | **partial** | per-frame `@Published` workspace write removed and HUD throttled; expected-frame registration still runs per window per frame |
| D12 | P2 | **non-goal** | `animationDuration` semantics unchanged |
| D13 | P2 | **fixed** | analytic `SpringState`; frame-rate independence check |
| D14 | P2 | **open / product decision** | `freezeOnRelease` still overrides snap/momentum |
| D15 | P2 | **default now false** | fresh-install default matches the no-freeze intent; release copy not checked |
| D16 | P1 | **fixed** | single-column range; snap preserves that range; layout harness |
| D17 | P2 | **fixed** | `centerFocusedColumn()` uses the shared bounds/loop decision |
| D18 | P1 | **fixed** | one `scrollBounds` authority; all-paths and single-column snap tests |
| D19 | P2 | **partial** | settle and completion coalesce through `scheduleSettlePass`; no synchronous window application inside the settle callback, but no per-tick test |
| D20 | P2 | **open** | event-tap callback calls the `@MainActor` gate on the main-run-loop assumption |
| D21 | P2 | **fixed** | `CriticallyDampedSpring` removed |
| D22 | P2 | **open / low** | `onSwipeSettled` still has no production consumer |
| D23 | P2 | **fixed (docs)** | `CHANGELOG.md` and `docs/ARCHITECTURE.md` now say the Rust engine is off the layout/scroll path |
| D24 | P3 | **partial** | `OSSignposter` categories plus AX duration/error telemetry; a live Instruments capture was not run |

---

## 7. Before / after

| finding | before | after (harness) |
|---|---|---|
| D01 | `maxOffset = 100` left the viewport at 1200, `isMoving == false` | shrunken-spring and deferred-query tests end inside `[0, maxOffset]` |
| D02 | `settle()` with snap off left `isMoving == true` forever | snap-disabled settle ends idle with zero spring velocity |
| D03 | single-column loop mode let the strip leave the screen | controller loop flag is false; over-scroll returns to `maxOffset` |
| D08 | loop snap was pinned by the linear clamp | seam snap lands one period forward/backward |
| D16 | single-column `maxScrollOffset == 0` | wide single column reports its real range (400 pt fixture) |
| D16/D18 | a single wide column's snap target returned 0, erasing that range on every lift | snap keeps an in-range offset, clamps an overshoot to `maxOffset`, and pins a fitting column to 0 |
| D18 | five max-offset formulas | one `ScrollBounds` value feeds every path |
| D09 | a stale timer could settle a new gesture | stale wheel/freeze callbacks are inert |
| D04 | 29/59 frozen frames in the bursty fixture | 0/59 at 60/80/120 Hz; 2/119 at 240 Hz (outside Phase 2) |

The D04 row is the concurrent writer's Phase 3 work, not a Phase 2 claim. The 240 Hz result and
the live feel remain unproven.

---

## 8. Blockers

1. **No full Xcode.** `swift build` and `swift test` fail before compiling project code:
   `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro
   'State()'; plugin for module 'SwiftUIMacros' not found`.
2. **No live app run.** The app was not launched, Accessibility was not granted, and no physical
   trackpad A/B was recorded. The only display is 60 Hz.
3. **The new Swift Testing files cannot execute.** They are parsed and typechecked against the
   real sources; the harness mirrors their assertions, but that is not `swift test`.
4. **Concurrent writer.** The tree changes while verification runs. A green run is only valid for
   the hash-stable snapshot recorded in §3.
5. **Adversarial runner wiring.** `AdversarialStressTests.swift` is compiled by the default
   script but not invoked by `main.swift`; the 350-check result comes from an injected call. The
   input-gap catch-up invariant is now green in that run (maximum catch-up 9.60 pt against the
   15.0 pt bound). The suite is the writer's Phase 3/4 extra, not a Phase 2 acceptance gate.

---

## 9. Changed files (Phase 2)

| file | change |
|---|---|
| `Sources/IumeCore/Controller/ScrollController.swift` | clamp/finish paths, generation guards, `.common` timers, settle termination, unclaimed-settle cleanup, stray-lift guard extended to `.springing` |
| `Sources/IumeCore/LayoutEngine/LayoutEngine.swift` | `isLoopEligible`, `ScrollBounds`, `scrollBounds`, D16 single-column range and snap preservation, loop-aware snap |
| `Sources/IumeCore/Workspace/WorkspaceManager.swift` | bounds authority across query, settle, layout, scrub, keyboard and delta; `centerFocusedColumn` |
| `Sources/IumeCore/UI/StatusBarController.swift` | centering routed through `centerFocusedColumn()` |
| `Tests/IumeCoreTests/SlidingPhysicsTests.swift` | new; 13 Phase 2 motion regressions |
| `Tests/IumeCoreTests/ScrollBoundsAuthorityTests.swift` | new; 9 geometry regressions |
| `scripts/audit/harness/main.swift` | Phase 2 checks + legacy-contract mirrors |
| `scripts/audit/harness/layout/main.swift` | 75 geometry checks |
| `scripts/audit/run-physics-tests.sh`, `run-layout-tests.sh` | Xcode-free executable gate |
| `scripts/audit/run-all-tests.sh` | unified gate; layout count corrected to 75 and total to 411 |
| `CHANGELOG.md`, `docs/ARCHITECTURE.md` | corrected Rust-path, 120 Hz and spring-settle claims |
| `docs/audit/10-phase2-verification.md` | this report |

The concurrent writer also changed `WindowController.swift`, `SettingsView.swift`,
`Sources/IumeCore/Physics/SpringState.swift`, the harness and Phase 3/4 docs; those changes are
not attributed to Phase 2.

---

## 10. Phase 3 decision

**NO-GO for declaring Phase 3 complete, merging it as verified, or shipping it.**  
**Conditional GO for one bounded verification pass** once all of the following are true:

1. `swift build` and `swift test` run on a machine with full Xcode; the whole existing suite
   (including the five at-risk legacy tests) is green without deleting or weakening a test.
2. The app runs with Accessibility granted, on a 120 Hz display, and a live A/B records scroll
   latency, frozen frames and settle position against the 60 Hz harness.
3. The D04 input-gap catch-up invariant stays green (9.60 pt maximum in this snapshot) and the
   240 Hz case (2 frozen frames in 119) is explained or fixed; a threshold is not edited without
   measurement.
4. A stable checkpoint is committed and the concurrent writer stops editing the scroll core.
5. The default physics runner either invokes the adversarial suite or the omission is recorded
   deliberately, so the 350-check result is reproducible with one command.

Until then, the defensible claim is: **Phase 2 P0 correctness is implemented and harness-proven;
Phase 3 motion feel is not proven.** Correctness tests are not smoothness evidence.
