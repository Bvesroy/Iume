# 01 — Sliding architecture and event-flow map

Scope: everything that moves windows horizontally.

> **Snapshot notice.** This map describes the tree at fingerprint
> `81b51e7873106dbe1d879228d3a6407fde64aa4c` (22:58). A concurrent process rewrote
> `ScrollController.swift` and added `Sources/IumeCore/Physics/SpringState.swift` at 23:07–23:12.
> Line numbers below that point do not match the current tree. Read
> [`07-working-tree-drift.md`](07-working-tree-drift.md) first.

Commit `9992c80` + uncommitted working-tree edits (the tree is dirty on `ScrollController.swift`,
`LayoutEngine.swift`, `WorkspaceManager.swift`, `SettingsStore.swift`,
`crates/iume_engine/src/layout.rs`; this map describes that snapshot).

Every claim below is annotated with `file:line`.

---

## 1. Pipeline at a glance

```
HID trackpad ──► MultitouchSupport.framework          HID wheel/trackpad ──► CGEventTap (session, head-insert)
                        │                                        │
                        │ MTContactCallback (non-main thread)    │ callback runs on the main run loop
                        ▼                                        ▼
             DispatchQueue.main.async                shouldInterceptScroll()  ScrollController:1088
                        │                                        │  (ownership decision, returns nil to consume)
                        ▼                                        ▼
                  applyInteractiveDelta()                 enqueueScroll()  ScrollController:855
                        │  3/4-finger path                        │  accumulates pendingDelta × sensitivity × natural
                        └──────────────┬───────────────────────────┘
                                       ▼
                          CADisplayLink (NSScreen.displayLink)  ScrollController:344
                          120 Hz preferred, 80–120 range, paused when idle
                                       │
                                       ▼
                          displayLinkFired(timestamp:)  ScrollController:398
                                       │
              ┌────────────────┼─────────────────┬──────────────────┐
              ▼                ▼                 ▼                  ▼
        direct 1:1      momentum coast     exp. filter        spring settle
      (touch / macOS   (custom, friction   (wheel/coast)      (SpringState.step)
       momentum)        0.965/frame)                             :598
              └────────────────┴─────────────────┴──────────────────┘
                                       │ currentOffset
                                       ▼
                       onViewportOffsetChanged?(offset)   :601/:580/...
                                       │
                                       ▼
        WorkspaceManager:675  ──►  ws.viewportOffset = offset
                                   workspaces[activeDisplayId] = ws   (@Published, every frame)
                                   applyPhysicalWindowPositions()      WorkspaceManager:3062
                                       │
                                       ├─ LayoutEngine.computeLayout()          LayoutEngine:242
                                       ├─ observer.recordExpectedFrame() × N    WorkspaceManager:3114
                                       ├─ WindowController.applyStripFrames()   WindowController:254
                                       │     ├─ isMoving  → WindowWriter.setPositionAsync (per-PID queue)
                                       │     └─ settled   → setFrame / setPosition (+ CGS atomic batch)
                                       └─ enforceStripZOrder() (signature-cached) WindowController:357
```

**One sentence:** the strip is a single scalar `currentOffset`; every window is a pure function of
that scalar, recomputed from scratch each display-link tick and pushed over Accessibility.

---

## 2. Event acquisition

| source | entry point | thread | notes |
|---|---|---|---|
| 2-finger / wheel scroll | `ScrollController.startEventTap()` `:1184` | `CFRunLoopGetMain()`, `.common` (`:1250`) | `.cgSessionEventTap`, `.headInsertEventTap`, `.defaultTap` (`:1240-1244`). Synchronous, session-wide. Returns `nil` to swallow the event (`:1233`). |
| 3/4-finger swipe | `startMultitouchMonitoring()` `:1272` | MultitouchSupport callback thread | dlsym of `MTDeviceCreateList` / `MTRegisterContactFrameCallback` / `MTDeviceStart` (`:1280-1296`). Each contact frame hops to main via `DispatchQueue.main.async` (`:1329`). |
| keyboard scroll | `WorkspaceManager` shortcuts `:1520-1572` | main | commands in `Sources/IumeCore/Shortcuts/`. |
| mouse drag / resize | `MouseStateKeeper` + `WindowObserver` | main | not a scroll source, but gates writes (`resizingWindowId`). |

