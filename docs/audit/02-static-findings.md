# 02 — Ranked defects (static + measured)

> **Snapshot notice.** Findings and line numbers describe fingerprint
> `81b51e78…` (22:58), measured against the 2026-10-24 `libIumeCore.a`. A concurrent process
> rewrote the scroll core at 23:07–23:12. Status of every finding against the new tree — and the
> new risks it adds — is in [`07-working-tree-drift.md`](07-working-tree-drift.md). D01, D02, D09,
> D13 and D21 are addressed in that new source but **unbuilt and unverified**; D04 is unchanged.

Commit `9992c80`, working tree (dirty). Severity is assigned by the task's own definitions:

* **P0** — scrolling broken, input lost, windows jump/overlap, or the app stops managing windows.
* **P1** — significant latency, stutter, inconsistent motion, or interference with other apps.
* **P2** — incomplete controls, inconsistent snapping, poor edge/focus transitions.
* **P3** — polish, observability, dead code.

`CONFIRMED` = reproduced by benchmark or proven from control flow with no runtime dependency.
`HYPOTHESIS` = code supports it, magnitude/frequency still needs profiling (listed again in §6).

Measured evidence lives in `04-baseline.md`; raw output in `$TMPDIR/iume-scroll-bench/results-release.jsonl`.

---

## P0 — fix before anything else

### D01 — Spring completion writes `springState.target` without re-clamping to `maxOffset`

**CONFIRMED / MEASURED.** `maxOffset: 100` left the viewport at **1200** — 1100 pt out of range,
with `isMoving == false` (so nothing will ever bring it back except another gesture).

`ScrollController.swift:598-618`

```swift
springState.step(dt: dt)
currentOffset = isLoopModeEnabled ? springState.position
                                  : min(max(0, springState.position), maxOffset)   // clamped every frame
...
if springState.isAtRest {
    currentOffset = springState.target                                         // ← unclamped
    normalizeLoopOffsetAtRest(notify: false)
```

* **Repro (headless):** `scrollTo(target: 1200, maxOffset: 20_000)`, step 6 frames, set
  `maxOffset = 100`, run to rest → `currentOffset == 1200`.
  `scripts/audit/scroll_bench.swift` → `max_offset_shrink_midspring`.
* **Live repro:** start a long snap, then close a window in another column (or change display) so
  the strip shortens while the spring runs. The strip stops past the last column with blank screen
  on the right and no rubber-band recovery (freeze-on-release clamps new input but never re-homes
  the existing offset).
* **Cause:** the per-frame clamp is applied to the animated position but the at-rest branch
  assigns the *target*, which was computed before `maxOffset` changed.
* **Correction (narrow):** re-clamp once at the at-rest branch, exactly as the per-frame branch does:
  `currentOffset = isLoopModeEnabled ? springState.target : min(max(0, springState.target), maxOffset)`,
  then set `springState.position = currentOffset`. Optionally re-target instead of snapping when the
  delta is large (> one column) to avoid a jump. No new state, no new engine.
* **Regression risk:** low. Only changes behaviour when `maxOffset` shrank mid-flight, which is
  currently a corruption path. Add a `didRetargetAtRest` telemetry flag if the jump is undesirable.
* **Proving test:** `maxOffsetShrinkMidSpringKeepsOffsetInRange` — assert
  `0 <= currentOffset && currentOffset <= maxOffset` after rest; assert `isMoving == false`.

---

### D02 — `settle()` with `snapToColumn == false` never clears `springState.velocity`; `isMoving` stays true forever

**CONFIRMED / MEASURED.** After `settle()`, `isMoving == true` one second later with
`springState.velocity == 1152`, `springState.isAtRest == false`, and **zero** viewport callbacks.
`WorkspaceManager` guards window adoption and reconciliation on `!scrollController.isMoving`.

`ScrollController.swift:1079-1083` and `:188-190`

```swift
} else {
    smoothTargetOffset = currentOffset
    currentVelocity = 0.0          // springState.velocity untouched
    onAnimationCompleted?()
}
...
public var isMoving: Bool {
    isActivelyScrolling || isMomentumCoasting || isSpringAnimating || !springState.isAtRest || isSwipingInteractively
}
```

`WorkspaceManager.swift:385-392`

```swift
guard settings.isEnabled, !scrollController.isMoving, ... else { return }
scrollController.startEventTap()
```

* **Repro (headless):** settings `snapToColumn = false`, `freezeOnRelease = false`; feed 60 events;
  call `settle()`; step 120 idle frames → `isMoving` still true, no callbacks.
  `scroll_bench.swift` → `settle_snap_disabled`.
* **Live repro:** Settings → disable *Snap to columns*, disable *freeze on release*, scroll once and
  lift. New windows stop being adopted; drag a new window in and it floats unmanaged; the 60 s
  reconcile never runs. The only recovery is another scroll that happens to zero the velocity.
* **Cause:** the non-snapping branch resets the *filter* velocity but not the *spring* state that
  `isMoving` actually reads. `cancelAnimation()` does not clear `springState.velocity` either
  (`:805-810`).
