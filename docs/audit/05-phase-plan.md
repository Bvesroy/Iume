# 05 — Phase 2–5 implementation plan

> **Snapshot notice.** This plan targets fingerprint `81b51e78…` (22:58). The tree moved at
> 23:07–23:18: items 2.1, 2.2 and 2.7 are already present in the new source, item 3.3’s spring
> work (D13) is done, and D05 now has a bounded read-back/retry in `WindowController`. Re-base
> the plan on the new tree before coding.
> See [`07-working-tree-drift.md`](07-working-tree-drift.md).

Status: **nothing has been changed by this session.** No source file was modified by this
session; only `scripts/audit/*` and `docs/audit/*` were added. A concurrent process modified
`Sources/IumeCore/Controller/ScrollController.swift` and added
`Sources/IumeCore/Physics/SpringState.swift` during documentation (see the drift note above).

Guiding constraints from the brief:

* one motion model, no second animation engine;
* reuse the existing `ScrollController` state and the existing `LayoutEngine`;
* do not rebuild the Rust engine;
* no duplicate settings without demonstrated need;
* do not touch tab groups or unrelated window management.

---

## Phase ordering rule

Each phase must end green on the harness in `scripts/audit/` before the next starts. The harness is
the regression gate because `swift test` cannot build on this machine; Phase 5 fixes that
permanently. Phases 2–4 are ordered by user-visible damage, not by code cleanliness.

```
Phase 2  correctness        (P0)  ──► must land first; D01/D02/D03 corrupt state
Phase 3  one motion model   (P1)  ──► changes feel; needs Phase 2 to measure cleanly
Phase 4  window application (P1)  ──► changes frame pacing; needs Phase 3 to measure latency
Phase 5  observability/CI   (P3)  ──► makes the rest repeatable
```

---

## Phase 2 — Correctness and single source of truth (P0, ~1 day)

**Goal:** no state can be corrupted by a timing/layout change. Nothing in this phase changes how
motion feels; it only prevents the viewport and the "is moving" flag from getting stuck.

| # | change | file:line | acceptance |
|---|---|---|---|
| 2.1 | Re-clamp at spring completion | `ScrollController.swift:616-620` | `max_offset_shrink_midspring` ends with `0 ≤ offset ≤ maxOffset` |
| 2.2 | Zero the spring state on every non-snap settle exit; add `resetSpringState()` | `:1079-1083`, `:805-810` | `settle_snap_disabled` ends with `isMoving == false`, `velocity == 0` |
| 2.3 | Make loop eligibility one predicate owned by `LayoutEngine`; drive the controller flag from it | `WorkspaceManager.swift:3013`, `LayoutEngine.swift:148/338` | one-column + loop-on ⇒ `isLoopModeEnabled == false` (new test) |
| 2.4 | Thread `loopMode` into `computeSnapTarget` | `WorkspaceManager.swift:733` | cyclic snap target stays within one column (new test) |
| 2.5 | One `currentMaxOffset(for:)` used by scroll, settle, scrub, keyboard, delta | `WorkspaceManager.swift:664/700/343/1523/3554` | all five return the same value on a margined fixture |
| 2.6 | Fix single-column `maxScrollOffset == 0` | `LayoutEngine.swift:88-96` | single 2000 pt column on 1400 pt screen has `maxOffset > 0` |
| 2.7 | Phase-guard `settleTimer` / `momentumWatchdogTimer`, register in `.common` | `ScrollController.swift:894-916`, `:986-995` | settle does not fire between `phase 1` and `phase 4` |
| 2.8 | Correct `CHANGELOG.md:41-43` and `docs/ARCHITECTURE.md` to say the Rust spring/layout is **not** on the scroll path | docs only | statement matches `grep` |

**Explicit non-goals:** no change to the spring constants, no change to the filter, no change to
`freezeOnRelease` semantics.

**Risk:** 2.3 and 2.5 touch the boundary definitions that every layout mode shares. Land them
behind the new comparison tests, one commit each, and re-run `cargo test` (the Rust tests pin
Swift/Rust parity for margins and parking).

**Rollback:** each item is independently revertible; none introduces new persisted state.

---

## Phase 3 — One motion model (P1, ~2–3 days, needs A2/A4)

**Goal:** exactly one place decides how an input delta becomes a displayed offset, and one control
governs it. Keep the 1:1 displacement contract; remove the *distribution* jitter.

### 3.1 Resample direct touch (D04) — the core change

> **Superseded by `08-phase3-direct-touch.md`.** The exponential λ = 120–160 approach below was
> rejected during implementation: it converts burst aliasing into a permanent `v / λ` lag and smears
> direction changes. Phase 3 ships a timestamped input reservoir drained over the observed input
> interval instead. The text below is kept for history only; do not reintroduce λ.

Today `isDirectTouch` assigns `currentOffset = smoothTargetOffset` (`:492-499`). Replace the
assignment with the **existing** filter arithmetic, using a short, frame-rate-normalised constant:

```swift
// pseudocode, same file, same state — no new engine
let lambdaTouch = 120.0 ... 160.0        // ≈ 6–8 ms time constant
let factor = 1 - exp(-lambdaTouch * dt)
currentOffset += (smoothTargetOffset - currentOffset) * factor
```

* Total displacement is unchanged (the target is still the integral of input).
* Worst-case added lag at 120 Hz: one frame. At 60 Hz: one frame.
* The measured gate: `frozenFrames` in `direct_bursty_packets` must go from 29 → ≤ 3, and
  `perFrameDelta.max` from 19.2 → < 12, with `|finalOffset − expected| < 1`.
* If that gate cannot be met without adding > 8 ms of latency, stop and report — do not raise λ.

### 3.2 Make the smoothness slider mean one thing (D12, D14, A2)

The slider currently drives (a) the non-touch filter λ, (b) the settle spring's `response`, and
(c) the settle spring's `dampingRatio`. Pick one primary meaning — "input smoothing" — and move the
spring response to `animationDuration` only. This is a settings-semantics change and needs **A2**
and **A4** before coding.

### 3.3 Frame-rate-independent spring (D13)

Sub-step `SpringState.step(dt:)` to a fixed 1/240 s. Six flops per sub-step, ≤ 4 sub-steps at 60 Hz.
Gate: position spread across 60/80/120/240 Hz < 5 pt at 50/100/200 ms (currently 106 pt at 50 ms).

### 3.4 Release-mode matrix (D14, D15, A1)

Replace `freezeOnRelease` × `snapToColumn` × `momentumScrolling` with one enum
(`freeze` / `snap` / `momentum`) **only if** A1 approves. Otherwise keep the booleans but disable and
annotate the dependent controls, and make the two default paths agree.

**Risk:** this is the phase users feel. Every change must be A/B'd with the harness and, if A0 is
approved, one live capture. Do not land 3.1–3.4 in one commit.

---

## Phase 4 — Window application (P1, ~2–3 days, needs A0 for verification)

**Goal:** the offset the controller believes in and the pixels on screen stop diverging.

| # | change | file:line |
|---|---|---|
| 4.1 | Invalidate `lastAppliedFrames` on any non-`.success` AX return; bound retries | `WindowController.swift:475-486`, `:95`, `:126-133` |
| 4.2 | Settle pass writes unconditionally, then records; one read-back per window at settle to correct a missed write | `:307-336`, `:521` |
| 4.3 | `recordExpectedFrame` only for windows actually written this frame | `WorkspaceManager.swift:3114` |
| 4.4 | Move `viewportOffset` out of the `@Published` dictionary (or publish at ≤ 10 Hz) | `WorkspaceManager.swift:675-681` |
| 4.5 | Throttle `MinimapHUDController.update` to 30 Hz | `WorkspaceManager.swift:683-696` |
| 4.6 | Coalesce settle application into the next tick (no AX inside the frame callback) | `:700-770`, `ScrollController.swift:583` |

**Acceptance (needs the app):** with the sampler at 60 Hz, during a 10 s slow scroll, the max gap
between `targetFrame` (from the benchmark) and the observed `CGWindowList` frame for any window is
< 2 pt, and no window is observed more than one frame stale. Idle CPU after 2 s of no input must be
< 1% (this is where D02 currently keeps the display link awake).

**Risk:** 4.2 adds one synchronous AX write per window per settle. That is the point — it is bounded
by the settle, not by the frame. If a target app has a 100 ms `AXUIElementSetMessagingTimeout`, the
settle can block for 100 ms per window unless 4.6 has already moved it off the frame path; land 4.6
first.

---

## Phase 5 — Observability and a real test gate (P3, ~1 day)

1. Add `Signposts.swift` and the six intervals from `03-instrumentation.md`. No behaviour change.
2. Add one `OSLog` subsystem `com.iume.Iume` and forward `Diagnostics.record` into it, so the ring
   buffer stops being invisible.
3. Make the harness a checked-in test gate: `scripts/audit/run_scroll_bench.sh` exits non-zero if any
   scenario's invariant fails (D01/D02/D13/D04 gates above). This is the only regression gate that
   works without Xcode.
4. Fix the `swift test` blocker on CI: use a macOS runner with Xcode, or vendor the SwiftUI macro
   plugin. Until then, state plainly in the README that `swift test` requires Xcode.
5. Add `xctrace` recipes to the README with **verified** template names (must be produced on a
   machine with Xcode; cannot be verified here).

---

## 4. Decision deferred: which spring is the implementation of record

Two spring implementations exist and a third is dead:

| implementation | used by | frame-rate independent | at-rest test |
|---|---|---|---|
| `SpringState.step` (Swift) | `ScrollController` — **the shipped path** | no (D13) | `<0.40 / <3.5` |
| `RustEngine.step` → `iume_spring_step` | nothing | no (measured 24.9 pt spread) | Rust-side |
| `CriticallyDampedSpring` | nothing, ever | analytic (would be) | `<0.35 / <3.0` |

Recommendation: keep `SpringState` (it is the one with production mileage), fix D13 by sub-stepping,
and **delete** `CriticallyDampedSpring` and `RustEngine.step`/`springIsAtRest` unless a concrete
need for the Rust path appears. "Rebuild the Rust engine" is explicitly out of scope; leaving three
implementations in the tree is worse than leaving one.