Tap lifecycle issues (see findings D10, D20):
* `Unmanaged.passUnretained(self)` as `userInfo` (`:1187`) — dangling if the controller deallocates
  while the tap is installed.
* `shouldInterceptScroll` is called **before** the `Thread.isMainThread` check (`:1213`), so the
  class's `@MainActor` isolation is not enforced on that call even though it mutates state.
* `startEventTap` is called again from `reconcileUnmanagedWindows` (`WorkspaceManager:392`), and
  `startMultitouchMonitoring` re-registers the contact callback with no unregister path (`:1348`).

---

## 3. Gesture lifecycle and ownership

`GestureOwner` is a one-way latch inside a gesture: `.undecided → .strip | .app`.

```
phase 1/32 ──► gestureOwner = .undecided                      :1107
modifier    ──► gestureOwner = .strip, consume                :1112
|dx|>|dy| threshold ──► .strip                                :1129-1141 (UNVERIFIED exact branch)
.strip latched ──► every event consumed until phase 4/8 or 150 ms silence  :1119-1143
150 ms watchdog ──► gestureOwner = .undecided, isActivelyScrolling = false :1101-1104
```

There is **no `.strip → .app` hand-back** inside a gesture. A diagonal gesture that latches
horizontal keeps consuming vertical motion until it ends. In `seamlessHorizontal` mode the tap
also consumes events whose `|dx| < |dy|` (`:863-871`), which is how vertical scrolling inside an
app can be swallowed.

Two independent writers feed the same offset:

* `applyInteractiveDelta()` — 3/4-finger path, writes `pendingInteractiveDelta`.
* `enqueueScroll()` — wheel/trackpad path, writes `pendingDelta`.
* `displayLinkFired()` consumes both, in different branches (`:410` vs `:461`), so a single physical
  gesture that produces both a multitouch contact stream **and** synthetic scroll events is applied
  twice. This is the mechanism behind ISSUE-05 (diagonal hijack) and is not yet disproven live.

---

## 4. State ownership (the core structural problem)

There is **no single owner of the viewport offset**. Four values describe it and all four are
written from different places.

| state | declared | writers | readers |
|---|---|---|---|
| `currentOffset` | `ScrollController:171` | `displayLinkFired` (`:436`, `:502`, `:557`, `:577`, `:600`, `:617`), `setOffset` (`:664`), `scrollTo` (`:702`, `:749`), `scrollBy` (`:776`) | layout, `isMoving`, callbacks, HUD |
| `smoothTargetOffset` | `:172` | `enqueueScroll` (`:890`, `:927`, `:934`), `displayLinkFired` (`:497`, `:625`), `setOffset` (`:670`), `scrollTo` (`:706`), `settle` (`:1048`, `:1080`) | filter step, projection base |
| `springState.position` | `SpringState:62`, stored `:181` | `displayLinkFired` (`:435`, `:505`, `:516`, `:545`, `:567`), `setOffset` (`:669`), `scrollTo` (`:738`), `scrollBy` (`:784`), `normalizeLoopOffsetAtRest` (`:294`) | spring step, `isMoving` |
| `springState.target` | same | same sites | spring step, `isMoving` |
| `ws.viewportOffset` | `CoreModels` / `WorkspaceManager` workspace | `onViewportOffsetChanged` (`WorkspaceManager:679`), settle paths (`:726`, `:744`) | `computeLayout`, HUD, persistence |
| `currentVelocity` | `:173` | filter (`:556`), touch (`:437`), settle (`:1056`, `:1077`) | projection, telemetry, `zOrder`? |
| `settleVelocity` | `:174` | `settle` (`:1076`), `scrollTo` (`:729`), `cancelAnimation` (`:809`) | `onSettleRequested` → `scrollTo(initialVelocity:)` |

`springState.velocity` is never cleared by the `snapToColumn == false` settle branch (`:1079-1083`),
and `isMoving` includes `!springState.isAtRest` (`:188-190`). That single omission is D02.

Two extra "stopped" definitions exist and disagree:

* `SpringState.isAtRest` — `|Δ| < 0.40 && |v| < 3.5` (`:68-70`)
* `isPositionAtRest` — `<= 0.05` (`:321-324`)
* `CriticallyDampedSpring.isSettled` — `< 0.35 && |v| < 3.0` (`:129-131`), dead code