* **Correction (narrow):** in that branch set `springState.position = currentOffset;
  springState.target = currentOffset; springState.velocity = 0`. Do the same in `cancelAnimation()`.
  Then make `isMoving` read an explicit `motionState` flag OR keep it but guarantee every exit path
  zeroes the spring. Prefer the former only if a test proves a second divergence.
* **Regression risk:** low, but `cancelAnimation` is called on every phase-1 event (`:906`), so
  clearing velocity there must not erase the touch velocity used for momentum. Use a dedicated
  `resetSpringState()` called only from settle/stop paths, not from `cancelAnimation`.
* **Proving test:** `settleWithoutSnapStopsMotion` — after `settle()` + 1 idle frame,
  `isMoving == false`, `springState.velocity == 0`, and `WorkspaceManager.reconcileUnmanagedWindows`
  is reachable (assert via a spy on the guard).

---

### D03 — Loop mode can be ON in the controller while the layout engine refuses to loop

**CONFIRMED BY INSPECTION** (end-to-end repro needs the app; not run).

`WorkspaceManager.swift:3013-3014` sets the controller flags unconditionally:

```swift
scrollController.isLoopModeEnabled = settings.loopMode
scrollController.loopPeriod = ...
```

`LayoutEngine.swift:148` and `:338` only loop when:

```swift
columns.count >= 2 && period >= visibleWidth && layoutMode.supportsLoop
```

The controller's loop branches **skip the boundary clamp and rubber-band** (`:419-430`, `:1060`),
while `computeLayout` still clamps frames at `maxOffset` (often `0` for one column). The result is a
viewport that can be swiped arbitrarily far past the only column with no clamp and no spring-back.

* **Repro:** enable Loop mode, close windows until one column remains, then scroll right. The
  window leaves the screen; nothing pulls it back. (Also reproduces with a strip narrower than the
  screen, or in `manualLayout`.)
* **Cause:** one user setting drives two independent predicates; the controller trusts the setting,
  the engine trusts the geometry.
* **Correction (narrow):** make the engine the single source of truth. Add
  `LayoutEngine.isLoopEligible(columns:visibleWidth:layoutMode:)` returning the existing private
  predicate, and set `scrollController.isLoopModeEnabled = settings.loopMode && engine.isLoopEligible(...)`
  in the same place the period is computed. Re-evaluate on column add/remove/resize/display change
  (already the sites that recompute `maxOffset`).
* **Regression risk:** medium — loop users will see the strip stop at the seam instead of wrapping
  when the geometry is ineligible. That is the intended fallback and must be documented.
* **Proving test:** `loopDisabledWhenSingleColumn` — one column, loop on → assert
  `scrollController.isLoopModeEnabled == false` and that an over-scroll returns to `maxOffset`.

---

## P1 — latency, stutter, inconsistent motion

### D04 — Direct finger tracking is raw 1:1 with no packet-jitter absorption (the measured stutter)

**CONFIRMED / MEASURED.** At the same mean input rate, a 0/2-packets-per-frame pattern produces
**29 of 60 frames with zero movement** and **30 frames with a 19.2 pt jump**. `scrollSmoothness`
0 / 0.75 / 1 produce byte-identical output during touch.

`ScrollController.swift:492-499`

```swift
if isDirectTouch || isMacOSMomentum {
    // Direct 1:1 manipulation during physical touch or native macOS momentum stream!
    // Zero input lag, instant response, perfectly synchronized!
    currentOffset = smoothTargetOffset
    springState.position = currentOffset
    springState.target = currentOffset
    springState.velocity = currentVelocity
```

`isDirectTouch` is `phase 1/2 && momentumPhase == 0 && now − lastInputTimestamp <= 0.12` (`:458`).

* **Repro (headless):** `direct_1to1_120hz` (8 pt every frame) → exact 9.6 pt/frame, zero lag.
  `direct_bursty_packets` (0/2 alternating) → 29 frozen frames, 19.2 pt jumps.
* **Live repro:** slow two-finger drag on any trackpad. The window moves in visible steps that track
  the sensor packet boundaries, not the display refresh. Most obvious at 60 Hz and on long strips.
* **Cause:** the only anti-jitter stage in the file (`λ` filter, `:553-560`) is deliberately bypassed
  for direct touch. Trackpad packets are not frame-aligned, so their arrival pattern becomes the
  window's motion pattern.
* **Correction (narrow, no second engine):** keep the 1:1 *displacement* contract but resample it.
  Accumulate into `smoothTargetOffset` as today, and in the direct-touch branch advance
  `currentOffset` toward the target with a short time constant instead of assigning:
  `factor = 1 − exp(−λ_touch · dt)` with `λ_touch ≈ 120–160` (≈ 6–8 ms). Cap the catch-up so total
  added lag stays under one frame at 120 Hz (8.3 ms). This reuses the existing filter branch;
  it does not add a spring or a timer. Make `λ_touch` a function of the existing smoothness slider
  only if measurement shows the slider should affect touch (see approval decision §A2).