---

## 5. What must not be touched

* Tab groups, `WindowTabGroupingTests`, `ColumnPresentationMode.stacked`, tab bar overlays.
* `BoxTilingEngine`, BSP, grid/tall/wide layout modes.
* Permission flow, entitlements, packaging (`scripts/package.sh`), onboarding.
* The event tap's *placement* (session-level head insert) — changing it changes what the app can see
  system-wide. Behaviour of the lease/hand-back is Phase 3.4 only, behind A3.
* The Rust crate's public ABI.

---

## 6. Approval decisions (require an answer before the default changes)

### A0 — May I launch Iume for an interactive capture? *(not a default change; a permission)*

Phase 1 measured everything that can be measured headlessly. The remaining P1 findings
(AX write latency, Electron behaviour, real gap/overlap, `objectWillChange` cost, tap-induced
latency, 120 Hz) need the app running.

What launching does: Iume is `.accessory` and **immediately retiles every eligible window on the
active Space**; it needs Accessibility trust (`com.iume.Iume` is not currently in the TCC
Accessibility list). This is destructive to the current window arrangement and cannot be undone.
Proposed: 2 minutes, one Space, I start it from the terminal with `--kickstart` omitted, capture
with the sampler at 60 Hz, then quit and restore nothing.

Options: **(a) yes, go ahead**, (b) I launch it myself and tell you when, (c) skip — accept that the
interactive metrics stay unmeasured.

### A1 — `freezeOnRelease` default on a truly fresh install

Current state is contradictory: `SettingsStore.swift:688` → `false`; `SettingsMemoryManager`
(`:89`, `:161`, `:317`) → `true`; `CHANGELOG.md:24` says true.

Options:
* **(a) true everywhere** — matches the changelog and the durable snapshot; snap/momentum stay inert
  until the user turns it off. **Recommended**, because it is what the product already claims and
  what this machine's snapshot contains.
* (b) false everywhere — snap/momentum work out of the box; contradicts the changelog and changes
  feel for new users.
* (c) leave contradictory — not acceptable; it makes two installations behave differently.

### A2 — Should "Smoothness" affect direct finger tracking?

Measured: it currently does nothing during touch (identical output at 0/0.75/1). Phase 3.1 adds a
short resampling stage to remove packet jitter. Two ways to expose it:

* **(a) fixed** — resampling is always on, slider affects wheel/coast only. Lowest risk, least
  surprising. **Recommended.**
* (b) make the slider scale the touch time constant (0 = raw 1:1, 1 = maximum smoothing). Gives users
  a way back to today's feel, but changes what the slider means for everyone and adds a second
  interpretation of the same value.

### A3 — Diagonal gesture hand-back

D06 proposes that a gesture which starts horizontal and becomes clearly vertical stops being
consumed. This fixes "Iume ate my vertical scroll" but makes horizontal swipes feel less sticky.

* (a) implement behind a setting that defaults **on** — fixes the interference, one new setting.
* **(b) implement and log for one release, ship off** — measure first. **Recommended.**
* (c) don't implement — accept the interference.

### A4 — `animationDuration` semantics

Measured: the value is a spring *period*; 0.22 yields 420 ms of motion.

* **(a) convert on input (`response = duration / 1.9`)** so the label is true. Every existing user's
  snap becomes ~47% faster at the same stored value. **Recommended**, but it is a felt change.
* (b) rename the setting to "Response time" and leave behaviour alone.
* (c) leave it — the label stays wrong.

### A5 — Three-way release mode

`freezeOnRelease`, `snapToColumn` and `momentumScrolling` are presented as independent but freeze
silently wins (D14). Options: **(a)** UI-only dependency hints (no model change, lowest risk);
**(b)** a single `ReleaseMode` enum with migration (cleanest, bigger change); (c) leave it.
Recommendation: **(a) now, (b) only if users report confusion.**

---

## 7. Definition of done for the sliding system (not claimed yet)

The system may be called fixed only when **all** of the following are green on this machine *and*
on a live capture:

1. `direct_bursty_packets`: `frozenFrames ≤ 3`, `max Δ < 12 pt`, total displacement within 1 pt.
2. `max_offset_shrink_midspring`: `0 ≤ offset ≤ maxOffset`, `isMoving == false`.
3. `settle_snap_disabled`: `isMoving == false` after 1 idle frame, `springState.velocity == 0`.
4. `spring_settle_rate_sweep`: position spread across 60/80/120/240 Hz < 5 pt at 50/100/200 ms.
5. Sampler capture: no adjacent-window gap > configured gap + 2 pt, no overlap > 1 pt, no direction
   reversal during a monotonic gesture.
6. Idle CPU < 1% and the display link paused within 500 ms of the last motion.
7. `cargo test --release` 30/30 and a Swift test run on an Xcode machine.

Until then, the correct statement is: **the defects are identified, the baseline is measured, and
the fixes are planned — the sliding system is not fixed.**