### Dead / unused motion machinery

| symbol | location | status |
|---|---|---|
| `CriticallyDampedSpring` | `:98-133`, stored `:192` | **never sampled, retargeted or stepped.** Dead. |
| `RustEngine.step(spring:)` | `RustEngine.swift:384` | **never called.** |
| `RustEngine.springIsAtRest` | `RustEngine.swift:398` | never called. |
| `onSwipeSettled` | `:163`, fired `:840/:849/:1054/:1078` | **no consumer** in `WorkspaceManager` or anywhere else. |

`RustEngine` *is* used, but only by `MagneticWindowEngine` (`MagneticWindowEngine.swift:59, 192, 286`).
Neither `LayoutEngine` nor `ScrollController` references it. This contradicts `CHANGELOG.md:41-43`
and `docs/ARCHITECTURE.md:151`.

---

## 5. The four motion models (why motion feels inconsistent)

`displayLinkFired` selects a branch per frame:

| # | branch | condition | behaviour | location |
|---|---|---|---|---|
| 1 | **Direct 1:1** | `isDirectTouch` = phase 1/2 within 120 ms | `currentOffset = smoothTargetOffset` — no filter, no interpolation | `:492-499` |
| 2 | **Native momentum** | `momentumPhase 1/2` | same 1:1 assignment | `:492-499` |
| 3 | **Custom coast** | `isMomentumCoasting` (set when macOS momentum does not arrive and \|v\|>25) | `v *= 0.965^(dt·60)`; `target += v·dt` | `:507-531` |
| 4 | **Exponential filter** | wheel / post-gesture | `λ = max(28, 35+(1−s)·80)`, `factor = 1−e^(−λ·dt)` | `:534-575` |
| 5 | **Spring** | `isSpringAnimating` | `SpringState.step`, implicit Euler, `response` = period | `:596-632` |

Branch 3 can run *while* macOS momentum events arrive → two integrators on one velocity
(the "double integrator" in `IUME_COMPLETE_INVENTORY.md` §5.3). Branch 1 bypasses branch 4
entirely, which is why the smoothness slider is inert during finger contact (measured, §04).

---

## 6. Layout → window application

```
applyPhysicalWindowPositions(workspace)                    WorkspaceManager:3062
  guard !disabledDisplayIds.contains(display)              :3063
  isMoving = scrollController.isMoving                     :3065
  programmaticResetTimer 0.45 s (only when !isMoving)      :3069-3076
  computation = layoutEngine.computeLayout(...)            :3082-3098
  for each column / window:
      registry.getAXElement + getCGWindowID                :3110
      observer.recordExpectedFrame(targetFrame, 0.65s)     :3114   ← unconditional, every frame
  controller.applyStripFrames(placements:visibleFrame:isMoving:)
      ├─ async: setPositionAsync (per-PID WindowWriter)     WindowController:300-304, 472
      └─ settled: setFrame/setPosition inside CGS atomic   WindowController:307-336, 241, 521
  updateTabBarOverlays + dimming + focus border            :3126-3150
```

Key properties:

* `applyStripFrames` splits visible vs parked by a 12 pt sliver test
  (`rawRect.origin.x < visibleFrame.maxX - 12 && rawRect.maxX > visibleFrame.minX + 12`)
  and parks offscreen windows against an edge (`WindowController:254-368`).
* **`isMoving` is sampled once at the top** (`:3065`). If the spring finishes inside
  `computeLayout`, the frame is still written through the *async* path and the authoritative
  settle pass is deferred to the next `onAnimationCompleted` callback (`:762`). Under a stall this
  is the frame where a slow app is left behind.
* `recordExpectedFrame` suppresses the observer's "window moved" echo for 650 ms. Because it is
  recorded on every frame regardless of whether a write succeeded, a window that ignores a write
  has its real position filtered out as "expected" for 650 ms — the observer cannot correct it.
* `enforceStripZOrder` is invoked every frame (`:357`) but short-circuits on a `ZOrderSignature`
  equality check (`WindowController:397-404`), so its steady-state cost is one array compare.

---

## 7. Snapping, boundaries, loop mode

`maxOffset` is recomputed from **five** different formulas:

| site | width used | margins | gap | centre mode |
|---|---|---|---|---|
| `onQueryMaxOffset` `WorkspaceManager:664-672` | `visibleFrame.width − margins` (collapsed if ≤1 window) | smart-aware | collapse-aware | yes |
| `onSettleRequested` `:700-709` | `visibleFrame.width − edgeMargins` | raw | `appsEdgeTogether ? 0 : gap` | yes |
| scrub / ratio `:343-344` | `visibleFrame.width − margins` | raw | default | default |
| keyboard `:1523`, `:1532`, `:1570` | raw `visibleFrame.width` | none | default | yes |
| `applyScrollDelta` `:3554-3559` | raw `visibleFrame.width` | none | default | default |

`settle()` (`ScrollController:1027`):

```
freezeOnRelease == true   → emit onSettleRequested(currentOffset) and RETURN   :1049-1057
offset < 0 or > maxOffset → scrollTo(boundary)                                :1060-1071
snapToColumn == true      → projection = base + currentVelocity * 0.18        :1073-1078
snapToColumn == false     → clear currentVelocity, emit completed              :1079-1083
```

The `0.18` is a hard-coded projection horizon, not derived from the spring. Measured exactly
0.18 s (`04-baseline.md`).

`scrollTo` (`:682`) converts `duration` into the spring's **period**, not its settle duration:

```
springState.response     = max(0.08, duration * (0.70 + smoothness*0.40))     :742
springState.dampingRatio = max(0.88, 0.98 - smoothness*0.10)                 :743
```

At the defaults (0.22 s, 0.75) that is `response = 0.22`, `ζ = 0.905` → settle ≈ 1.9 periods
≈ **420 ms** measured. The label says 0.22 s.

Loop mode is a parallel geometry:

* Controller branches on `isLoopModeEnabled` to skip rubber-band (`:419-430`) and boundary
  spring-back (`:1060`).
* `LayoutEngine` only loops when `columns.count >= 2 && period >= visibleWidth &&
  layoutMode.supportsLoop` (`LayoutEngine:148`, `:338`).
* These two conditions are set independently (`WorkspaceManager:3013-3014`) → D03.
* `computeSnapTarget` is called **without** `loopMode:` (`WorkspaceManager:733-741`) → D08.

---

## 8. Frame pacing and timers

| timer / source | rate | mode | pause condition |
|---|---|---|---|
| `CADisplayLink` (`:344`) | requested 120, range 80–120 | `.common` | `isPaused` set when `hasPendingSettle == false && !isSpringAnimating && !isMoving && diff <= 0.05` (`:636`) |
| `fallbackTimer` (`:376`) | 120 Hz | `.common` | invalidated in `pauseDisplayLink` |
| `settleTimer` (`:991`) | `0.10 + smoothness*0.08` s | **default** | invalidated in `settle` / `cancelAnimation` |
| `momentumWatchdogTimer` (`:901`, `:947`) | 0.12 s / 0.09 s | **default** | invalidated on momentum end |
| `programmaticResetTimer` (`WorkspaceManager:3070`) | 0.45 s | default | invalidated every `applyPhysicalWindowPositions` |
| `periodicReconcileTimer` (`:375`) | 60 s | default | — |
| `persistenceTimer` (`:3568`) | 0.5 s | default | — |

The two timers that can call `settle()` mid-gesture are registered in the **default** run-loop mode,
unlike the display link, so they do not fire during a tracking-mode scroll — but they can fire
between two gesture phases and they test only `lastMomentumPhase`, not `phase` or
`isActivelyScrolling` (`:903-916`, `:949-963`). That is D09.

`dt` handling: first frame uses `1/120` (`:400`); the spring clamps `dt` to `[0.001, 0.033]`
(`:79`), so below 30 fps the animation advances at most 33 ms per real frame and stretches in
wall-clock time. `dt` is taken from the injected timestamp, so a display-link timestamp that is
not monotonic produces a negative `dt` → clamped to 1 ms.

---

## 9. Display / focus / resize interactions

* Display change → `attachDisplayLink(to:)` (`:357`), `WorkspaceManager.handleDisplaysChanged`
  (`:2090`), `viewportOffset` re-derived from `visibleFrame.width` ratio (`:2090-2091`).
  `ScrollController.maxOffset` is not updated in that path; it is refreshed on the next
  `onQueryMaxOffset` (`enqueueScroll` phase 1 or `settle`). A display change while idle therefore
  leaves a stale `maxOffset` until the next gesture.