* **Regression risk:** medium. Touch will feel marginally less "raw"; the 1:1 total displacement is
  preserved because the target is still the integral of input. Direct-touch latency is the one
  metric that must be re-measured after the change (harness already measures `lagAtEnd` and
  per-frame delta SD).
* **Proving test:** `burstyPacketsDoNotFreezeFrames` — same scenario as `direct_bursty_packets`;
  assert `frozenFrames <= 3` (from 29) and `max |Δ| < 12 pt` (from 19.2), while
  `|finalOffset − expected| < 1 pt`.

---

### D05 — The window writer caches write *intent* and never reads the actual frame back

**CONFIRMED BY INSPECTION.** No read-back path exists. A write that times out or is rejected is
remembered as applied.

`WindowController.swift:205`, `:475-486`, `:307-336`

```swift
private var lastAppliedFrames: [WindowId: CGRect] = [:]
...
if let prev = lastAppliedFrames[windowId],
   abs(prev.origin.x - rounded.x) < 0.5 && abs(prev.origin.y - rounded.y) < 0.5 {
    lock.unlock(); return                       // suppressed
}
if var prev = lastAppliedFrames[windowId] { prev.origin = rounded; ... }
lastAppliedFrames[windowId] = CGRect(...)       // recorded before the write is attempted
```

`AXUIElementSetAttributeValue` returns an `AXError` that is discarded in `WindowWriter`
(`:95`, `:126`, `:129`) and in `setFrame`/`setPosition` (`:521`, `:602`).

* **Repro:** hold a very slow app (Electron with `AXEnhancedUserInterface` stuck on, or a busy
  Xcode) and scroll slowly (<0.5 pt/frame at 120 Hz). The window stops following and only jumps when
  the intent crosses 0.5 pt. On a 1 px/frame drag the correction threshold is never crossed in the
  other direction, so the window remains offset until the settle pass — which uses the same cache.
* **Cause:** `lastAppliedFrames` answers "what did I ask for", but the suppression test treats it as
  "what is on screen". The settle path (`:307-336`) compares against the same map, so a failed
  async write is considered done.
* **Correction (narrow):** (a) clear the cache entry on any non-`.success` AX return, so the next
  frame retries; (b) on the settle pass, always write once regardless of the cache, then update it;
  (c) optionally read `kAXPositionAttribute` once per window at settle and correct once. Do not add
  a per-frame AX read — that is the expensive direction.
* **Regression risk:** low. (b) adds one write per visible window per settle (already bounded).
  (a) can cause a retry storm if an app never accepts the write — bound it with a per-window
  consecutive-failure counter (max 3 per settle) and log it.
* **Proving test:** `failedWriteIsRetried` — inject a writer whose first `AXUIElementSetAttributeValue`
  returns `.cannotComplete`, assert the frame is re-sent on the next frame and once at settle.

---

### D06 — Gesture ownership is a one-way latch; a horizontal→vertical gesture keeps swallowing the app's scroll

**CONFIRMED BY INSPECTION.** `.strip` never returns to `.app` mid-gesture.

`ScrollController.swift:1119-1143`

```swift
if gestureOwner == .strip {
    if phase == 4 || phase == 8 { gestureOwner = .undecided; ... }
    return true                      // consume everything until the gesture ends
}
```

`ScrollController.swift:863-871` chooses `dx` when `|dx| >= |dy|`, and in `seamlessHorizontal`
falls back to `dx` even when `|dy|` is larger — then `:1233` returns `nil` (consumed).

* **Repro:** two-finger scroll diagonally in Safari: start horizontal, then go vertical while the
  fingers are still down. The page does not scroll; Iume keeps consuming. (This is ISSUE-05 in
  `issue.md`; the code confirms the mechanism, live repro pending.)
* **Cause:** ownership is decided once, with no hysteresis or hand-back rule, and the decision is
  enforced by swallowing the event at the tap.
* **Correction (narrow):** add a hand-back rule evaluated per event before consuming:
  if `gestureOwner == .strip && |dy| > |dx| * 1.5 && |dy| > 8 && phase == 2` and no modifier is held,
  set `gestureOwner = .app` for the remainder of the gesture and return `false`. Keep the 150 ms
  watchdog as the backstop. Add a per-gesture `didHandBack` flag so it can only happen once.
* **Regression risk:** medium-high — this is the most user-visible behavioural change in the list.
  It can make a deliberate horizontal swipe feel like it "escapes" mid-gesture. Gate it behind
  measurement: log `handBack` events and only ship if the diagonal case is common. **Requires
  approval (§A3).**
* **Proving test:** `diagonalGestureHandsBackToApp` — feed 6 horizontal packets then 6 packets with
  `dy == 2·dx`; assert the tap returns `false` for the vertical packets and `gestureOwner == .app`.

---

### D07 — Settle uses a hard-coded 0.18 s projection and discards most of the finger-lift velocity

