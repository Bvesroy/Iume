# 03 — Instrumentation and measurement method

## 0. What exists today

`grep -r "os_log\|os_signpost\|OSLog\|Logger" Sources/` → **zero matches**.

The only built-in telemetry is `Sources/IumeCore/Diagnostics/Diagnostics.swift`: an `NSLock`-guarded
in-memory ring buffer (500 `LogEntry`, four counters, `exportDiagnosticReport()`). It is invisible to
`log stream` and to Instruments, so **no existing signal can be correlated with a trace**. Every
number in `04-baseline.md` comes from the external harness described below.

## 1. External harness (works today, no source changes)

### 1.1 Controller/layout benchmark — `scripts/audit/scroll_bench.swift`

Links the prebuilt `libIumeCore.a` and drives the real `ScrollController` through its public API
(`setOffset`, `scrollTo`, `scrollBy`, `enqueueScroll`, `settle`, `displayLinkFired(timestamp:)`) and
the real `LayoutEngine.computeLayout`. It never starts a run loop, an event tap or a display link,
so nothing else can tick.

Why it is trustworthy for physics: `displayLinkFired(timestamp:)` is the exact function the
display link calls; it accepts an injected timestamp, and the harness paces injection against
`CACurrentMediaTime()` so that the controller's own wall-clock comparisons (direct-touch detection,
`dtScroll`) see a realistic timeline. An earlier version injected time faster than wall time and
produced a false "input lag" of 183 pt — that failure mode is recorded in `04-baseline.md` §7 so it
is not repeated.

### 1.2 Live window sampler — `scripts/audit/window_sampler.swift`

Standalone `swiftc` binary. `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])`
at 1–240 Hz, plus `proc_pid_rusage` CPU/RSS every 250 ms.

CSV schema:

```
t_monotonic_s,window_number,pid,owner,bounds_x,bounds_y,bounds_w,bounds_h,layer
```

Header comments record the ISO start, target pid, requested Hz, the display mode
(`1470x956`, pixel `2940x1912`, 60 Hz) and `NSScreen.maximumFramesPerSecond`. Trailer records
`sample_call_cost_ms_p50/p95/max`, `interval_ms_*`, `deadline_overruns`, `cpu_source`.

Validated on this machine: 5 s at 20 Hz → 99 samples, 495 rows, achieved **20.2 Hz**,
`CGWindowList` call cost p50 **0.610 ms** / p95 0.934 / max 5.784, **1** deadline overrun. Raw
output in `$TMPDIR/iume-audit/sample.csv` and `sample-analysis.txt`.

### 1.3 Analyser — `scripts/audit/analyze.py`

stdlib-only. Reports: sampling floor (max of sample period and call cost, cross-checked against the
display commit period), interval p50/p95/max, motion episodes, per-window `|dx|`/`|dy|`, resize
count, direction reversals with a reversals-per-moving-step ratio, adjacent-window gap/overlap
series, total path length. Emits `--json`.

**Sampling floor on this machine: 50 ms (20 Hz).** Nothing faster is observable with that run.
Run the sampler at 120 Hz for hitch work and accept a higher call cost; at 120 Hz the call itself
(0.54 ms) is 6.5% of the 8.33 ms budget.

## 2. Proposed signposts (diff-style, **not applied**)

Minimal set that answers the four questions the external harness cannot: input→first-offset-change,
per-frame main-thread cost, AX write latency, settle duration. One `OSLog` subsystem, one signposter,
six intervals. No behaviour change.

```diff
+// Sources/IumeCore/Diagnostics/Signposts.swift
+import os
+
+public enum IumeSignpost {
+    public static let log = OSLog(subsystem: "com.iume.Iume", category: .pointsOfInterest)
+    public static let scroll = OSSignposter(logHandle: log)
+}
```

```diff
// ScrollController.swift — displayLinkFired(timestamp:)
 public func displayLinkFired(timestamp: CFTimeInterval? = nil) {
+    let sp = IumeSignpost.scroll.beginInterval("scroll.frame")
+    defer { IumeSignpost.scroll.endInterval("scroll.frame", sp) }
     let now = timestamp ?? CACurrentMediaTime()
```

```diff
// ScrollController.swift — enqueueScroll(...)  (after effectiveDelta is computed)
+    IumeSignpost.scroll.emitEvent("scroll.input", "dx=\(dx, privacy: .public) dy=\(dy, privacy: .public) phase=\(phase, privacy: .public) mom=\(momentumPhase, privacy: .public)")
     pendingDelta += effectiveDelta
```