* Focus: `onAnimationCompleted` (`WorkspaceManager:759-770`) calls `applyPhysicalWindowPositions`
  and `focusWindowProgrammatically` if the focused id changed, guarded by
  `suppressFocusNotification(for:duration:0.60)`.
* Resize: `activelyResizingWindowId` skips writes for the resizing window
  (`WindowController:270-276`) and `applyStripFrames` receives `resizingWindowId`.
* Mouse drag: `MouseStateKeeper` blocks frame application during a drag
  (`WorkspaceManager:3196+`).

---

## 10. Structural risks (ranked by blast radius)

1. **Offset has no single owner** (§4). Four representations, six writers, three "stopped" tests.
2. **Five motion models selected per frame** (§5). Two of them (1 and 2) bypass the only filter,
   which is the measured stutter mechanism.
3. **`maxOffset` has five formulas** (§7). Clamps, snaps and keyboard scroll can disagree.
4. **Per-frame observable mutation + per-frame expected-frame registration** (§6). `@Published`
   dictionary reassignment at 120 Hz, plus N observer cache writes per frame.
5. **Write-intent cache is treated as ground truth** (`WindowController:205`, `:475-486`, `:307-336`).
   No read-back path exists anywhere; slow apps are never corrected until the intent moves >0.5 pt.
6. **Loop mode is two independent switches** (controller vs layout engine) that can disagree (§7).
7. **Gesture latch is one-way** (§3) and the tap consumes session-wide.
8. **Rust engine is not on the scroll path** despite the changelog; the Swift and Rust spring
   implementations are duplicated with different at-rest thresholds.

---

## 11. Phase 2–5 skeleton (detail in `05-phase-plan.md`)

* **Phase 2 — correctness first.** Clamp on spring completion; clear `springState.velocity` in every
  settle branch; gate loop mode on the layout engine's own predicate; pass `loopMode` to
  `computeSnapTarget`; unify `maxOffset` behind one accessor.
* **Phase 3 — one motion model.** Add a single touch-resampling stage (no second animation engine),
  keep the existing `smoothTargetOffset`/filter machinery, make the smoothness slider mean one thing.
* **Phase 4 — window application.** Move to read-back-verified writes for the settle pass; coalesce
  the per-frame `@Published` mutation; make `recordExpectedFrame` conditional on a successful write.
* **Phase 5 — observability + tuning.** Ship the signposts from `03-instrumentation.md`, add
  permission-free benchmarks to CI, expose the settle/projection constants as tested behaviour.

**Do not touch:** tab-group behaviour, `WindowTabGroupingTests`, BSP/box/grid layout modes,
permission flow, packaging.

---

## 12. Documentation contradictions (verified)

| claim | source | reality |
|---|---|---|
| "`LayoutEngine` now delegates `computeLayout`, `computeViewportOffset`, `maxScrollOffset`, `findClosestColumnIndex`, `computeSnapTarget` … to the Rust engine" | `CHANGELOG.md:41` | `LayoutEngine.swift` contains no `RustEngine` reference. |
| "`ScrollController` uses the Rust spring integrator for every animation frame" | `CHANGELOG.md:43` | `ScrollController.swift` contains no `RustEngine` reference; it uses `SpringState.step`. |
| "`freezeOnRelease` … by default" | `CHANGELOG.md:24` | `SettingsStore.swift:688` defaults to `false` when no stored value exists; `SettingsMemoryManager` defaults to `true` (`:89`, `:161`, `:317`). Fresh install and restored-snapshot install differ. |
| "220 ms perceptual response" | `ScrollController.swift:65` | `response` is the oscillator **period**; measured settle 420 ms at that setting. |
| "silky 120 Hz harmonic spring settle … zero visual flicker" | `docs/ARCHITECTURE.md:198` | The settle model is not the model that runs during the gesture; the gesture path is a hard 1:1 assignment. |
| "viewport-aware window updates" | `docs/ARCHITECTURE.md` | True for `computeLayout`; false for `computeSnapTarget` (not loop-aware) and for five `maxOffset` variants. |