**CONFIRMED / MEASURED.** Projection horizon is exactly **0.18 s**. A ±800 pt/s hand-off changes the
first frame by ±4.5 pt and does **not** change settle duration (420 / 417 / 421 ms).

`ScrollController.swift:1073-1078`

```swift
let base = abs(smoothTargetOffset - currentOffset) > 0.5 ? smoothTargetOffset : currentOffset
let projection = base + currentVelocity * 0.18
```

`ScrollController.swift:738-744`

```swift
springState.velocity = initVel
springState.response = max(0.08, baseResp * (0.70 + smoothness * 0.40))
springState.dampingRatio = max(0.88, 0.98 - smoothness * 0.10)
```

* **Repro (headless):** `settle_projection` → `projectedOffset − offset = 207.36` for
  `v = 1152` ⇒ horizon `0.18`. `spring_settle` → ±800 pt/s changes duration by ≤ 4.4 ms.
* **Cause:** the projection substitutes for velocity continuity (it moves the *target*), so the
  spring's initial velocity is almost irrelevant at ζ≈0.9. The visible deceleration at finger lift
  is therefore a step, not a curve: the strip was moving at 1152 pt/s and the spring starts from a
  near-rest trajectory toward a target 207 pt away.
* **Correction (narrow):** derive the projection horizon from the spring instead of hard-coding it:
  `horizon = currentVelocity / (ζ·ω)` (≈ 1/26 ≈ 0.038 s at defaults) is too short; the physically
  consistent choice is the spring's own velocity impulse `v/ω²` added to the target. Compute the
  target as the column that contains `x + v·t_proj` with `t_proj = 1/(ζω) · ln(...)`, or simply
  expose `0.18` as a named constant and *tune it against measured path length*. The narrow fix is
  to name it, test it, and stop the spring from starting at near-zero velocity when `settleVelocity`
  is large (raise the share of `initVel` that survives the first frames, e.g. by lowering ζ toward
  0.85 for user-aimed settles only).
* **Regression risk:** medium — changes the "feel" of every flick. Must be A/B'd with the harness
  (`pathLength`, `maxOvershoot`, `elapsedMs`) before shipping.
* **Proving test:** `settleVelocityIsContinuous` — sample offset at 8 ms and 16 ms after
  `settle()` with `v = 1200`; assert the first two deltas are within 25% of `v·dt` (currently they
  are ≤ 5%).

---

### D08 — `computeSnapTarget` is called without `loopMode:`

**CONFIRMED BY INSPECTION.** In loop mode a cyclic offset is snapped back by a whole period.

`WorkspaceManager.swift:733-741`

```swift
let snapTarget = self.layoutEngine.computeSnapTarget(
    for: projectedOffset, velocity: ..., columns: ws.columns,
    visibleWidth: usableWidth, centerMode: ..., gap: effectiveGap
)                                        // loopMode defaults to false
```

`LayoutEngine.swift:604-611` — `computeSnapTarget(..., loopMode: Bool = false)` clamps candidates
to `[0, totalWidth − usableWidth]` on the linear path.

* **Repro:** loop mode on, ≥2 columns, flick right past one full period. The snap animates backwards
  by exactly one period (or pins to the linear end) instead of snapping to the next column.
* **Cause:** the loop-aware parameter was added but not threaded through the only production caller.
* **Correction (narrow):** pass `loopMode: settings.loopMode && <engine eligibility>` at the call
  site. One line.
* **Regression risk:** very low; only affects loop mode, where the current behaviour is wrong.
* **Proving test:** `snapTargetUsesLoopPeriod` — with `loopMode: true` and
  `projectedOffset = period + 120`, assert the snap target is within ±(column width) of
  `period + nearest column offset`, not `nearest column offset`.

---

### D09 — Settle and momentum timers use the default run-loop mode and are not phase-guarded

**CONFIRMED BY INSPECTION** (frequency unmeasured). `settleTimer` and `momentumWatchdogTimer` are
created with `Timer.scheduledTimer` (default mode), unlike the display link which is added in
`.common` (`:345`, `:380`).

`ScrollController.swift:894-916`

```swift
momentumWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { ... 
    if self.lastMomentumPhase == 0 { self.settle() }        // no phase / isActivelyScrolling check
}
```

`ScrollController.swift:986-995`

```swift
settleTimer = Timer.scheduledTimer(withTimeInterval: settleDelay, repeats: false) { ...
    self?.settle()                                          // no phase check
}
```

* **Repro:** wheel-scroll, then within 180 ms start a two-finger gesture. If the timers fire between
  phases they call `settle()`, which clears `pendingDelta`, unlatches `gestureOwner`, and sets
  `isActivelyScrolling = false` (`:1030-1038`).
* **Cause:** the timers were written before phase state was reliable and only test
  `lastMomentumPhase`.
* **Correction (narrow):** add `guard self.lastPhase != 1 && self.lastPhase != 2 &&
  !self.isActivelyScrolling else { return }` to both closures, and register both timers in
  `.common` mode via `RunLoop.main.add(timer, forMode: .common)` (matching the display link).