```diff
// WorkspaceManager.swift — onViewportOffsetChanged
 scrollController.onViewportOffsetChanged = { [weak self] newOffset in
+    let sp = IumeSignpost.scroll.beginInterval("workspace.apply")
+    defer { IumeSignpost.scroll.endInterval("workspace.apply", sp) }
     var ws = self.workspaces[self.activeDisplayId]!
```

```diff
// WindowController.swift — setPositionAsync(element:...)
 public func setPositionAsync(element: AXUIElement, position: CGPoint, size: CGSize = .zero, windowId: WindowId) {
+    let sp = IumeSignpost.scroll.beginInterval("window.setPositionAsync")
+    defer { IumeSignpost.scroll.endInterval("window.setPositionAsync", sp) }
     let rounded = CGPoint(x: round(position.x), y: round(position.y))
```

```diff
// WindowController.swift — setFrame(element:...)
 public func setFrame(element: AXUIElement, frame: CGRect, windowId: WindowId? = nil) -> Bool {
+    let sp = IumeSignpost.scroll.beginInterval("window.setFrame")
+    defer { IumeSignpost.scroll.endInterval("window.setFrame", sp) }
     AXUIElementSetMessagingTimeout(element, 0.10)
```

Also useful, one line each: `scroll.settle.begin/end` around `settle()`, and
`window.axWrite` as an **event** inside `WindowWriter`'s drain loop immediately before
`AXUIElementSetAttributeValue`, carrying the `AXError` code. That last one is the only way to see a
timed-out write, because the caller currently discards the error (`WindowController.swift:95`).

Then:

```sh
log stream --predicate 'subsystem == "com.iume.Iume"' --style compact
xctrace record --template 'Time Profiler' --launch ./Iume ...
```

## 3. Trace recipes (command verified to fail here; names unverified)

`xctrace` is **not available on this machine**: `xcode-select -p` is `/Library/Developer/CommandLineTools`
and `xcrun --find xctrace` fails. `/Applications/Instruments.app` and Xcode are absent. Therefore
**the template names below could not be verified here** and must be confirmed on a machine with
Xcode using:

```sh
xctrace list templates
```

Expected (unverified) templates and intended use:

| template | what it answers |
|---|---|
| Time Profiler | per-frame main-thread self time; `computeLayout`, `objectWillChange`, HUD |
| Animation Hitches | true hitch/frame-miss attribution (the only trustworthy source) |
| Core Animation | commit/composite cost, offscreen passes, layer count |
| System Trace | WindowServer IPC, thread scheduling, AX round-trips |
| Metal System Trace | only if a GPU-bound overlay is suspected (not the strip itself) |

Recording shape:

```sh
xctrace record --template 'Time Profiler' \
  --time-limit 30s --output /tmp/iume.trace --launch /Applications/Iume.app
```

## 4. What cannot be measured on this machine, even with the harness

| metric | why |
|---|---|
| Input-to-first-visible-motion (true) | needs a physical trackpad event with a hardware timestamp + a composited-frame timestamp. The harness measures controller-internal latency only. |
| Present-to-photon / dropped frames | needs `Animation Hitches` or a Core Animation trace, i.e. Xcode. |
| 120 Hz ProMotion behaviour | this display is **60 Hz** (`NSScreen.maximumFramesPerSecond == 60`), so the 80–120 range request cannot be exercised. |
| Per-app AX write latency | requires Accessibility trust for the running app and a live window set. Requires launching Iume (approval §A0). |
| Electron / many-window behaviour | same. |
| Tab-group interaction | out of scope by instruction. |

## 5. Caveats that apply to every sampler number

1. `CGWindowList` returns **committed/composited** geometry, not present timing. Deltas are quantized
   to the display refresh; at 20 Hz six 120 Hz commits merge into one sample.
2. Reversal counts are **lower bounds** (Nyquist): an oscillation faster than the floor aliases into
   a slower apparent oscillation or into noise.
3. `ps -o pcpu=` is a decayed average; the `proc_pid_rusage` path is instantaneous but the 250 ms
   sampling timer itself perturbs CPU by a few percent of one core.
4. `DispatchTime.uptimeNanoseconds` is monotonic and does not advance across sleep the way wall
   time does.
5. `NSScreen.maximumFramesPerSecond` can read 0 outside an `NSApplication`; the CG mode refresh rate
   is then authoritative (and is 0 on some variable-refresh modes).
6. Coordinate spaces: Iume works in top-left-origin Quartz coordinates; `CGWindowList` is also
   top-left global but excludes menu-bar/Dock offsets that `NSScreen.visibleFrame` includes.
   Normalise before diffing or every comparison shows a constant y error.
