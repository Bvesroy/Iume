# Iume — Fixes, Feature Parity & Upgrade Instructions

**Goal:** make Iume as smooth, reliable and complete as ChainYourMac / TileMyMac, with every behaviour happening automatically.
**Date:** 15 Oct 2026 · **Audience:** whoever is editing the Iume codebase (the developer or engineer).

---

## 0. Read this first (scope and honesty)

**What I analysed**
- Your 6 docs: `ARCHITECTURE.md`, `COMPATIBILITY.md`, `TROUBLESHOOTING.md`, `SHORTCUTS.md`, `PERMISSIONS.md`, `FEASIBILITY_REPORT.md`
- Your feature list and issue list
- chainyourmac.com (home page) and chainyourmac.com/setup (the setup guide, which explains a lot about how they work)

**What I could NOT do**
- **I have not seen your source code.** Root causes below are *most likely causes inferred from your architecture docs*. Each one has a "Confirm" step (a 10-minute check) so you can verify before changing anything. Treat them as a ranked hypothesis list, not a verdict.
- **tilemymac.com blocks automated access**, so I could not inspect it. Everything I say about "parity" comes from ChainYourMac's published pages. For smoothness, I give you measurable targets instead of guessing how TileMyMac does it.
- Feature parity is fine; do **not** copy ChainYourMac's wording, icons, screenshots or UI assets.

**Status legend:** ✅ present in your docs · 🟡 partial / unverified · ❌ not in your docs
**Priority:** P0 = fix now · P1 = needed for parity · P2 = advanced parity · P3 = polish and automation

---

## 1. Top 12 actions, in order

| # | Action | Fixes | Priority |
|---|---|---|---|
| 1 | Sign with a stable **Developer ID** identity, fixed bundle ID, hardened runtime, notarize. Never ad-hoc sign. | Issue 4 | P0 |
| 2 | Request Accessibility **once**, from a user click. Afterwards only check silently with `AXIsProcessTrusted()`. | Issue 4 | P0 |
| 3 | Stop moving **every** window on every frame. Update only windows near the viewport; park the rest once. | Issues 1, 3 | P0 |
| 4 | Move all AX calls off the main thread, one serial queue per app, latest-wins coalescing, short AX timeouts. | Issues 1, 3 | P0 |
| 5 | Replace the fixed-duration cubic ease-out with a **retargetable critically-damped spring** driven by a display link. | Issue 1 | P0 |
| 6 | Make the scroll event tap fast and self-recovering; latch each gesture's owner once (no half-consumed gestures). | Issues 1, 3 | P0 |
| 7 | Rebuild window discovery: a better eligibility rule, retries, per-window observers, periodic and event-driven reconcile sweeps. | Issue 2 | P0 |
| 8 | Change default shortcuts from `⌥+letter` to `⌃⌥+key`. | Parity, typing bugs | P0 |
| 9 | Add layout persistence and "new window opens beside focused, no focus stealing". | Parity | P1 |
| 10 | Add 3/4-finger swipe as the primary gesture. Gate or retire global two-finger hijacking. | Parity, side effects | P1 |
| 11 | Add Mac Setup (settings checker) and guided first run. | Parity, support load | P1 |
| 12 | Add stacks, tabbed columns, drag-reorder, per-app rules, per-Space strips, focus-follows-mouse. | Parity | P2 |

---

## 2. Fixes for your 4 issues

### 2.1 Issue 4 — "It keeps asking for Accessibility permission again and again"

Do this one first. Everything else is hard to test while permission keeps resetting.

**Evidence in your docs:** `PERMISSIONS.md` says macOS "may retain a stale code-signature hash after a rebuild" and tells users to remove and re-add Iume, and to run `./scripts/build.sh`. That strongly suggests ad-hoc or inconsistently signed builds. ChainYourMac's setup page confirms the permission is tied to the app's identity *and location*: it says to run from `/Applications`, and even it needs "remove and re-add" after an app is moved or replaced.

**Likely root causes (ranked)**

| # | Cause | Confidence |
|---|---|---|
| A | App is **ad-hoc signed** (`codesign -s -`) or signed with a different identity each build, so macOS treats each build as a new app and drops the grant. | High |
| B | Code calls `AXIsProcessTrustedWithOptions` with the **prompt option on every launch** or inside a polling timer. | High |
| C | The app runs from **DerivedData, a build folder, Downloads, or a translocated path** (`/private/var/folders/.../AppTranslocation/...`). | Medium |
| D | **Several copies** with the same bundle ID exist (debug build, release build, a copy in `/Applications`). | Medium |
| E | Iume is launched as a **bare executable** from Terminal/Xcode, so the grant attaches to the wrong process. | Medium |
| F | An embedded helper process has a different identity from the main app, so it needs its own grant. | Low (only if you have a helper) |

**Confirm (run on the build users actually get)**

```bash
codesign -dvvv --requirements - /Applications/Iume.app 2>&1 | egrep "Identifier|Signature|Authority|TeamIdentifier|designated"
#  "Signature=adhoc"  or  "TeamIdentifier=not set"  => cause A. This is the bug.

spctl -a -vvv -t install /Applications/Iume.app     # should say: accepted, source=Notarized Developer ID
mdfind "kMDItemCFBundleIdentifier == 'com.yourco.iume'"   # more than one path => cause D

# Watch macOS make the decision live while you launch the app:
log stream --predicate 'subsystem == "com.apple.TCC"' --info
```

**Fix 1 — Stable signing and notarization (the real fix)**