* **Regression risk:** low. Worst case the settle is deferred to the next display-link tick, which is
  already the normal path (`hasPendingSettle`).
* **Proving test:** `settleTimerDoesNotFireDuringGesture` — arm the wheel timer, deliver a
  `phase == 1` event, advance the run loop past the timer, assert `pendingDelta` survives and
  `gestureOwner != .undecided`.

---

### D10 — Event tap and Multitouch callback are registered with unretained pointers and re-registered every 60 s

**CONFIRMED BY INSPECTION** (crash / double-apply unproven).

`ScrollController.swift:1187`

```swift
let selfPtr = Unmanaged.passUnretained(self).toOpaque()
```

`ScrollController.swift:1348` — `registerCallback(dev, contactCallback)` runs on every
`startMultitouchMonitoring()`; there is no `MTUnregisterContactFrameCallback`, and
`WorkspaceManager:392` calls `startEventTap()` from the 60 s reconcile. `stopMultitouchMonitoring`
calls `MTDeviceStop` then `dlclose` (`:1361-1364`) without proving callbacks have drained.

* **Repro:** not yet reproduced. Static hazard: if the controller is released while the tap is
  installed, the next scroll event dereferences freed memory. If the MT callback is registered
  twice, every 3/4-finger delta is applied twice (2× speed).
* **Correction (narrow):** (a) retain the controller for the lifetime of the tap
  (`Unmanaged.passRetained` + `deinit` release, or make `startEventTap` a no-op unless
  `eventTap == nil` — it already guards that, so the real fix is the pointer ownership);
  (b) guard `startMultitouchMonitoring()` with a `didRegisterMT` flag; (c) remove `dlclose` or defer
  it to process exit.
* **Regression risk:** low; touches only lifecycle, no motion math.
* **Proving test:** `multitouchRegistrationIsIdempotent` — call `startMultitouchMonitoring()` twice,
  assert the registered device count is unchanged (expose a test seam counter).

---

### D11 — Per-frame `@Published` mutation, per-frame expected-frame registration, per-frame HUD copy

**CONFIRMED CODE / magnitude HYPOTHESIS.** `computeLayout` itself is cheap (p50 15.3 µs, p95 43.5 µs,
24 windows release), so the layout math is **not** the frame bottleneck. The unmeasured cost is the
observable publish, the observer cache writes and the HUD array copy.

`WorkspaceManager.swift:675-696`

```swift
scrollController.onViewportOffsetChanged = { [weak self] newOffset in
    var ws = self.workspaces[self.activeDisplayId]!
    ws.viewportOffset = newOffset                                   // struct copy
    self.workspaces[self.activeDisplayId] = ws                      // @Published write, every frame
    self.applyPhysicalWindowPositions(workspace: ws)
}
```

`WorkspaceManager.swift:3114` — `observer.recordExpectedFrame(targetFrame, for: winId)` for every
window, every frame, even when no write is issued.

`WorkspaceManager.swift:3119+` — `MinimapHUDController.update(...)` receives a copied columns array
per frame; the comment claiming this is "strictly throttled" is false.

* **Repro:** Instruments Time Profiler during a 10 s scroll on a 20-window strip; compare
  self-time in `objectWillChange` fan-out, `WindowObserver.recordExpectedFrame`, and
  `MinimapHUDController.update`.
* **Correction (narrow):** (a) move `viewportOffset` out of the `@Published` workspace dictionary
  into a plain (non-published) field, or publish at most once per 100 ms; (b) record expected frames
  only for windows actually written this frame; (c) throttle the HUD to 30 Hz (it is a minimap, not
  the strip).
* **Regression risk:** low for (b)/(c); (a) needs the Settings/HUD observers audited for
  `workspaces` dependencies (`MinimapHUDController`, `StatusBarController`).
* **Proving test:** `noObservablePublishDuringMotion` — subscribe to `objectWillChange.sink`, run a
  120-frame gesture, assert ≤ 2 emissions (with `@Published` removed) and that the HUD receives
  ≤ 4 updates/s.

---

## P2 — controls, snapping, transitions

### D12 — `animationDuration` is used as the spring *period*, so the settle is ~1.9× longer than labelled

**CONFIRMED / MEASURED.** `animationDuration = 0.22` → settle **420 ms** at 120 Hz
(`spring_settle`). `response` feeds `omega = 2π/response` (`:78`), and a ζ = 0.905 second-order
system needs ≈ 1.9 periods to reach the 0.4 pt threshold.

* **Repro:** headless `spring_settle`; any UI slider labelled "Animation duration 0.22 s".
* **Correction (narrow):** either rename the setting to "Response time", or convert on input:
  `response = duration / 1.9`. Prefer converting so the label means what users expect, and record
  the mapping in the test.
* **Regression risk:** medium — every snap becomes ~47% faster at the same slider value. Must be a
  deliberate, documented default change (**approval §A4**).
* **Proving test:** `animationDurationMatchesSettleTime` — for durations 0.15/0.22/0.30, assert
  measured time-to-rest is within ±15% of the value.

---

### D13 — Settle trajectory is frame-rate dependent

**CONFIRMED / MEASURED.** Same 1200 pt settle, synthetic timestamps:

| rate | frames | time to rest | pos @50 ms | pos @100 ms | pos @200 ms |
|---|---:|---:|---:|---:|---:|
| 60 Hz | 22 | 350 ms | 579.1 | 951.3 | 1177.6 |
| 80 Hz | 34 | 412 ms | 709.5 | 1024.5 | 1188.9 |
| 120 Hz | 50 | 408 ms | 685.3 | 1025.0 | 1191.7 |
| 240 Hz | 96 | 396 ms | 657.6 | 1026.1 | 1194.6 |

60 Hz reaches the target 58 ms sooner and is **106 pt behind** 120 Hz at the 50 ms mark. The
implicit-Euler step (`:78-90`) with `dt` clamping (`:79`) is the cause.

* **Repro:** headless `spring_settle_rate_sweep`.
* **Correction (narrow):** keep the integrator but sub-step to a fixed 1/240 s inside `step(dt:)`
  (`while remaining > 0 { step(min(remaining, 1/240)) }`). Cost is ≤ 4 sub-steps at 60 Hz and one at
  240 Hz; the spring is 6 flops per sub-step, so this is free. Alternative: use the analytic
  solution already implemented in `CriticallyDampedSpring` — but that changes overshoot behaviour,
  so sub-stepping is the lower-risk fix.
* **Regression risk:** low; makes 60/120/240 agree. Slightly more CPU in the spring branch only.
* **Proving test:** `springTrajectoryIsFrameRateIndependent` — assert the spread of positions at
  50/100/200 ms across 60/80/120/240 Hz is < 5 pt (currently 106 pt at 50 ms).

---

### D14 — `freezeOnRelease` silently disables snapping, momentum, and boundary spring-back

**CONFIRMED BY INSPECTION.** Three settings are presented as independent; one wins invisibly.

* `settle()` returns before the boundary and snap branches (`ScrollController.swift:1049-1057`).
* All momentum packets are dropped (`:881-892`).
* `onSettleRequested` takes the clamped-offset branch and calls `setOffset`, which stops any spring
  (`WorkspaceManager:712-730`).
* `enqueueScroll` clamps `nextTarget` instead of rubber-banding (`:479-481`).

With the current stored defaults (`freezeOnRelease = true`) **`snapToColumn`, `momentumScrolling` and
`animationDuration` never affect a release**. The benchmark confirms they are inert under that
combination.

* **Repro:** defaults, scroll and lift → no snap, no momentum. Then disable freeze-on-release →
  snap and momentum appear.
* **Correction (narrow):** do not change behaviour yet. Make the dependency explicit in the UI
  (disable/grey the dependent controls and show "Freeze on release overrides snapping and momentum"),
  or introduce a three-way release mode (`freeze` / `snap` / `momentum`) rather than two booleans.
  The latter is a settings-model change and needs approval (**§A1**).
* **Regression risk:** low for the UI hint; medium for a three-way mode (migration of stored flags).
* **Proving test:** `releaseModeMatrix` — table test over (freeze, snap, momentum) asserting exactly
  one release behaviour and that the UI model reports the dependencies.

---

### D15 — Fresh-install `freezeOnRelease` default contradicts the changelog and the memory manager

**CONFIRMED BY INSPECTION.**

| source | value |
|---|---|
| `CHANGELOG.md:24` | "stop exactly at finger lift **by default**" |
| `SettingsStore.swift:688` | `... as? Bool ?? false` — fresh install gets **false** |
| `SettingsMemoryManager.swift:89`, `:161`, `:317` | snapshot default **true** |

So a user with a `settings_memory.json` gets freeze-on-release, and a user without one gets
snap-on-release. The two installations behave differently on first launch.

* **Correction (narrow):** pick one and make it a single named constant used by both defaults.
  Do not change it silently — this is the most perceptible behaviour in the app (**approval §A1**).
* **Proving test:** `freshInstallDefaultIsStable` — decode an empty domain and an empty snapshot,
  assert the same value from both paths.

---

### D16 — `maxScrollOffset` returns 0 for a single column

**CONFIRMED BY INSPECTION.** `LayoutEngine.swift:88-96`:

```swift
guard columns.count >= 2 else { return 0 }
```

A single column wider than the usable width can never be scrolled to reveal its right edge, and
`.always` centre mode is unreachable for it.

* **Correction (narrow):** `return max(0, columns[0].width + margins − visibleWidth)` when there is
  one column. Preserve the existing 0 for a column that fits.
* **Regression risk:** low; only enables previously impossible scrolling.
* **Proving test:** `singleWideColumnCanScroll` — one 2000 pt column on a 1400 pt screen, assert
  `maxScrollOffset > 0` and that the right edge reaches `visibleFrame.maxX − margins.right` at max.

---

### D17 — Keyboard centring ignores loop mode and clamps against a different `maxOffset`