1. Enrol in the Apple Developer Program and create a **Developer ID Application** certificate.
2. Fix the bundle identifier forever (example `com.yourco.iume`). Use a *different* ID for debug builds (`com.yourco.iume.dev`) so dev and release never share a grant.
3. Do **not** use the App Sandbox (a sandboxed app cannot control other apps' windows). Keep Hardened Runtime on.
4. Replace `scripts/build.sh` signing with:

```bash
set -euo pipefail
APP="build/Iume.app"
IDENTITY="Developer ID Application: YOUR NAME (TEAMID)"

codesign --force --deep --options runtime --timestamp \
  --entitlements Iume.entitlements --sign "$IDENTITY" "$APP"

ditto -c -k --keepParent "$APP" Iume.zip
xcrun notarytool submit Iume.zip --keychain-profile "iume-notary" --wait
xcrun stapler staple "$APP"

codesign -dr - "$APP"        # designated requirement must reference your Team ID, not a cdhash
spctl -a -vvv -t install "$APP"
```

5. For daily development without a paid account, create a **self-signed code-signing certificate** in Keychain Access ("Iume Dev"), and sign every dev build with it. Never `-s -`. A stable certificate keeps the grant across rebuilds.
6. Clean up stale entries during development: `tccutil reset Accessibility com.yourco.iume.dev`.

**Fix 2 — Ask exactly once, then stay silent**

```swift
import ApplicationServices
import AppKit

enum AXPermission {
    /// Silent check. Safe to call anywhere, any number of times.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Call ONLY from a user click (onboarding button / menu item).
    static func requestFromUserClick() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "didShowAXPrompt") {
            openSettingsPane()                       // never re-prompt; just take them there
        } else {
            defaults.set(true, forKey: "didShowAXPrompt")
            // Use the literal key. The global kAXTrustedCheckOptionPrompt trips Swift 6 concurrency checks.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    }

    static func openSettingsPane() {
        NSWorkspace.shared.open(URL(string:
          "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

// React to the toggle instead of polling with prompts:
DistributedNotificationCenter.default().addObserver(
    forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { _ in
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        AXPermission.isTrusted ? engine.start() : engine.stopGracefully()
    }
}
```

Rules to enforce in code review:
- **Never** call `AXIsProcessTrustedWithOptions` with the prompt on launch, in `applicationDidBecomeActive`, or in a timer.
- If trusted state flips to false at runtime, **stop the engine, show the menu bar warning, do not prompt**.
- If the system says "trusted" but AX calls still return `.apiDisabled`, show a **Restart Engine** button that relaunches Iume. ChainYourMac does the same.

**Fix 3 — Make the install location predictable**
- Ship a `.dmg` with an Applications shortcut.
- On launch, if the bundle path is not `/Applications` or `~/Applications`, or contains `AppTranslocation`, show "Move Iume to Applications" and offer to do it (use `NSWorkspace`/`FileManager`, then relaunch). Do not ask for Accessibility until this is resolved.
- Sparkle (section 7.9) updates in place, which preserves the signature and the grant.

**Fix 4 — Rule out look-alike prompts**
Users call any macOS prompt "the permission again". Since Sequoia, macOS re-asks for **Screen Recording** roughly monthly. Make sure Iume never triggers it: do not call `CGWindowListCreateImage`, ScreenCaptureKit, or read `kCGWindowName` from `CGWindowListCopyWindowInfo`. Reading window numbers, owner PIDs, bounds and layer is fine. Also keep the scroll tap an *active* tap (`.defaultTap`); a `.listenOnly` tap needs Input Monitoring, which is a second prompt.

**Done when:** 20 consecutive release builds installed over each other, plus a reboot and a Sparkle update, never re-prompt.

---

### 2.2 Issues 1 and 3 — "Scroll is not smooth" and "very laggy"

These are one problem: too much synchronous Accessibility work per frame, scheduled badly.

**Evidence in your docs**
- `ARCHITECTURE.md` §3: "At each step, **all managed windows** are translated accordingly." Every frame, N windows × one cross-process call each.
- `ARCHITECTURE.md` §5.5 claims an "80% reduction" and "zero dropped frames at 120 Hz". Skipping `setSize` helps, but `setPosition` is still a **synchronous IPC round trip into each target app**. The cost depends on the *slowest app*, not on your code. The claim is not realistic, so remove it (see §9).
- "Cubic ease-out interpolation" is fixed-duration. It cannot carry finger velocity into the animation and cannot be retargeted smoothly, so it feels mechanical when you press keys fast or swipe then release.
- The scroll controller consumes events in a tap, runs its own "rolling velocity" physics, **and** macOS is also sending momentum events. That risks double physics.
- Nothing says AX work is off the main thread. If the event tap lives on the main run loop and a slow app blocks it, macOS disables the tap (`tapDisabledByTimeout`) and scrolling dies or stutters.

**Likely root causes (ranked)**

| # | Cause | Confidence |
|---|---|---|
| 1 | Per-frame AX writes to all windows, including off-screen ones | High |
| 2 | AX writes on the main thread or one shared serial queue, so one slow app (Chrome, Electron, Slack, VS Code) stalls everything | High |
| 3 | Frame pacing from `Timer`/`DispatchQueue` rather than a display link; no real timestamps | Medium |
| 4 | Event tap too slow or on the main thread; tap gets disabled and never re-enabled | Medium |
| 5 | Gesture handled inconsistently across `began`/`changed`/`ended`/momentum phases (some consumed, some passed through) | Medium |
| 6 | Apps with `AXEnhancedUserInterface = true` animate or delay programmatic moves | Low to Medium |
| 7 | Sub-pixel positions written every frame (extra IPC, no visual gain) | Medium |

**Confirm (Instruments, 10 minutes)**
1. Add `os_signpost` around each AX write, tagged with the bundle ID.
2. Record Instruments → *Points of Interest* + *Time Profiler* while scrolling across 6 mixed windows (Safari, Terminal, VS Code, Slack, Finder, Notes).
3. Look for: main-thread time per frame (target < 2 ms), AX write latency p95 per app, count of AX writes per frame (target ≈ number of *visible* windows, not all windows), and any `tapDisabledByTimeout` log line.

**Fix 1 — Only touch windows that matter**

```swift
// Partition per frame
let viewport = offset ..< offset + visibleWidth
let live   = columns.filter { $0.stripRange.overlaps(viewport.expanded(by: visibleWidth * 0.5)) }
let parked = columns.filter { !live.contains($0) }

// live windows: position updates every frame (only if the rounded origin changed)
// parked windows: moved ONCE to a parking origin when they leave the live range; never touched per frame
// jumps (focus 5 columns away): animate only windows visible at start or end; teleport the rest to final spots
```

- Round positions to device pixels and skip writes when the origin did not change.
- Never write size during scroll (you already do this). Do one authoritative **settle pass** at the end of the animation: set position and size, read back, correct drift.

**Fix 2 — AX I/O off the main thread, isolated per app, latest-wins**

```swift
final class AppAXContext {                       // one per PID
    let app: AXUIElement
    let queue: DispatchQueue                     // serial, QoS .userInteractive
    init(pid: pid_t) {
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2) // default is long; a hung app must not stall the frame
        queue = DispatchQueue(label: "ax.\(pid)", qos: .userInteractive)
    }
}

final class WindowWriter {
    private let ctx: AppAXContext, ax: AXUIElement
    private var latest: CGPoint?; private var draining = false
    private let lock = NSLock()

    func setPosition(_ p: CGPoint) {             // called from the display-link tick; returns instantly
        lock.lock(); latest = p
        let shouldStart = !draining; draining = true
        lock.unlock()
        guard shouldStart else { return }
        ctx.queue.async { [self] in
            while true {
                lock.lock()
                guard let next = latest else { draining = false; lock.unlock(); return }
                latest = nil; lock.unlock()
                var pt = next
                if let v = AXValueCreate(.cgPoint, &pt) {
                    AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, v)
                }
            }
        }
    }
}
```

- The tick **never waits** for AX. If an app is slow, it simply skips intermediate positions (latest wins) while other apps stay smooth.
- **Adaptive throttle:** track a rolling p95 of AX write latency per bundle ID. If p95 > ~8 ms, mark the app "slow" and update it every 2nd or 3rd frame; if > ~25 ms, update it only at the start and the settle pass. Log this to Diagnostics so you can see which apps are the problem.
- If an app has `AXEnhancedUserInterface == true`, temporarily set it to `false` for the duration of a scroll animation and restore it afterwards (Rectangle does this for the same reason).

**Fix 3 — Display-link animation with a spring**

Use a vsync-locked display link (macOS 14+: `NSScreen.displayLink(target:selector:)` / `CADisplayLink`; macOS 13: `CVDisplayLink`) and `link.targetTimestamp`, not wall-clock timers. Run only while animating; stop when settled (zero idle CPU).

```swift
/// Critically damped spring: no overshoot, retargetable, velocity-continuous.
struct Spring {
    private(set) var target: CGFloat
    private var x0: CGFloat = 0, v0: CGFloat = 0, t0: CFTimeInterval = 0
    let omega: CGFloat = 18                        // ~0.35 s settle; expose as "Animation speed"

    init(at value: CGFloat) { target = value }

    func sample(_ now: CFTimeInterval) -> (pos: CGFloat, vel: CGFloat) {
        let t = CGFloat(now - t0), e = exp(-omega * t)
        let b = v0 + omega * x0
        return (target + (x0 + b * t) * e, (v0 - omega * b * t) * e)
    }
    mutating func retarget(to newTarget: CGFloat, now: CFTimeInterval, extraVelocity: CGFloat = 0) {
        let s = sample(now)
        target = newTarget; x0 = s.pos - newTarget; v0 = s.vel + extraVelocity; t0 = now
    }
    func isSettled(_ now: CFTimeInterval) -> Bool {
        let s = sample(now); return abs(s.pos - target) < 0.25 && abs(s.vel) < 2
    }
}
```

- Key press → `retarget(...)` **immediately** (same run-loop turn), so motion starts the instant the key is pressed. Holding a key (repeat) retargets smoothly instead of restarting.
- Swipe release → `retarget(to: nearestColumn, extraVelocity: releaseVelocity)` so the strip carries your finger's speed.
- Delete the separate "rolling velocity" and "130 ms settle timer". Use real gesture phases instead (Fix 4).
- Rubber band: `offset' = (1 - 1 / (overshoot * 0.55 / dimension + 1)) * dimension` is smoother than a linear clamp.

**Fix 4 — Event tap: fast, on its own thread, self-healing, latched per gesture**

```swift
// Dedicated thread + run loop. The callback does O(1) work and returns.
let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                            options: .defaultTap,          // active tap: needs Accessibility only
                            eventsOfInterest: mask, callback: tapCallback, userInfo: ctx)

func tapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ e: CGEvent,
                 _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        CGEvent.tapEnable(tap: gTap, enable: true)         // RE-ENABLE, and log it
        return Unmanaged.passUnretained(e)
    }
    let phase    = e.getIntegerValueField(.scrollWheelEventScrollPhase)    // began=1 changed=4 ended=8 cancelled=16 mayBegin=32
    let momentum = e.getIntegerValueField(.scrollWheelEventMomentumPhase)
    let dx = e.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
    let dy = e.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)

    // Decide the owner ONCE per gesture (first event with non-zero delta), then keep it
    // for began/changed/ended AND momentum. Mixing owners makes the app under the cursor jerk.
    if phase & (1 | 32) != 0 { gesture.owner = .undecided }
    if gesture.owner == .undecided && (dx != 0 || dy != 0) {
        gesture.owner = shouldOwnGesture(dx: dx, dy: dy, flags: e.flags, cursor: e.location) ? .strip : .app
    }
    guard gesture.owner == .strip else { return Unmanaged.passUnretained(e) }

    engine.pushScrollDelta(dx)                 // lock-free write of the latest target offset
    if phase & 8 != 0 { engine.endGesture() }  // finger lifted: spring to nearest column, carry velocity
    if momentum != 0 { /* swallow system momentum, the spring replaces it */ }
    return nil                                  // consume
}
```

- The tap only *records* the latest finger offset. The display-link tick reads it and moves windows. Never move windows inside the tap callback.
- Add a watchdog: if no tick was processed for >1 s while the tap should be live, recreate the tap.

**Fix 5 — Stop hijacking all two-finger horizontal scrolls**
Your doc consumes *every* horizontal-dominant two-finger event system-wide. That breaks horizontal scrolling in spreadsheets, timelines, wide code, Figma, maps, and the Safari/Chrome two-finger back/forward swipe. ChainYourMac avoids this by using **3 or 4 finger swipes** (section 7.4). Make two-finger scrolling optional and gated:
- Only when the pointer is over the wallpaper, a gap between columns, or a column's title bar, **or** while a chosen modifier is held.
- Off by default.

**Performance budget (put these in CI or a manual checklist)**

| Metric | Target |
|---|---|
| Main-thread work per frame | < 2 ms |
| AX writes per frame | ≈ number of visible windows, not all windows |
| AX write p95 for native apps | ≤ 6 ms |
| Effective frame rate during scroll (visible windows, cooperative apps) | ≥ 55 fps on 60 Hz |
| Idle CPU (no animation) | ~0 % (no timers running) |
| `tapDisabled` events in a 30 min stress test | 0 |

Cooperative-app caveat: Chrome and Electron apps can be inherently slower to accept moves. The adaptive throttle keeps them from dragging everything else down, but expect them to look slightly less smooth than Safari or Terminal.

---

### 2.3 Issue 2 — "Certain apps and windows are left behind in the background or not taken into the strip"

This covers two symptoms: **(a)** windows never adopted, and **(b)** windows adopted but stranded, clamped or hidden. Check both.

**Evidence in your docs**
- `FEASIBILITY_REPORT.md` filters to `kAXWindowSubrole == kAXStandardWindowSubrole`, and `ApplicationDiscovery` finds "eligible running GUI applications via `NSWorkspace`". Both are too strict for real-world apps.
- Discovery is event-driven from `didLaunchApplication` and `kAXWindowCreatedNotification`. A freshly launched app often isn't AX-ready yet, so the first query fails and you never retry.
- The doc claims windows on inactive Spaces are found via `CGWindowList`. In practice, `kAXWindowsAttribute` is widely reported to return only windows on the **current** Space, and `CGWindowList` can't give you AX elements.
- `FEASIBILITY_REPORT.md` says moving windows to `x = -2000` or `x = 4500` is fully supported. Several macOS window managers report that macOS won't let a window go **entirely** off-screen and pulls it back, so they leave ≥1 px visible. ChainYourMac's setup page also says that with side-by-side displays a window "can only slide halfway off" toward the other display. Verify this on your target macOS versions; if true, it explains windows "left behind".

**Likely root causes (ranked)**

| # | Cause | Symptom | Confidence |
|---|---|---|---|
| 1 | Subrole filter drops real windows (apps reporting `AXDialog`, `AXFloatingWindow`, empty or unknown subrole: some Electron/Java/Qt apps, terminals, DAWs) | Never tiled | High |
| 2 | No retry for apps that aren't AX-ready at launch, or whose first window is created before the observer is attached | Never tiled | High |
| 3 | `kAXUIElementDestroyedNotification` registered on the app, not on each window | Ghost columns; stale registry | Medium |
| 4 | No reconcile sweep; missed notifications are never recovered | Window permanently orphaned | High |
| 5 | Windows on other Spaces, minimized/hidden windows, accessory-policy apps ignored | Missing after Space switch, wake, unhide | Medium |
| 6 | Off-screen windows clamped back by macOS, or leaking onto a neighbouring display | Window on top of / behind the wrong thing | Medium (verify) |
| 7 | Windows with a minimum width wider than their column overlap the next column | Overlap or "hides behind" | Medium |
| 8 | Floating/unmanaged windows have no z-order policy, so tiled windows cover them | "Left behind background" | Medium |

**Confirm**
- Add a debug command "Dump all windows" that prints, for every running app: policy, each AX window's role, subrole, `AXMinimized`, `AXFullScreen`, size settable?, and **why** it was classified tile/float/ignore. Anything you can see on screen but the dump classifies as *ignore* is a bug in the rules.
- Park test: write `x = display.maxX + 5000` to a Safari window, then read the position back. If it comes back different, macOS clamps, and cause 6 is real.

**Fix 1 — A real eligibility rule (replace the single-subrole check)**

Classify every AX window into `tile`, `float` (kept visible, not in the strip) or `ignore`:

| Condition | Result |
|---|---|
| App is Iume itself, or window is Iume's overlay/minimap/border | ignore |
| `AXRole != AXWindow` (menus, popovers, sheets, tooltips) | ignore |
| `AXMinimized == true` | ignore now, adopt on de-minimize |
| `AXFullScreen == true` (native full-screen) | ignore, and re-adopt when it returns |
| Subrole `AXStandardWindow` and size/position settable | **tile** |
| Subrole `AXDialog`, `AXFloatingWindow`, `AXSystemDialog` | **float** (keep on top of strip, centre on the focused column) |
| Subrole empty/unknown **and** has a close, minimize or zoom button **and** size is settable | **tile** |
| Size not settable, or no resize ability (probe: min == max) | **float** (smart floating, section 7.8) |
| Matches a per-app rule | rule wins |
| Anything else | float, and log why |

App-level: manage `.regular` apps. For `.accessory` apps (menu-bar apps that sometimes have real windows), observe `NSRunningApplication.activationPolicy` changes via KVO and apply the same window rules. Do not just exclude them.

**Fix 2 — Discovery that cannot miss windows**

```text
On app launch: attach AXObserver, then query windows at t = 0, 0.15, 0.5, 1.5, 4 s (stop early once stable).
AXObserver per app, on a dedicated run-loop thread. Register:
  app element:    kAXWindowCreated, kAXFocusedWindowChanged, kAXMainWindowChanged, kAXApplicationActivated/Deactivated
  EACH window:    kAXUIElementDestroyed, kAXWindowMiniaturized, kAXWindowDeminiaturized,
                  kAXWindowMoved, kAXWindowResized, kAXTitleChanged
When a window is created: re-check classification after ~100 ms (subrole is often not set yet).
When an unknown window becomes focused: adopt it immediately.
```

**Fix 3 — Self-healing reconcile sweep.** Diff "AX windows right now" against the registry (add missing, remove dead) on:
- app activation, app unhide, window de-minimize
- `NSWorkspace.activeSpaceDidChangeNotification`
- `NSApplication.didChangeScreenParametersNotification`
- `NSWorkspace.didWakeNotification`
- a low-priority timer every ~2 s while the strip is idle
- a **"Rescan windows"** menu item and optional shortcut

Dedupe windows by `CFEqual` on the `AXUIElement`. Optionally use the widely-used private `_AXUIElementGetWindow` to get a `CGWindowID` as a stable key for the window's lifetime, and keep it behind a protocol so you can swap it out.

**Fix 4 — Parking policy for off-viewport windows**
- Keep ≥1 px of every managed window inside its own display (verify with the park test). If every corner of the display overlaps another display, pick the least-bad corner and log a warning.
- With vertically arranged displays, parking left/right is clean. With side-by-side displays, **choose a parking corner whose rectangle does not intersect any other display's frame**, and at rest never leave a column straddling an edge that faces a neighbouring display (snap flush). In Mac Setup, recommend vertical arrangement (as ChainYourMac does).
- Write the park position once, not per frame.

**Fix 5 — No overlap, ever.** In `LayoutEngine`, use the **effective width** = `max(requestedWidth, observedMinWidth)`. After each settle pass, read back the real size and re-pack following columns by the real width. If a window can't be made narrower than its minimum, shift the later columns right; never let columns overlap.

**Fix 6 — Floating windows stay reachable.** Floating windows (dialogs, smart-floated windows, Iume's own settings) should be raised when their parent gains focus and never be left behind the strip.

**Done when:** across your test-app list (section 10), 100% of standard windows are adopted within 500 ms of creation, survive sleep/wake and Space switches, and "Dump all windows" shows zero visible-but-ignored windows.

---

## 3. Make it "do everything automatically"

Your item 6 means these must happen with **zero user action**. Use this as an acceptance checklist.

| Automatic behaviour | Mechanism |
|---|---|
| Start tiling at login | `SMAppService.mainApp.register()` plus "start engine on launch" |
| Adopt every new window | Sections 2.3 + 7.2 |
| Open new windows beside the focused one | Section 7.2 |
| Don't steal focus from background popups | Section 7.2 |
| Restore layout after restart / relaunch | Section 7.3 |
| Float things that can't tile | Section 7.8 |
| Handle monitor connect/disconnect, and put windows back on reconnect | Section 7.6 |
| Recover from engine or event tap death | Section 7.10 |
| Detect conflicting apps and wrong macOS settings | Section 7.5 |
| Update itself | Section 7.9 |
| Leave macOS native full-screen alone | Section 7.2 |
| Apply setting changes instantly (no Save, no restart) | Settings → live engine via Combine/observers |

---

## 4. Feature parity matrix (ChainYourMac vs Iume, from your docs)

| Feature (ChainYourMac) | Iume per docs | Action | Pri |
|---|---|---|---|
| Endless strip, nothing overlaps, new windows don't shrink others | ✅ model; 🟡 min-size overlap | Effective-width packing (§2.3 Fix 5) | P1 |
| New windows open beside the focused one | ❌ | §7.2 | P1 |
| Strip follows focus on a spring that starts on key press | 🟡 cubic ease-out | Spring + display link (§2.2) | P0 |
| Layout persists (order, widths, stacks); per display **and per Space** | ❌ (settings only) | §7.3 | P1 |
| Stacks (consume/expel, reorder, taller/shorter) | 🟡 `⌥J/K` navigation only | §7.7 | P2 |
| Tabbed columns + tab bar | ❌ | §7.7 | P2 |
| Preset widths 25/33/50/66/75, nudge, full, centre | 🟡 33/50/66/75/100 cycle, centre, full | §7.1 | P1 |
| Gaps (inner and outer, down to 0), Dock-aware | 🟡 gap, `visibleFrame` | §7.1 | P1 |
| One strip per display; send to next display; switch off per display; flush edges | 🟡 per-display strips | §7.6 | P1 |
| 3/4-finger swipe follows fingers, settles on nearest column | 🟡 2-finger scroll only | §7.4 | P1 |
| Strip minimap | ✅ | Verify non-activating panel | P3 |
| Focus border + dimming (both off by default) | 🟡 border only | Add dimming | P2 |
| Centre modes: never / on overflow / always | 🟡 centre command only | §7.1 | P1 |
| Drag to reorder | ❌ | §7.7 | P2 |
| Session restore, launch at login | 🟡 login item yes, restore no | §7.3 | P1 |
| No focus stealing | ❌ unknown | §7.2 | P0 |
| Smart floating (Calculator, own settings) | 🟡 min-size only | §7.8 | P1 |
| Per-app window rules (float, fixed slot, pick from list) | 🟡 exclusion list | §7.8 | P2 |
| Focus follows mouse / mouse follows focus (both off by default) | ❌ | §7.7 | P2 |
| Guided start + Mac Setup + conflict warnings | ❌ | §7.5 | P1 |
| Rebindable shortcuts, several bindings per action, non-US layouts | 🟡 "customizable" | §7.11 | P1 |
| Settings apply instantly | 🟡 | Live-apply | P1 |
| Native full-screen left alone | ✅ (feasibility doc) | Verify `AXFullScreen` + Space handling | P1 |
| Automation: URL scheme, CLI, Raycast commands | ❌ | §7.12 | P3 |
| Automatic updates (Sparkle) | ❌ (`PERMISSIONS.md` says "no network") | §7.9 | P3 |
| Self-healing engine + engine log | 🟡 Diagnostics | §7.10 | P3 |
| Notarized, Developer ID signed | ❌ likely ad-hoc | §2.1 | P0 |
| Accessibility only, no account, no telemetry | ✅ claimed | Verify (see §2.1 Fix 4) | P0 |

---

## 5. Architecture upgrades

1. **Three threads, three jobs.**
   - *Input thread:* event tap + multitouch callbacks. It only writes the latest target to a lock-free struct.
   - *Engine/main thread:* display-link tick reads that target, runs the pure `LayoutEngine`, and **enqueues** writes. It never waits on AX.
   - *Per-app AX queues:* all AX reads/writes and observer callbacks.
2. **Single source of truth.** `WorkspaceState` is an immutable value (displays → Spaces → strips → columns → windows). Every command is a pure function `(state, command) → state`. Rendering diffs old vs new frames. This makes stacks, tabs, persistence, undo and tests easy.
3. **Keep one process for now.** ChainYourMac runs a Rust engine as a separate background process. You don't need that to reach parity. If you split later, embed the helper inside the app bundle and **test Accessibility attribution first**: a helper with its own identity needs its own grant and can bring back Issue 4.
4. **Supervisor/watchdog** (§7.10).
5. **Pure `LayoutEngine` stays pure** and gets property tests: no overlaps, total width, gap invariants, snapping, centre modes, stack heights.
6. **Coordinate helper.** Centralise AppKit (bottom-left origin) ↔ AX (top-left origin, relative to the primary display) conversion in one function, with unit tests including displays arranged above/below/left of the primary. Mixed-up coordinates are a classic source of "windows come back shorter than the screen" bugs (ChainYourMac's own changelog mentions one for a display arranged below the main one).

---

## 6. Search your code for these (fast way to confirm the causes)

| Grep for | What it means |
|---|---|
| `AXIsProcessTrustedWithOptions`, `kAXTrustedCheckOptionPrompt` | Is the prompt flag set anywhere other than a user click? |
| `Timer.scheduledTimer`, `DispatchQueue.main.asyncAfter` near scroll/animation code | Frame pacing from timers |
| `for .* in .*windows` inside the animation step | Moving every window per frame |
| `setSize` / `kAXSizeAttribute` inside the scroll path | Size writes during scroll |
| `CGEvent.tapCreate`, `listenOnly`, `tapDisabled` | Wrong tap type; missing re-enable |
| `RunLoop.main` / `CFRunLoopGetMain` for the tap or `AXObserver` | Observers and taps on the main loop |
| `kAXStandardWindowSubrole` | The over-strict filter |
| `activateIgnoringOtherApps` | Deprecated since macOS 14; focus reliability |
| `codesign -s -` in `scripts/build.sh` | Ad-hoc signing |
| `CGWindowListCreateImage`, `kCGWindowName` | Possible Screen Recording prompt |

---

## 7. Detailed specs for features to add

### 7.1 Sizing, gaps, centre modes
- **Preset widths:** user-editable list, default `[25, 33, 50, 66, 75]` %. `⌃⌥R` cycles; `⌃⌥= / ⌃⌥-` nudge by a configurable step (default 5 %); `⌃⌥F` toggles full width and remembers the previous width; `⌃⌥C` centres.
- **Width semantics (niri-style):** a proportion `p` of the working area should tile exactly with gaps:
  `colWidth = p × (workWidth + gap) − gap`, where `workWidth = visibleFrame.width − 2 × outerGap`. Then two 50 % columns plus the gap fill the screen exactly.
- **Gaps:** inner gap, plus outer gaps (top/bottom/left/right), each 0 to N px; 0 is valid.
- **Dock/menu bar:** derive from `NSScreen.visibleFrame`, convert to AX coordinates (§5.6), and recompute when the Dock size/position/auto-hide changes (screen-parameter and Dock notifications).
- **Centre modes:** `never` (minimal scroll to bring the column fully into view), `onOverflow` (centre only when the strip is wider than the viewport), `always`. At the ends, clamp (with rubber band during gestures); with centre mode `never` and a short strip, left-align.
- **Scrolling rule on focus change:** move the minimum distance to bring the whole column into view; if the column is wider than the viewport, align its left edge.
- **User resizes a window by hand:** adopt that as the new column width (do not snap back). Detect by comparing the `kAXWindowResized` size with what you last wrote, within a short suppression window.

### 7.2 New-window placement, focus rules, native full-screen
- **Insert position:** immediately **right of the focused column** (configurable: left / end of strip).
- **Focus-stealing rule:**
  - If the new window's app is the frontmost app, or was activated by the user within ~1 s of launch (Dock/Spotlight click) → focus it and scroll to it.
  - Otherwise (a background app popped a window) → place it silently, **do not focus, do not scroll**.
- **Raising/focusing:** on user navigation use `kAXRaiseAction` + `kAXMainAttribute`/`kAXFocusedAttribute` + `NSRunningApplication.activate()`. `.activateIgnoringOtherApps` is deprecated on macOS 14+ and can be ignored (cooperative activation), so test focus reliability on macOS 14, 15 and 26 and add a fallback if needed.
- **Native full-screen:** when `AXFullScreen == true`, remove from the strip but remember the slot; re-insert at the same slot when it exits.
- **Window closed:** focus the neighbour (prefer right, else left); no layout jump.

### 7.3 Persistence and per-Space strips
- **File:** `~/Library/Application Support/Iume/layout.json`, schema-versioned, written atomically, debounced (~500 ms) and on quit/sleep.
- **Key everything by:** display UUID (`CGDisplayCreateUUIDFromDisplayID`) → Space identity → strip.
- **Per column:** width fraction, mode (`stacked`/`tabbed`), per-window height weights, active index, plus the focused column and scroll offset.
- **Per window slot:** `bundleID`, title hash, role, ordinal (nth window of that app), last size.
- **Restore algorithm:** when a window is adopted, match it to a saved slot by `(bundleID, title similarity, ordinal)`. Unmatched windows insert beside the focused column. Keep unmatched slots for a while (e.g. 10 min) in case the app is still starting.
- **Space identity:** there is no public API. Two options:
  - *A (what most tools do):* private SkyLight/CGS calls (`CGSGetActiveSpace`, `CGSCopyManagedDisplaySpaces`) behind a protocol, with a kill-switch.
  - *B (public-API fallback):* fingerprint the current Space by the set of on-screen window IDs from `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`. Less reliable.
  - Document that Mission Control must have **"Automatically rearrange Spaces based on most recent use" off**, otherwise Space order shuffles.

### 7.4 Trackpad gestures (the "follows your fingers" swipe)
- **Primary:** 3- or 4-finger horizontal swipe, user-selectable (default 4), tracking fingers 1:1 during the gesture, then spring to the nearest column on release with release velocity.
- **How:** ChainYourMac's setup page says macOS sends the swipe to the system *and* the app, and the app "can follow a swipe but can't stop macOS from acting on it". That matches **passive reading of raw multitouch data** (for example the private `MultitouchSupport.framework` via `dlopen`: contact-frame callbacks give finger count and positions; compute the centroid's horizontal delta). Treat it as a private, version-fragile API: isolate it behind a `GestureSource` protocol, feature-flag it, and test on each macOS release. I did not verify whether it triggers a permission prompt on macOS 26; test that early.
- **Consequence:** you can't swallow the system's own gesture, so you must tell users to free that swipe (Mac Setup, §7.5): *System Settings → Trackpad → More Gestures → Swipe between full-screen applications → Off* (or move it to the other finger count), *Swipe between pages → two fingers*, and Three-Finger Drag off if using 3 fingers.
- **Fallbacks:** keyboard always works; mice don't send multi-finger swipes; optional gated two-finger scroll (§2.2 Fix 5).
- **Feel:** deltas applied 1:1, rubber band past the ends, snap to nearest column on release, velocity projection for flicks, haptic-free.

### 7.5 Mac Setup + guided first run
**Mac Setup panel** (live checklist, each item turns green as fixed):

| Check | How to read it (verify keys with `defaults read` on your Mac) |
|---|---|
| Accessibility granted | `AXIsProcessTrusted()` |
| Running from `/Applications`, not translocated | Bundle path |
| Displays have separate Spaces: **On** | `com.apple.spaces` → `spans-displays` |
| Auto-rearrange Spaces by recent use: **Off** | `com.apple.dock` → `mru-spaces` |
| Stage Manager: **Off** | `com.apple.WindowManager` → `GloballyEnabled` |
| macOS 15+ tiling: drag-to-edge, drag-to-menu-bar, ⌥-drag tiling: **Off** | `com.apple.WindowManager` (`EnableTilingByEdgeDrag`, `EnableTopTilingByEdgeDrag`, `EnableTilingOptionAccelerator`) |
| Trackpad gesture conflict with the chosen finger count | `com.apple.AppleMultitouchTrackpad` and `com.apple.driver.AppleBluetoothMultitouch.trackpad` (3/4-finger horizontal swipe keys, `TrackpadThreeFingerDrag`); global `AppleEnableSwipeNavigateWithScrolls` |
| Conflicting window apps running | Rectangle, Magnet, Loop, BetterSnapTool, Moom, Amethyst, AeroSpace, yabai, Stage Manager-style tools (detect by bundle ID/process name; verify IDs) |

**Guided first run (4 steps):** (1) move to Applications, (2) grant Accessibility with the single user-click prompt, (3) Mac Setup, (4) an interactive "try the five shortcuts" step (focus left/right, move, cycle width, stack). End with the menu bar icon showing **Running**.

### 7.6 Multi-monitor
- One strip per display, own focus and scroll offset; identify displays by UUID.
- **Send to next display** (`⌃⌥N`): order displays by position and cycle.
- **Per-display enable/disable** (Configuration → Displays). Disabled display: Iume never touches windows there.
- **Disconnect:** migrate that strip's columns to another display; **remember origin** and restore them when the display returns (`didChangeScreenParametersNotification`, debounced).
- **Flush edges:** at rest, never leave a column straddling an edge that faces another display (§2.3 Fix 4). During animation, intermediate positions may overlap a neighbour; macOS can't clip.
- Verify mixed DPI, rotated portrait displays, displays arranged above/below/left of the primary, and Dock on any edge.

### 7.7 Stacks, tabs, drag-reorder, focus-follows-mouse, dimming
**Model:** `Column { id, width, mode: stacked|tabbed, windows: [WindowID], heightWeights, activeIndex }`.

- **Stacks:** commands: stack into left column `⌃⌥[`, into right `⌃⌥]`, pop out right `⌃⌥⇧]`, pop out left `⌃⌥⇧[`, reorder inside stack `⌃⌥⇧+J/K`, taller/shorter `⌃⌥⇧= / -`, equalize `⌃⌥0`. Heights are weights summing to the column height minus gaps; clamp to each window's minimum height.
- **Tabbed:** `⌃⌥⇧T` toggles stacked↔tabbed. All windows share the column frame (minus a tab-bar height); only the active one is raised, others are parked. Tab bar = a **non-activating** `NSPanel` (`.nonactivatingPanel`, `canBecomeKey = false`, joins all Spaces) so clicking it never steals focus.
- **Drag to reorder:** global mouse monitors; if mouse-down lands in a managed window's title-bar band, mark it as a user drag, **suppress the move notifications for that window**, show an insertion marker or stack-target highlight, and on mouse-up reorder/stack by cursor position, then animate. This requires macOS drag-to-edge tiling to be off (Mac Setup).
- **Focus follows mouse (off by default):** hover delay ~120 ms; ignore while dragging or scrolling; ignore floating panels. **Mouse follows focus (off by default):** warp the cursor to the focused window's centre on *keyboard* navigation only.
- **Dimming (off by default):** a click-through overlay panel per display with a cut-out for the focused window, or per-window dim panels. Never intercepts mouse events.
- **Focus border:** keep your overlay; ensure it is click-through, non-activating, and follows animation frames.

### 7.8 Smart floating and per-app rules
- **Smart float:** auto-float a window if its size attribute is not settable, it has no zoom/full-screen button and min == max (probe by trying ±1 px and reading back), it is a dialog/utility subrole, or it is Iume's own window. Calculator should float without any user rule.
- **Per-app rules** (picker lists running apps and `/Applications`, shows icons): `Tile` (default) · `Float` · `Ignore entirely` · `Fixed slot` (pin to first/last/nth column) · `Default width`. Optional title-regex per window.
- Store rules by bundle ID; apply live; show current rule in a "Windows" list with a Float/Unfloat toggle (`⌃⌥T`).

### 7.9 Automatic updates (and your "no network" wording)
- Add **Sparkle 2** with EdDSA-signed appcast; check on launch and daily; user-toggleable.
- Update `PERMISSIONS.md`: "No account, no telemetry. The only network request is the update check, which can be switched off." (Your current "No network" line would become false.)
- Updating in place keeps the signature, so Accessibility is preserved (verify, §2.1).

### 7.10 Self-healing and diagnostics
- **Watchdog:** engine writes a heartbeat each second. If the heartbeat stops, the tap is disabled, observers are dead, or AX errors (`cannotComplete`) spike, restart the engine components and log it. Menu bar shows **Running / Stopped / Needs permission**, with **Start**, **Restart Engine**, **Rescan Windows**.
- **Engine log** with a **Reveal Engine Log** item; Diagnostics export already exists, so extend it with per-app AX latency, tap-disabled counts, classification decisions, and persistence restore results.
- Keep everything local; nothing is sent anywhere.

### 7.11 Shortcuts: new defaults, rebinding, non-US layouts
**Change the defaults.** `⌥ + letter` has three problems:
1. It types characters (`˙` on US `⌥H`; `@` on German `⌥L`; `ç`, `®`, `å` elsewhere), so a global hotkey blocks typing them.
2. In macOS 15.0 to 15.1, Carbon `RegisterEventHotKey` with only ⌥ or ⌥⇧ modifiers was restricted (reported to affect sandboxed apps, and reportedly relaxed in 15.2 beta). Not worth depending on.
3. ChainYourMac made the same move for the same reason: new installs use `⌃⌥`.

**Proposed default set (`⌃⌥` + key, arrows as alternates):**

| Group | Bindings |
|---|---|
| Focus | `H J K L` and `← ↓ ↑ →`; first/last `⌘` + arrows; jump to window 1–9 `1…9` |
| Move | `⇧` + the same keys; send to next display `N`; stop/start engine `Q` |
| Size | cycle `R`; full `F`; centre `C`; wider/narrower `= / -`; taller/shorter `⇧= / ⇧-`; equalize `0` |
| Stacks | `]` `[` stack left/right; `⇧]` `⇧[` pop out; `⇧T` tabbed; `T` float |
| Utility | rescan windows; toggle minimap; open settings |

**Existing users:** keep their current bindings, add new ones only where keys are free, and offer a one-click "Switch to new defaults".

**Recorder and storage:**
- Store `keyCode + modifiers` per binding; allow **several bindings per action**.
- Display labels via the current keyboard layout (`TISCopyCurrentKeyboardLayoutInputSource` + `UCKeyTranslate`).
- Layout-dependent defaults (`[ ] = -`): resolve the *character* to a key code at install time and when the layout changes (AZERTY, QWERTZ, Dvorak).
- Conflict detection: registration failure (`eventHotKeyExistsErr`), duplicates inside Iume, and macOS symbolic hotkeys.
- Keep `RegisterEventHotKey` (no Input Monitoring needed).
- **Fix the doc contradictions** (§9): `⌥←/→` vs `⌃⌥←/→`; `⌥Return` as "zoom" vs "full width".

### 7.12 Automation
- `iume://focus/left`, `iume://width/cycle`, `iume://stack/left`, etc.
- A small CLI (`iumectl focus left`) talking to the app over a Unix socket or XPC; ship Raycast script commands that call it.
- Menu bar: Start/Stop, Open Iume, Open Configuration (shows raw settings file), Check for Updates.

---

## 8. Roadmap with acceptance criteria

| Phase | Scope | Acceptance |
|---|---|---|
| **P0 — Stabilise** (≈1–2 weeks) | §2.1 signing and permission; §2.2 live-window set, per-app AX queues, spring, tap fixes; §2.3 eligibility, retries, reconcile; new shortcut defaults | 20 rebuild/update cycles with no permission re-prompt · scroll budget met on 6 mixed apps · every test app's standard windows adopted · zero `tapDisabled` in 30 min |
| **P1 — Core parity** | Persistence, insertion and no focus stealing, widths/gaps/centre modes, 3/4-finger swipe, display hardening, Mac Setup + first run, rebindable shortcuts, live-apply settings | Relaunch restores layout · background popups never move the strip · swipe tracks 1:1 and snaps · Mac Setup turns green |
| **P2 — Advanced parity** | Stacks, tabbed columns, drag-reorder, per-app rules + smart float, per-Space strips, focus-follows-mouse, dimming | All commands in §7.7 and §7.8 work and persist |
| **P3 — Polish** | Sparkle, URL scheme + CLI, watchdog, docs and compat rewrite, website/demo | Killing the tap/engine recovers by itself · update flow keeps the grant |

---

## 9. Corrections to your existing docs

| File | Problem | Fix |
|---|---|---|
| `SHORTCUTS.md` | `⌥ + letter` defaults; says `⌥+←/→` scrolls the viewport | New `⌃⌥` set (§7.11); update the table |
| `ARCHITECTURE.md` vs `SHORTCUTS.md` | `⌃⌥←/→` = focus in one, `⌥←/→` = scroll in the other; `⌥Return` = full width in one, toggle zoom in the other; `⌥R/⌥C` missing from the shortcuts table | Pick one definition per action; "zoom" (AX zoom button) is *not* the same as "full column width" |
| `ARCHITECTURE.md` §3 | "All managed windows are translated accordingly" at each step | Replace with live-range + park model (§2.2) |
| `ARCHITECTURE.md` §5.5 | "80 % reduction", "zero dropped frames at 120 Hz" | Remove. Replace with the measured budget in §2.2 |
| `ARCHITECTURE.md` §5.1 | Consumes all horizontal two-finger scrolls system-wide; "130 ms settle" timer; own momentum physics | Gesture-owner latching, phase-based end, spring (§2.2); 3/4-finger primary (§7.4) |
| `ARCHITECTURE.md` §5.1 | Width cycle `33→50→66→75→100` | Default `25, 33, 50, 66, 75`; full width is a separate command |
| `FEASIBILITY_REPORT.md` | "Windows can be placed at `x = -2000` or `4500`" | Add the park test; document the ≥1 px rule if confirmed |
| `FEASIBILITY_REPORT.md` | Focusing with `.activateIgnoringOtherApps` | Deprecated in macOS 14; see §7.2 |
| `FEASIBILITY_REPORT.md` | Inactive-Space windows "detected via CGWindowList" | Rewrite: AX sees the current Space only (verify); see §7.3 |
| `PERMISSIONS.md` | "No Network" | "No telemetry; update check only" once Sparkle ships |
| `PERMISSIONS.md` | Remove/re-add is presented as normal | Keep as a last resort; the real fix is stable signing (§2.1) |
| `PERMISSIONS.md` | Says the native prompt appears on first launch | Say it appears when you click *Grant* in onboarding |
| `TROUBLESHOOTING.md` | "Look at the menu bar icon" only | Add Mac Setup, Rescan Windows, Restart Engine, Reveal Engine Log |
| `COMPATIBILITY.md` | Stops at macOS 15 | Add **macOS 26 (Tahoe)** and test it; check whether a newer macOS has shipped before you publish this table |
| `COMPATIBILITY.md` | Says macOS 14 is needed for `SMAppService` | `SMAppService` arrived in macOS 13; ChainYourMac supports macOS 13+ |
| `COMPATIBILITY.md` | Intel "Supported" | Decide deliberately. ChainYourMac is Apple silicon only, which shrinks the test matrix; Tahoe is the last macOS release to support Intel |

---

## 10. QA matrix

**Test apps (minimum):** Safari, Chrome, Firefox · Terminal, iTerm2 (and Ghostty/kitty/Alacritty if you care about them) · VS Code, Slack, Discord, Spotify (Electron) · Xcode · Finder, Preview, Notes, Mail · System Settings, Calculator (fixed-size) · IntelliJ/PyCharm (Java) · Zoom/Teams · Figma · Parallels/UTM windows · one menu-bar app that opens real windows.

**Scenarios:** launch with 10+ windows already open · launch app via Dock / Spotlight / background popup · close focused window · minimize/restore · hide/unhide app · native full-screen in and out · Space switch · sleep/wake · log out/in · plug/unplug a display · display arranged above/below/side-by-side · rotate a display · Dock auto-hide on/off · change gaps live · hold a key to repeat focus-move · fast swipe flicks · swipe with a slow app (Chrome with many tabs) · rebuild + reinstall 20 times and watch for permission prompts.

**Evidence to keep:** an Instruments trace per release (Points of Interest + Time Profiler), the "Dump all windows" output, and the per-app AX latency table from Diagnostics.

---

## 11. Quick-start implementation order

1. Read §2.1 and fix signing/permission code. Verify with the commands shown.
2. Add the debug "Dump all windows" command and per-app AX latency signposts (needed to prove every later fix).
3. Implement the live-range/park model and the per-app writer (§2.2 Fix 1–2).
4. Replace the animation with the spring + display link (§2.2 Fix 3).
5. Rework the event tap and gesture latching (§2.2 Fix 4–5).
6. Replace the eligibility rule and discovery (§2.3), then re-run the dump on the test apps.
7. Change shortcut defaults and migrate existing users (§7.11).
8. Then work through P1, P2, P3 from §8 in order, adding a test for each command in the pure `LayoutEngine`/state layer.

*Confidence note:* items marked "verify" depend on macOS behaviour I could not test here (window clamping off-screen, multitouch permission behaviour on macOS 26, exact `defaults` keys). Run the confirm steps before relying on them.