**CONFIRMED BY INSPECTION.** `WorkspaceManager.swift:1570-1572`

```swift
let maxOffset = layoutEngine.maxScrollOffset(columns: ..., visibleWidth: ws.displayGeometry.visibleFrame.width, ...)
let centerOffset = layoutEngine.centerColumnOffset(at: current, columns: ..., visibleWidth: ...)
scrollController.scrollTo(target: min(centerOffset, maxOffset), ...)
```

`centerColumnOffset` has a `loopMode` parameter (`LayoutEngine:880`) that is not passed, and the
`min(centerOffset, maxOffset)` defeats the loop branch anyway. The width is the raw visible frame
(no margins), unlike `onQueryMaxOffset`.

* **Correction (narrow):** use the same `maxOffset` accessor as scroll+settle (see D18) and pass
  `loopMode`; drop the `min` clamp in loop mode.
* **Proving test:** `keyboardCenteringMatchesScrollLimits` — assert keyboard and gesture paths agree
  on `maxOffset` for a workspace with margins and for loop mode.

---

### D18 — Five different `maxOffset` formulas

**CONFIRMED BY INSPECTION.** See the table in `01-architecture-map.md` §7
(`WorkspaceManager:664`, `:700`, `:343`, `:1523`, `:3554`, plus `applyLayout`).

The visible consequence is that a snap target, a keyboard centring target, and a scrub thumb can
disagree about where the strip ends — by exactly the margin delta, which is 0 when margins collapse
for a single window and non-zero otherwise.

* **Correction (narrow):** one private `currentMaxOffset(for ws: DisplayWorkspace) -> CGFloat` on
  `WorkspaceManager`, used by all five sites. It must take the same collapsed/edge-together
  arguments that `onQueryMaxOffset` already computes.
* **Regression risk:** low-medium; each site currently compensates for its own width convention.
  Land with the D17 test plus a workspace-with-margins fixture.
* **Proving test:** `maxOffsetIsConsistentAcrossPaths` — assert all five entry points return the
  same value for a fixture with 3 columns, 12 pt gaps, 8 pt margins, one display.

---

### D19 — `onSettleRequested` runs synchronous window application inside the display-link tick

**CONFIRMED BY INSPECTION.** `settle()` is called from `displayLinkFired` (`:583`). With
freeze-on-release (or snap-off), `onSettleRequested` immediately calls
`setOffset` + `applyPhysicalWindowPositions` (`WorkspaceManager:726-729`), which is a full
`computeLayout` + N window writes. With snap-on, `scrollTo` can complete synchronously when the
target is within 0.5 pt, firing `onAnimationCompleted` → another `applyPhysicalWindowPositions`
(`:753-770`). So up to two full layout passes run inside one frame callback.

* **Correction (narrow):** coalesce: have `onSettleRequested` set a `pendingSettleApplication` flag
  and let the *next* `displayLinkFired` (or a `DispatchQueue.main.async`) do the application once.
  Do not call `applyPhysicalWindowPositions` synchronously from either callback.
* **Regression risk:** low; adds ≤ 1 frame of latency to the final correction, removes a
  re-entrancy path.
* **Proving test:** `settleAppliesOncePerFrame` — count `applyPhysicalWindowPositions` calls per
  tick during a settle; assert ≤ 1.

---

### D20 — `shouldInterceptScroll` is called off the main actor despite `@MainActor` isolation

**CONFIRMED BY INSPECTION.** `ScrollController` is `@MainActor` (`:154`), but the tap callback calls
`controller.shouldInterceptScroll(...)` before any thread check (`:1213`); only `enqueueScroll` is
marshalled to main (`:1214-1230`). The tap is attached to `CFRunLoopGetMain()` (`:1250`), so in
practice it runs on main — but the code does not enforce what it declares, and a tap created on a
different run loop (or a future refactor) is a data race on `gestureOwner`, `lastScrollEventTime`
and `isActivelyScrolling`.

* **Correction (narrow):** move the `Thread.isMainThread` marshalling to wrap the whole body, or
  mark `shouldInterceptScroll` `nonisolated` with an explicit lock. Prefer the former.
* **Regression risk:** low, but adds one dispatch hop in the hot path — measure tap latency after
  (currently claimed `< 5 µs`, unverified).
* **Proving test:** `tapCallbackIsMainActorIsolated` — assert `MainActor.assumeIsolated` does not
  trap when the callback runs, or add a debug assertion `Thread.isMainThread`.

---

## P3 — polish, observability, dead code

### D21 — `CriticallyDampedSpring` is dead

Declared `ScrollController.swift:98-133`, stored at `:192`, never sampled/retargeted/stepped.
It is the only implementation with an analytic solution, and D13 needs frame-rate independence.
Either delete it or use it. **Recommendation:** delete after D13 lands, so there is one spring.

### D22 — `onSwipeSettled` has no consumer

Declared `:163`, fired at `:840`, `:849`, `:1054`, `:1078`. `grep` finds no assignment anywhere in
`Sources/`. Delete or wire it to the settle-pass application; do not leave a callback that implies
a second settle path (the inventory's "snap runs twice" claim likely refers to this).

### D23 — Rust engine is not on the scroll path (documentation is false)

`CHANGELOG.md:41-43` claims `LayoutEngine` delegates layout/viewport/snap to Rust and
`ScrollController` uses the Rust spring "for every animation frame". Neither file references
`RustEngine`; only `MagneticWindowEngine` does (`:59`, `:192`, `:286`). `RustEngine.step` and
`springIsAtRest` are never called.

Consequence beyond documentation: the Swift and Rust spring at-rest thresholds differ
(`<0.40/<3.5` vs whatever `spring.rs` uses) and `spring_bench.rs` measures behaviour users never see.
**Recommendation:** correct the changelog and `docs/ARCHITECTURE.md` in Phase 2, and decide
explicitly whether the Rust spring is the target implementation (see `05-phase-plan.md` §4). Do not
"just switch" it on: `spring_bench.rs` shows the Rust spring is itself frame-rate dependent
(60→240 Hz spread 24.9 pt at 100 ms).

### D24 — No unified logging or signposts anywhere

`grep` for `os_log|os_signpost|OSLog|Logger` across `Sources/` returns **zero** matches.
`Diagnostics.swift` is an in-memory 500-entry ring buffer with four counters, invisible to
Instruments and `log stream`. Every latency claim in this audit must therefore come from the
external harness; nothing can be correlated with a trace until the signposts in
`03-instrumentation.md` are added.

---

## 5. Documented features vs code reality

| feature | documented | code reality | verdict |
|---|---|---|---|
| Physical spring physics | `ARCHITECTURE.md:151,198`; `CHANGELOG:28` | `SpringState.step`, implicit Euler, response = period | **works, but mislabelled** (D12, D13) |
| Rust layout + spring | `CHANGELOG:41-43` | not called from the scroll path at all | **false** (D23) |
| Viewport-aware window updates | `ARCHITECTURE.md` | `computeLayout` yes; `computeSnapTarget` no; 5 maxOffset variants | **partial** (D08, D18) |
| Magnetic snapping | `IUME_INVENTORY §7` | `MagneticWindowEngine` (Rust-backed) exists but is **not on the scroll settle path**; scroll snapping is `LayoutEngine.computeSnapTarget` | **different feature than documented** |
| Smoothness control | settings UI, `CHANGELOG` | affects the non-touch filter and the settle spring; **inert during direct touch** (measured identical output at 0/0.75/1) | **partial** (D04) |
| Live preview | settings UI | preview uses the same `computeLayout`; not exercised in this audit (no UI automation) | **unverified** |
| Freeze on release | `CHANGELOG:24` | implemented, but default is inconsistent and it overrides snap + momentum | **works, over-broad** (D14, D15) |
| Column snapping | settings, `CHANGELOG` | implemented via projection; **unreachable when freeze is on**; not loop-aware | **partial** (D08, D14) |
| Momentum scrolling | settings | native momentum is 1:1; custom coast can double-integrate; **dropped entirely when freeze is on** | **partial** (D14) |
| Keyboard scrolling | shortcuts | implemented; loop-blind and margin-blind | **partial** (D17) |

---

## 6. Suspected but unproven — needs profiling (do not report as measured)

1. **Tap-induced system-wide latency.** A session-level `.defaultTap` runs synchronously on the main
   run loop; any main-thread stall during a frame delays *every* app's scroll events. Measure with
   signposts around `displayLinkFired` and `window.setPositionAsync`.
2. **AX write latency per app.** `AXUIElementSetMessagingTimeout(element, 0.10)` in the settle path
   (`WindowController:522`) and 0.04 s on the app element (`:32`, `:69`). A single 100 ms timeout in
   a batch makes the settle visibly late. Needs a per-PID histogram.
3. **Electron/Chromium behaviour.** `AXEnhancedUserInterface` is set false once per writer
   (`:39-45`) and restored on deinit. Whether a given Electron app honours it during motion is
   unmeasured.
4. **Per-frame `objectWillChange` cost.** D11; needs Time Profiler with the SwiftUI instrument.
5. **HUD/minimap cost.** `MinimapHUDController.update` per frame with a copied columns array.
6. **Duplicate application via multitouch + synthetic scroll events.** D10/§3; needs a live
   instrumented gesture counting both inputs per physical swipe.
7. **`dt` clock domain mixing.** Multitouch timestamps vs `CACurrentMediaTime` (`:1376-1395`);
   possible first-frame velocity spike in `applyInteractiveDelta`.
8. **60 vs 120 Hz display-link behaviour.** `CAFrameRateRange(minimum: 80, maximum: 120)` on a 60 Hz
   panel (`:347`, `:361`): does the link run at 60, or does the range force a fallback timer? This
   machine is 60 Hz only, so ProMotion cannot be measured here.
9. **Window overlap/gap in practice.** `analyze.py` computes it; needs a live capture with the app
   running.
