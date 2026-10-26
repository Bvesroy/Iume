# Iume — Complete Feature, Issue & Capability Inventory

> **Consolidated from 10 source docs — single source of truth.**
> Sources: `ARCHITECTURE.md` · `COMPATIBILITY.md` · `FEASIBILITY_REPORT.md` · `FEATURE_MAP.md` · `IUME_FIX_PARITY_UPGRADE_INSTRUCTIONS.md` · `IUME_FIXES_AND_UPGRADES.md` · `MARKETING_FEATURES.md` · `PERMISSIONS.md` · `SHORTCUTS.md` · `TROUBLESHOOTING.md`
> Generated: 2026-10-24 · Version context: Iume 2.6.0

---

## Table of Contents

1. [System Overview & Design Blueprint](#1-system-overview--design-blueprint)
2. [Decoupled Modular Subsystems](#2-decoupled-modular-subsystems)
3. [Physical Window Positioning Model](#3-physical-window-positioning-model)
4. [Loop Prevention & Cycle Elimination](#4-loop-prevention--cycle-elimination)
5. [2-Finger Endless Scrolling Architecture](#5-2-finger-endless-scrolling-architecture)
6. [HUD & Visual Enhancements](#6-hud--visual-enhancements)
7. [Magnetic Edge Snapping & Zero-Gap Tiling](#7-magnetic-edge-snapping--zero-gap-tiling)
8. [Platform & Hardware Compatibility](#8-platform--hardware-compatibility)
9. [API Evaluation & Platform Capabilities](#9-api-evaluation--platform-capabilities)
10. [Window Type Classification & Management Policies](#10-window-type-classification--management-policies)
11. [Feature Inventory — Shipped / Partial / Not Started](#11-feature-inventory--shipped--partial--not-started)
12. [Keyboard Shortcuts & Navigation](#12-keyboard-shortcuts--navigation)
13. [Permissions & Security Model](#13-permissions--security-model)
14. [Troubleshooting & Diagnostics](#14-troubleshooting--diagnostics)
15. [Known Issues — Root Causes & Fixes (11 Source-Verified)](#15-known-issues--root-causes--fixes-11-source-verified)
16. [Parity Matrix — Iume vs. Established Window Managers](#16-parity-matrix--iume-vs-established-window-managers)
17. [Marketing — Hero Features, Claims & Proof Sheet](#17-marketing--hero-features-claims--proof-sheet)
18. [Roadmap & Implementation Order](#18-roadmap--implementation-order)
19. [QA Matrix & Acceptance Criteria](#19-qa-matrix--acceptance-criteria)
20. [Documentation Corrections & Guardrails](#20-documentation-corrections--guardrails)
21. [Appendix — File Map, Glossary & Build](#21-appendix--file-map-glossary--build)

---

## 1. System Overview & Design Blueprint

**Iume** brings the continuous, scrolling horizontal workspace model of Linux **PaperWM** and **niri** to macOS. Rather than forcing windows into a cramped overlapping grid on a single fixed desktop, Iume organizes all application windows along an **infinite horizontal strip of columns**.

```
+----------------------------------------------------------------------------------------------------+
|                                    Infinite Horizontal Strip                                       |
|  +--------------+  +--------------------+  +----------------------+  +--------------------------+  |
|  |   Column 0   |  |      Column 1      |  |       Column 2       |  |         Column 3         |  |
|  |  (Terminal)  |  |    (VS Code)       |  |  (Safari / Browser)  |  |   (Notes / Slack)        |  |
|  +--------------+  +--------------------+  +----------------------+  +--------------------------+  |
|                             ^                                                                      |
|                +-------------------------+                                                         |
|                |  Visible Screen Camera  |                                                         |
|                |    (Viewport Offset)    |                                                         |
|                +-------------------------+                                                         |
+----------------------------------------------------------------------------------------------------+
```

**Three architectures evaluated — one adopted:**

| Option | How it works | Verdict |
|---|---|---|
| A — Virtual Offscreen Desktop / Fake Composite | Capture via ScreenCaptureKit / CGWindowListCreateImage, render onto custom canvas, redirect clicks | **Rejected** — high latency, GPU/battery drain, broken text selection, broken IME, video glitches, permanent Screen Recording permission |
| B — macOS Spaces Simulation | Create dozens of native Spaces, programmatically switch | **Rejected** — no public API to create/reorder/instantly scroll Spaces without slow Mission Control animation |
| C — **Physical Desktop Coordinate Translation (PaperWM Model)** | Ordered horizontal strip `Col 0, Col 1, ...` each with width + X-offset in strip space. Visible screen is a camera at `viewportOffset.x`. Window screen X = `DisplayVisibleOrigin.x + StripX_i - ViewportOffset.x`. Scroll/hotkey updates offset with smooth animation, repositioning physical windows; offscreen windows rest off-screen in desktop coordinates | **Adopted** — 100% Accessibility-compliant, zero-lag native input, crisp text, multi-monitor, zero idle battery drain |

---

## 2. Decoupled Modular Subsystems

Codebase partitioned into distinct layers in `IumeCore` for testability, safety, separation of concerns:

```
User (Keyboard/Trackpad) --> ShortcutManager --> FocusManager, ScrollController
macOS WindowServer/AX --> ApplicationDiscovery, WindowDiscovery, WindowObserver, DisplayManager, SpaceManager
ApplicationDiscovery, WindowDiscovery, WindowObserver, DisplayManager, SpaceManager, FocusManager, ScrollController --> WorkspaceManager
WorkspaceManager --> LayoutEngine, WindowRegistry, WindowController, LayoutPersistenceManager
WindowController --> macOS (AX Position/Size/Focus)
LayoutPersistenceManager --> Disk (JSON)
```

| # | Subsystem | Responsibility |
|---|---|---|
| 1 | **`LayoutEngine`** | Pure deterministic calculation. Takes display geometry, column widths, window gap, viewport offset → exact `CGRect` target frames. Zero UI dependency; 100% unit-tested |
| 2 | **`WindowRegistry`** | In-memory thread-safe store tracking `ManagedWindow` metadata, indexed by `WindowId` + `AXUIElement` |
| 3 | **`ApplicationDiscovery` & `WindowDiscovery`** | Discover eligible GUI apps via `NSWorkspace`, query accessible top-level windows, filter transient overlays/sheets/drawers |
| 4 | **`WindowObserver`** | Subscribes to AX notifications (`kAXWindowCreatedNotification`, `kAXUIElementDestroyedNotification`, `kAXWindowMovedNotification`, etc.) with debouncing + feedback-loop suppression |
| 5 | **`WindowController`** | Executes physical repositioning (`kAXPositionAttribute`), sizing (`kAXSizeAttribute`), zooming, focusing. Per-PID async queues with latest-wins coalescing, 15–50 ms timeout, `AXEnhancedUserInterface = false` during scroll |
| 6 | **`ScrollController`** | Horizontal viewport animation with damped harmonic oscillator spring physics, synchronous frame-0 on keypress, `CADisplayLink` 80–120 Hz pacing |
| 7 | **`FocusManager`** | Directional navigation (`⌃⌥ H/L/J/K` + arrows), window activation, focus synchronization |
| 8 | **`DisplayManager`** | Monitors display geometry, resolution changes, multi-monitor hot-plugging; independent strip per display |
| 9 | **`SpaceManager`** | Tracks Mission Control virtual spaces per display; per-Space strips via `spaceWorkspaces` |
| 10 | **`LayoutPersistenceManager`** | Atomically serializes strip layout to `~/Library/Application Support/Iume/layout.json` (schema-versioned, debounced ~500 ms + on quit/sleep), restores column order/widths/stacks across restarts. Keys by display UUID + Space UUID (stable) |
| 11 | **`ShortcutManager`** | Carbon `RegisterEventHotKey` global dispatcher — system-wide, no Input Monitoring permission required. Now reads `ShortcutCatalog` for user-remappable bindings |
| 12 | **`SettingsStore` & `SettingsUI`** | Native SwiftUI config (8 panes), `UserDefaults` + JSON for bindings/rules, searchable sidebar, immediate apply (live engine via Combine) |
| 13 | **`Diagnostics`** | Local, privacy-first structured logging, per-app AX latency, `os_signpost` intervals, performance metrics |

**Three-thread model (target):** Input thread (event tap + multitouch, lock-free write of latest target) → Engine/main thread (display-link tick, pure `LayoutEngine`, enqueue writes, never waits on AX) → Per-app AX queues (all reads/writes + observer callbacks).

**Single source of truth (target):** `WorkspaceState` immutable value (displays → Spaces → strips → columns → windows). Every command is pure `(state, command) → state`; rendering diffs old vs new frames. Enables stacks, tabs, persistence, undo, tests.

---

## 3. Physical Window Positioning Model

Because macOS does not expose a programmable compositor to third parties, Iume uses **Physical Desktop Coordinate Translation**:

1. Each column *i* assigned strip coordinate:
   ```
   StripX_0 = 0
   StripX_i = StripX_{i-1} + Width_{i-1} + Gap
   ```

2. Physical screen position for window *w* in column *i*:
   ```
   ScreenX_w = VisibleFrame.origin.x + StripX_i - ViewportOffset
   ```

3. On scroll, `ScrollController` interpolates `ViewportOffset` → target; all managed windows translated accordingly; offscreen windows rest off-screen in desktop coordinates.

**Coordinate helper (required):** Centralise AppKit (bottom-left origin) ↔ AX (top-left, relative to primary display) conversion in one function, unit-tested for displays arranged above/below/left of primary. Mixed coordinates cause "windows come back shorter than screen" bugs.

**Strip geometry — one source (target fix):**

```swift
public struct StripGeometry: Sendable, Equatable {
    public let visibleFrame: CGRect
    public let margins: EdgeMargins
    public let gap: CGFloat
    public var originX: CGFloat { visibleFrame.minX + margins.left }
    public var usableWidth: CGFloat { max(200, visibleFrame.width - margins.left - margins.right) }
    public var usableHeight: CGFloat { max(200, visibleFrame.height - margins.top - margins.bottom) }
    public func width(forRatio p: CGFloat) -> CGFloat { floor((usableWidth + gap) * p - gap) }
    public func ratio(forWidth w: CGFloat) -> CGFloat { (w + gap) / (usableWidth + gap) }
    // niri formula: n columns of ratio 1/n exactly fill usableWidth
}
```

All layout, scroll, snap, presets, insertion, minimap, resize must use this — not scattered `visibleFrame.width` vs `usableWidth` derivations.

---

## 4. Loop Prevention & Cycle Elimination

**Classic window-manager feedback loop:**
1. Iume moves window A to `x = 200` → 2. macOS emits `kAXWindowMovedNotification` → 3. Unmitigated manager treats it as user drag → recalculates → 4. Another move → CPU spikes + jitter.

**Iume solutions (shipped):**
- `isPerformingProgrammaticUpdate` flag & `recordExpectedFrame`: expected frames registered so programmatic echoes distinguished from user drags.
- Live rate-limited edge reconciliation (~40–50 FPS): adjacent window adjusts in real time on edge resize without lag/overlap.
- Zero-overlap geometry & safe offscreen parking: windows past `maxVisibleX` parked deterministically offscreen in negative-X (`minVisibleX - colWidth - 200`), preventing WindowServer edge-clamping.
- Focused-strip slotting: new apps/windows slot at `effectiveFocusedIndex + 1` (beside active task), gliding into view.

**Required hardening (from FIX docs):**
- Replace global `isPerformingProgrammaticUpdate` with **per-window suppression tokens** (`observer.suppress(windowId:, until:)`) + 0.3 s expiry; never suppress the window currently being dragged by the user.
- Tighten `isSelfOriginatedFrameChange` to 2 pt (4 pt for size, terminal cell rounding).
- Latest-wins coalescing on per-PID queues; `recordExpectedFrame` once per gesture with final target + `gestureActive` flag per window, not every frame.
- `withAtomicScreenUpdates` (`CGSDisableUpdate`) removed from hot settle path — holding screen updates while waiting on synchronous AX is what causes whole-screen stutter.

---

## 5. 2-Finger Endless Scrolling Architecture

### 5.1 Gesture Interception Pipeline (shipped)

Trackpad gestures arrive as continuous `scrollWheel` events (`CGEventType.scrollWheel`). **Smart Horizontal Intent Detection:**

- `IsHorizontal = |dx| > |dy| && |dx| > 0.05`
  - Horizontal-dominant → `ScrollController` intercepts, consumes (`return nil`), glides strip.
  - Vertical-dominant (`|dy| >= |dx|`) → pass through (`return Unmanaged.passUnretained(event)`), browsers/editors scroll internally.

- Rolling velocity & momentum:
  ```
  Δt = max(0.005, t_current - t_previous)
  v_instant = Δx_effective / Δt
  v_rolling = 0.70 · v_rolling + 0.30 · v_instant
  ```

- Elastic edge rubber-banding past strip bounds (`x < 0` or `x > MaxOffset`):
  ```
  R = max(0.12, 1.0 - Overshoot/180)    // target: (1 - 1/(overshoot·0.55/dimension+1))·dimension
  ```
  On finger lift → cubic ease-out spring back.

- 130 ms settle & column snapping:
  ```
  TargetProjection = CurrentOffset + v_rolling · 0.18
  ```
  `LayoutEngine.findClosestColumnIndex` → spring to column + synchronous focus.

### 5.2 Performance Engine (shipped → needs hardening)

- **Zero-blocking 120 Hz ProMotion + async writers:** window writes during `isMoving == true` routed through per-PID background queues `com.iume.ax.<pid>`:
  - Latest-wins coalescing, 40–50 ms Mach timeout, `AXEnhancedUserInterface = false`, in-memory frame cache (skip if origin shift < 0.5 pt), park offscreen windows once.
- **Exponential smoothing for beat-frequency (sensor 90–125 Hz vs display 60/120 Hz):**
  ```
  factor = 1.0 - exp(-λ·Δt),  λ = max(20.0, 30.0 + (1.0 - smoothness)·70.0)
  CurrentOffset_t = CurrentOffset_{t-1} + (SmoothTargetOffset - CurrentOffset_{t-1}) · factor
  ```
- **C¹ velocity continuity:** `Position_0 = CurrentOffset, Velocity_0 = v_settle, Target = ColumnTarget` — no hitch on finger lift.
- **SPI / WindowServer IPC elimination:** `CGWindowID` cached in `WindowRegistry`, `NSScreen` cached per display ID, minimap/tab bar throttled.

### 5.3 Required Fix — One Motion Model (P0)

**Root cause:** Four competing models (1:1 tracking, custom coast `0.965`, exponential follow `λ = max(28, 35+(1-s)*80)`, spring snap, legacy `CriticallyDampedSpring`). Custom coasting runs *while* macOS momentum events arrive → double integrator. Snap runs twice (`onSwipeSettled` + `onSettleRequested`). Display link bound to `NSScreen.main` only. Successive writes mutate `@Published workspaces` at 120 Hz → SwiftUI re-renders, `CGSOrderWindow` per window per frame, minimap rebuild, `recordExpectedFrame` per window, synchronous 100 ms settle writes.

**Target model:**

| Phase | Behaviour |
|---|---|
| Finger down / scrolling (`phase` 1–2) | 1:1 tracking `offset += delta × sensitivity`; light smoothing from dial; rubber-band past ends (resistance 0.35, max 80 pt) |
| Finger up (`phase` 4) | Least-squares velocity over last 50 ms → `projected = offset + v·projectionTime` → snap column (or free position if snapping off) → one retargetable spring with current velocity |
| macOS momentum (`momentumPhase` 1–3) | **Consume and ignore** (return `nil` from tap); spring replaces it |
| New input during spring | Cancel spring, keep position + velocity, continue 1:1 |
| Mouse wheel (no phase) | Each notch adds to target; spring follows; snap 120 ms after last notch |
| 3/4-finger swipe | Same as trackpad: 1:1, lift → velocity projection → spring |

Rules: one `SpringState` (existing implicit-Euler, stable), delete `CriticallyDampedSpring` + friction coast + exponential branch; exactly one `onSettleRequested(projected, velocity)`; keep `GestureOwner` latching for whole gesture including momentum.

**Scroll interception fix:** Default `seamlessHorizontal` currently steals every horizontal 2-finger scroll (breaks Figma, spreadsheets, timelines, Safari back/forward swipe). New default: intercept only when `|dx| > 2.5|dy|` **and** (pointer over wallpaper/gap/titlebar/minimap **or** modifier held `⌥`/`⌃⌥` configurable). Keep `.modifierOnly` and `.always` options. Gate 2-finger globally; 3/4-finger becomes primary (see §7.4 speculative spec).

**Smoothness dial fix:** `scrollSmoothness` feeds 3 unrelated formulas → dial feels dead. Unify:

```swift
public struct MotionProfile: Sendable {
    public let trackingLambda: CGFloat
    public let springResponse: CGFloat
    public let springDamping: CGFloat
    public let projectionTime: CGFloat
    public let wheelSettleDelay: TimeInterval
    public static func from(smoothness s: Double, baseDuration: Double) -> MotionProfile {
        let s = CGFloat(min(max(s,0),1))
        return MotionProfile(
            trackingLambda: s < 0.05 ? .infinity : 90 - 70*s,
            springResponse: CGFloat(baseDuration)*(0.75+0.6*s),
            springDamping: 1.0 - 0.12*s,
            projectionTime: 0.10 + 0.12*s,
            wheelSettleDelay: 0.08 + 0.10*s)
    }
}
```

Cache via `settings.$scrollSmoothness` sink, not reading `SettingsStore.shared` in frame loop. Labels: 0 = Instant, 0.5 = Balanced, 1 = Silky. Replace SwiftUI `ScrollView` test track with `MotionProfile`-driven preview so dial effect is visible.

**Performance fixes:** Split hot `ViewportState` (offset/velocity/isMoving) from `@Published workspaces`; precompute `StripSnapshot` (displayId, geometry, columnX, placements) once per gesture; viewport-filter writes (only near viewport); delete `enforceStripZOrder` from frame loop; per-screen `CADisplayLink` from scrolled screen's `NSScreen` (not `main`); `os_signpost` budget < 2 ms/frame (p95 < 4 ms for 20 windows), WindowServer CPU < 40%, zero `tapDisabled`.

---

## 6. HUD & Visual Enhancements

| Component | Detail |
|---|---|
| **Floating Strip Minimap HUD** (`MinimapHUDController`) | Translucent glassmorphic capsule `NSPanel` `.floating` level, bottom-center. Miniature proportional column pills, active column highlight, gliding viewport frame. Fades in on scroll, out after 1.25 s. Needs 30 Hz throttle, `StripGeometry` widths, no SwiftUI `NSHostingView` re-alloc per frame |
| **Focus Border Overlay** (`FocusBorderOverlay`) | Click-through accent border framing active window, `NSAnimationContext` ease-out 0.22 s on focus shift. During scroll translate with `NSWindow.setFrameOrigin` (no re-render) |
| **Dimming Overlay** | Off by default. Must use Iume overlay windows with cut-out, **not** `CGSSetWindowAlpha` on foreign windows (requires SIP off — remove that usage). Per-display or per-window dim panels, click-through |
| **Shortcut Presets (HUD)** | `⌃⌥R`/`⌥R` cycle width (33→50→66→75→100% — target: 25/33/50/66/75 separate from full-width), `⌃⌥C`/`⌥C` center, `⌃⌥F`/`⌥Return` maximize (target: `⌃⌥F` only), `⌃⌥←/→`/`⌥H/L` directional focus, `⌃⌥G` toggle zero-gap |
| **Launch HUD** (`LaunchHUDController`) | Kickstart, Stop & Restore, width/gap presets, live window list, `🟢 ACTIVE`/`⚪ STOPPED` badge |
| **Smoothness Wheel UI** | `SmoothScrollWheelView` (`SettingsView.swift:956`) — 360° dial, gradient arc, response ms + damping ζ, VSYNC badge, 4 presets. Interactive trackpad test track (needs physics preview fix) |
| **Tab Bar Overlay** | 28 pt floating tab strip (`TabBarOverlayController` `NSPanel` `.nonactivatingPanel`), clickable icons/titles, dirty `•`, lock icon, notification count, drag-reorder, tear-off detach, drop preview, context menu, `[ Group Name ▾ ]` pill, `+` add tab, `x` close, double-click rename, `⌃⌥⇧P` pin |
| **Loop Seam Tick** | Quiet wooden tick on every completed lap in Loop Mode; toggle in Appearance → Sound Feedback |

**Transition animator (target):** `LayoutTransition` drives positions via `SpringState`/`MotionProfile` on display link; size changes batched (growth at start, shrink at end, ≤30 Hz for Electron/Chromium); respects `settings.enableTransitions` **and** `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.

---

## 7. Magnetic Edge Snapping & Zero-Gap Tiling

### Zero-Gap Strip (`appsEdgeTogether`)
- `gap = 0.0 pt`, tiling flush: `colScreenX_{i+1} = colScreenX_i + colWidth_i`
- Restores previous gap when toggled off. Toggle via menu bar `🧲 Apps Edge Together`, Launch HUD, Settings, `⌃⌥G`.

### Magnetic Snapping (`MagneticWindowEngine`)
- **Adjacent adhesion:** dragging one window moves companion in real time, no separation/gap.
- **Distance snap:** separated windows < 32 pt snap together.
- **Seam ratio snaps:** manual resize snaps to 25%/33.3%/50%/66.7%/75% within 18 pt radius.
- **Async AX + anti-flicker:** `setPositionAsync`/`setFrameAsync` on per-PID queues, latest-wins drain, expected frames 0.65 s, `activelyDraggingWindowId` lockout, 120 Hz spring settle on mouse-up.

### Required fixes (gap/geometry — P0)

- Gap/margin derivations differ in 4+ places (`visibleFrame.width` vs `usableWidth`, `windowGap` vs `appsEdgeTogether` vs `smartWindowMargins`). Mouse-up overwrites **every** column width from AX frames; `reflowColumnsForGeometryChange` resets widths; preset math ignores gap (`visibleWidth*ratio`); `computeLayout` skips empty columns but offset helpers don't; `presetWidthRatios` default mismatch (`1.0` in init not in `resetToDefaults`).
- **Fix:** `StripGeometry` everywhere; store widths as `widthRatio` + optional `minWidth`; presets via `width(forRatio:)` with `[0.25, 1/3, 0.5, 2/3, 0.75]` + separate full-width action; single `maxOffset = max(0, totalStripWidth(geometry) - usableWidth)`; filtered column list consistent; mouse-up commits only resized column+neighbour; first column `originX` at offset 0, last column `originX+usableWidth` at maxOffset; gap 0 truly 0 (apps rounding to character cells → set next column X from *actual* right edge).

### Overlap fixes (P0)

- **Sliver parking bug** (`LayoutEngine.swift:224-232`): left parked at `minVisibleX - colWidth + 12` overlaps left edge by 12 px; right parked at `maxVisibleX - 12` overlaps right edge; 35 px threshold jump. Tabs also parked at left sliver.
- **Fix:** per-display `safeParkSide` (side with no adjacent display, else bottom-right `x=maxX-1, y=maxY-1`); fully off-screen with 1 pt max sliver inside margin/gap; all parked share same spot; column at true strip X if any part intersects visible frame — parked only when completely outside; remove 35 pt rule. Respect real `AXMinSize` + read-back `minWidth` → re-layout. Remove `enforceStripZOrder` + duplicate `PureStripLayoutEngine`.


## 8. Platform & Hardware Compatibility

### macOS Version Matrix

| macOS Version | Architecture | Status | Notes |
| :--- | :--- | :--- | :--- |
| **macOS 15 (Sequoia)** | Apple Silicon (M1/M2/M3/M4) | **Tier 1 — Full Support** | Validated arm64, zero SIP requirements |
| **macOS 15 (Sequoia)** | Intel (x86_64) | **Supported** | Universal Binary / native x86_64 build |
| **macOS 14 (Sonoma)** | Apple Silicon & Intel | **Tier 1 — Full Support** | Minimum deployment target; full `SMAppService` + SwiftUI settings |
| **macOS 13 (Ventura) & earlier** | Any | **Unsupported** | Deprecated APIs; lacks Swift 6 Sendable + ServiceManagement |
| **macOS 26 (Tahoe)** | — | **Needs testing** | Intel last supported (still in compat table as "add and test") — FIX docs say `SMAppService` arrived in macOS 13 not 14, so table underreports |

> FIX-doc correction: `COMPATIBILITY.md` says macOS 14 needed for `SMAppService` — actually macOS 13. ChainYourMac supports 13+. `COMPATIBILITY.md` claims Intel "Supported" — ChainYourMac is Apple-silicon-only; Tahoe is last Intel macOS, so maintaining Intel doubles test matrix with diminishing return — decide deliberately.

### Hardware

- **Apple Silicon M1/M2/M3/M4**: native arm64, sub-ms focus, minimal CPU.
- **Multiple Displays**: mixed resolutions, retina/non-retina scaling, ProMotion 120 Hz, hot-plugging, mixed DPI, rotated portrait, displays arranged above/below/left of primary, Dock on any edge. Per-display independent strip; on disconnect migrate to primary, on reconnect restore origin strip.
- **Build assumption (MARKETING_FEATURES)**: shipped binary is `arm64` only, `LSMinimumSystemVersion 14.0`, `LSUIElement = true` (menu-bar only, no Dock icon), Swift 6 + Rust engine, bundle < 4 MB, 79 Swift tests (12 suites) + 30 Rust tests.

---

## 9. API Evaluation & Platform Capabilities

| Capability | macOS API | Permission | Feasibility |
| :--- | :--- | :--- | :--- |
| **Window Enumeration** | `AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute, ...)` | Accessibility (`AXIsProcessTrusted`) | ✅ Fully supported — all top-level UI windows |
| **Window Geometry Inspection** | `kAXPositionAttribute` + `kAXSizeAttribute` | Accessibility | ✅ CGPoint/CGSize in desktop coords (top-left origin) |
| **Window Repositioning** | `AXUIElementSetAttributeValue(window, kAXPositionAttribute, axValue)` | Accessibility | ✅ Can place beyond visible bounds (`-2000` / `4500`) — but FIX docs warn macOS may clamp windows entirely off-screen; leave ≥1 px visible and pick parking corner not intersecting another display |
| **Window Resizing** | `kAXSizeAttribute` | Accessibility | ✅ Subject to app-enforced min/max |
| **Window Focusing** | `kAXMainAttribute = true` + `NSRunningApplication.activate(options:)` | None extra | ✅ Reliably raises + transfers keyboard; `activateIgnoringOtherApps` deprecated since macOS 14 — test `kAXRaiseAction` + `_SLPSSetFrontProcessWithOptions` + conditional `activate()` |
| **Window Event Monitoring** | `AXObserverCreate` + `AXObserverAddNotification` on CFRunLoop | Accessibility | ✅ `kAXWindowCreatedNotification`, `kAXUIElementDestroyedNotification`, `kAXWindowMovedNotification`, `kAXWindowResizedNotification`, `kAXFocusedWindowChangedNotification` — must add run-loop source to `.commonModes` (not `.defaultMode` only), register per-window not just per-app |
| **App Lifecycle Tracking** | `NSWorkspace.didLaunchApplicationNotification` / `didTerminateApplicationNotification` | None | ✅ Combine / NotificationCenter |
| **Display Topology & Geometry** | `NSScreen.screens`, `visibleFrame` (Dock+menu aware), `didChangeScreenParametersNotification` | None | ✅ Real-time; cache `NSScreen` per display ID to avoid WindowServer queries during scroll |
| **Global Keyboard Shortcuts** | Carbon `RegisterEventHotKey` / `NSEvent.addGlobalMonitorForEvents` | None for `RegisterEventHotKey`; Accessibility/InputMonitoring for CGEventTap | ✅ `RegisterEventHotKey` = gold standard: zero lag, background, no Input Monitoring |
| **Horizontal Scrolling Input** | `CGEventTapCreate` or `NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel)` | Accessibility / Input Monitoring | ✅ For 2-finger horizontal gestures + mouse wheels — but active `.defaultTap` needs only Accessibility; `.listenOnly` would trigger Input Monitoring (avoid) |
| **Launch at Login** | `SMAppService.mainApp.register()` (macOS 13+) | None | ✅ Native, user-toggleable in System Settings; broken today: `SettingsView` only writes `UserDefaults`, `MacSetupChecker.setLaunchAtLogin` exists but nothing calls it — wire `SettingsStore.launchAtLogin.didSet` → `SMAppService` + handle `.requiresApproval` |

---

## 10. Window Type Classification & Management Policies

Not every window belongs in the strip — forcing utility dialogs into columns causes chaos.

| Category | Examples | Layout Action |
| :--- | :--- | :--- |
| **Standard Tiled Windows** | Safari, Xcode, Terminal, Notes, VS Code, Finder main windows | **Managed in columns** — positioned/moved/resized per layout mode |
| **Modal & System Dialogs** | File Open/Save, print sheets, permission alerts | **Floating (ignored by strip)** — floats above parent |
| **Popovers & Menus** | Autocomplete, contextual menus, tooltips | **Ignored** — filtered via `kAXWindowSubrole != kAXStandardWindowSubrole` |
| **Floating Utility Palettes** | Photoshop pickers, Xcode inspectors, 1Password mini | **Floating** — user-configurable via denylist / window role rules |
| **Native Full-Screen Apps** | Apps in macOS native full-screen space | **Excluded** while fullscreen; recovered on return to normal desktop |
| **Inaccessible / Custom Windows** | Java/Electron games, DRM windows lacking AX | **Safe fallback** — detected, logged, left untouched |

### Real Eligibility Rule (target — replaces single-subrole check)

| Condition | Result |
|---|---|
| App is Iume itself, or window is its overlay/minimap/border | ignore |
| `AXRole != AXWindow` (menus/popovers/sheets/tooltips) | ignore |
| `AXMinimized == true` | ignore now, adopt on de-minimize |
| `AXFullScreen == true` | ignore, re-adopt when it exits |
| Subrole `AXStandardWindow` + size/position settable | **tile** |
| Subrole `AXDialog`/`AXFloatingWindow`/`AXSystemDialog` | **float** (keep on top, centre on focused column) |
| Subrole empty/unknown + has close/minimize/zoom button + size settable | **tile** |
| Size not settable, or no resize (min==max) | **float** (smart floating) |
| Matches per-app rule | rule wins |
| Anything else | float + log why |

- App-level: manage `.regular` apps; for `.accessory` (menu-bar apps with real windows) observe `activationPolicy` via KVO and apply same rules — don't just exclude.
- **Discovery hardening:** on app launch query at t=0, 0.15, 0.5, 1.5, 4 s; per-app `AXObserver` on dedicated run-loop thread (`kAXWindowCreated`, `kAXFocusedWindowChanged`, `kAXMainWindowChanged`, `kAXApplicationActivated/Deactivated` on app; `kAXUIElementDestroyed`, `kAXWindowMiniaturized/Deminiaturized`, `kAXWindowMoved/Resized`, `kAXTitleChanged`, `kAXApplicationHidden/Shown` per window); on create re-check after ~100 ms (subrole not yet set).
- **Self-healing reconcile:** diff AX vs registry on app activation/unhide/de-minimize, `activeSpaceDidChange`, `didChangeScreenParameters`, `didWakeNotification`, idle every ~2–3 s, plus **Rescan Windows** menu/shortcut `⌃⌥Z`.
- **Parking:** keep ≥1 px inside own display at safe corner not intersecting neighbour display; parked once not per frame.

---

## 11. Feature Inventory — Shipped / Partial / Not Started

Status legend: **✅ shipped** · **🟡 partial / needs fix** · **⬜ not started** · **❌ missing/broken**

### 11.1 Tiling & Navigation — All Shipped

| Area | State | Notes |
|---|---|---|
| Scroll strip (PaperWM/niri style) | ✅ | Infinite strip, focus-driven viewport, spring settle |
| Focus Column / Centered Focus | ✅ | Minimal-scroll + always-centred camera modes (`never`/`onOverflow`/`always`) |
| Manual / free layout | ✅ | Windows keep dragged frame; no snap-back |
| Grid / Tall / Wide / BSP / Row / Column | ✅ | Adaptive grid `3+2`, `3+2+2`, `4+3+3` fills every row |
| Column stacks & tabbed columns | ✅ | Proportional stacks, tab bar overlay, stack/pop shortcuts |
| Gaps, margins, presets | ✅ | Per-screen margins, zero-gap mode, width presets, smart margins |
| Multi-display | ✅ | Independent strip per display, send-to-display, proportional width migration |

### 11.2 Resize, Snapping & Box Control — All Shipped

| Area | State | Notes |
|---|---|---|
| Neighbour-aware resize | ✅ | Edges push/pull adjacent boxes, clamped to min size + screen |
| Free edge/corner resize | ✅ | Cursor picks edge/nearest corner; axes stay locked |
| Keyboard box resize | ✅ | `⌃⌥=/−` + `⌃⌥⇧=/−` grow box from neighbours |
| Snap actions (halves/thirds/quarters/max/centre) | ✅ | Radial menu `⌃⌥B` + Custom Box Studio `⌃⌥⇧B` |
| Balance / equalise / swap with main | ✅ | `⌃⌥A`, `⌃⌥⇧↩` |
| Adaptive re-tile on open/close | ✅ | Stale boxes dropped per display+Space |
| Magnetic snapping & adhesion | ✅ | 32 pt attraction, seam ratio snaps, zero-flicker settle |

### 11.3 Window, Space & App Management — All Shipped

| Area | State | Notes |
|---|---|---|
| Virtual workspaces 1–9 | ✅ | Per display + Mission Control Space, switch/move shortcuts |
| Space throwing | ✅ | Factory chords `⌃⌥⇧⌘←/→` + `⌃⌥⇧⌘H/L`, moves window between Spaces |
| Persistence | ✅ | Atomic JSON restore of columns/widths/stacks/focus |
| Stop & restore | ✅ | Returns every window to pre-tiling frame (`initialFrame`) — on quit/SIGTERM/disable too |
| Native tab detection | ✅ | Safari/Finder/Ghostty tab swaps reuse column |
| App exclusions (float list) | ✅ | Settings → Application Rules |
| Per-app policies (`alwaysTile`/`alwaysFloat`/`fixedSlot`) | ✅ | Full editor in Settings → Application Rules, running-apps quick-select, live re-evaluation |
| Small-window auto-float | ✅ | Configurable width threshold (default 500 pt) |
| Focus follows mouse / mouse follows focus | ✅ | 120 ms hysteresis, anti-focus-steal guard |

### 11.4 Interaction & Performance — All Shipped

| Area | State | Notes |
|---|---|---|
| 120 Hz spring physics | ✅ | Analytical damped oscillator, `CADisplayLink` paced |
| Trackpad gestures | ✅ | 3/4-finger centroid panning, 2-finger modes, momentum handover |
| Loop seam tick (Loop Mode) | ✅ | Wooden tick per completed lap; toggle in Appearance → Sound Feedback |
| Modifier-drag move/resize | ✅ | `⌃⌥`-drag with live footprint preview |
| Off-screen parking | ✅ | SkyLight ordering + alpha, no WindowServer clamping |
| Rust physics core / C++ WindowServer bridge | ✅ | Spring solver, filtering, hit-testing, CGS window ordering (~3,000 lines, 30 Rust tests, zero hot-path alloc) |
| Titlebar drag-to-reorder | ✅ | Column midpoint hit-test on drop |
| Focus border, dimming, minimap HUD | ✅ | 3 HUD styles, dial, sound cues |

### 11.5 Shortcuts & Settings — All Shipped

| Area | State | Notes |
|---|---|---|
| **User-remappable shortcuts** | ✅ | Every action editable, live recorder, conflict detection, per-action reset, JSON persistence |
| **Shortcut cheatsheet** | ✅ | `⌃⌥/` floating list rendered from live binding table — cannot drift |
| Global Carbon hotkeys | ✅ | Background, no Input Monitoring |
| Legacy `⌥` shortcuts | ✅ | Optional additive layer, skipped when would collide |
| Settings window (8 panes) | ✅ | System Settings conventions, searchable sidebar, immediate apply |
| Menu bar + launch HUD | ✅ | Layout switcher, quick controls, status, stop/restore |
| Mac Setup checker & diagnostics | ✅ | Permissions, Spaces settings, conflicting managers, TCC repair |

> **P0 gap that was half-shipped and is now considered done:** per-app rules editor, space throwing defaults, cheatsheet overlay — all three struck through in `FEATURE_MAP.md` as shipped.

### 11.6 Gaps Worth Closing (FEATURE_MAP Roadmap — Ordered by Value ÷ Effort)

Each item is a vertical slice: model → engine → persistence → UI → shortcut → tests.

| Priority | Feature | Status | Detail |
|---|---|---|---|
| **P0** | Per-app rules editor | ~~⬜~~ ✅ | Shipped |
| **P0** | Space throwing defaults | ~~⬜~~ ✅ | Shipped |
| **P0** | Cheatsheet overlay | ~~⬜~~ ✅ | Shipped |
| **P1** | Frame undo / history | ⬜ | Small undo stack per window; `⌃⌥⌫` restores previous size (Rectangle/Loop parity) |
| **P1** | Named layouts | ⬜ | Save current strip as named profile, restore later; builds on `LayoutPersistenceManager` |
| **P1** | Scratchpad / sticky window | ⬜ | One hidden slot per display, toggled with chord; floats above strip |
| **P2** | Per-workspace layout mode | ⬜ | `layoutMode` global today → scope to `WorkspaceKey`, fall back to global default |
| **P2** | Named workspaces + workspace bar | ⬜ | Labels instead of 1…9, visible in menu bar + minimap |
| **P2** | Per-display gaps/margins | ⬜ | One `EdgeMargins` for all screens today |
| **P3** | Config file / export-import | ⬜ | TOML/JSON for bindings/rules/gaps/layouts; CLI `iume apply-profile` for dotfiles |
| **P3** | URL scheme / Shortcuts.app actions | ⬜ | `iume://layout/grid`, expose to Apple Shortcuts |
| **P3** | Gesture tuning | ⬜ | Finger count, direction inversion, per-device sensitivity |
| **P4** | Window switcher palette | ⬜ | Searchable titles instead of blind cycling |
| **P4** | Menu bar per-app pause | ⬜ | Suspend tiling for one app without editing exclusion list |
| **P4** | VoiceOver labels + keyboard-only settings navigation | ⬜ | Accessibility polish |

### 11.7 Full Marketing Feature Inventory (from MARKETING_FEATURES — All Shipped Unless Noted)

**Layout & Tiling:** continuous strip · 4 layout modes (Scroll Strip / Focus Column / Centered Focus / Manual) · Apps Edge Together · inner gap (0/4/8/12/16 pt + slider) · independent outer margins · smart margins (0 when single column) · built-in display exemption · default 50% + presets 25/33/50/60/66/75/100% · half-screen elongated sizing · centre modes · `⌃⌥F` full-width · manual mode · per-column custom widths.

**Navigation & Input:** directional focus `⌃⌥←/→/↑/↓` + `⌃⌥H/J/K/L` · move columns `⌃⌥⇧←/→` · window cycling `⌃⌥Tab`/`⌃⌥⇧Tab` · first/last `⌃⌥⌘←/→` · viewport scroll keys · 2-finger modes (Seamless/Option-gated/Control-gated/Always) · 3/4-finger swipes · momentum coasting · sensitivity · natural direction · gesture latching · drag titlebar reorder · focus-follows-mouse · mouse-follows-focus · legacy `⌥` set · international keymap (`UCKeyTranslate`).

**Column & Window Management:** width cycling `⌃⌥R`/`⌃⌥⇧R` · nudging `⌃⌥-/=` ±5% · centre `⌃⌥C` · pull/stack `⌃⌥[`/`⌃⌥]` · pop `⌃⌥⇧[`/`⌃⌥⇧]` · stacked↔tabbed `⌃⌥⇧T` · stack height `⌃⌥⇧=/−` · equalize `⌃⌥0` · 28 pt tab bar overlay · live edge resizing · magnetic seam snapping (18 pt) · zoom/close `⌃⌥Return`/`⌃⌥W` · smart floating · small-window threshold · manual float `⌃⌥T` · per-app rules · excluded apps.

**Displays & Spaces:** per-display strips · per-Space strips · 9 virtual workspaces `⌃⌥1…9` / send `⌃⌥⇧1…9` · send-to-next `⌃⌥N` / follow `⌃⌥⇧N` · proportional width migration · throw to Space `⌃⌥⇧←/→` · follow thrown · direct display focus `⌃⌥⌘1/2/3` · disable per display · hot-plug recovery · refresh-rate aware.

**Physics & Performance:** Rust engine · zero hot-path alloc · `CADisplayLink` 80–120 Hz · analytical spring · synchronous frame 0 · 15 ms AX timeout · per-PID async queues · `CGWindowID` caching · viewport filtering · `AXEnhancedUserInterface` suppression · idle reconcile · exponential backoff attach.

**Visual Feedback:** minimap HUD · focus border · dimming · Slide Launch Control · status badge `🟢/⚪` · smooth transitions · live preview in Settings · trackpad test track · rotary smoothness wheel.

**Rules & Automation:** per-app policies · small-window float · excluded bundle IDs · insertion policy (After Focused/At End/In Current Column) · launch at login `SMAppService` (broken wiring — see §9) · layout persistence (now debounced 500 ms + quit/sleep; needs stable UUID keys) · restoration bounds guards.

**Setup/Diagnostics/Recovery:** Mac Setup & Conflict Checker (Rectangle/Magnet/AeroSpace/Amethyst/yabai/Loop/Moom + trackpad swipe + `tccutil reset` repair) · re-evaluate `⌃⌥Z` · relaunch `⌃⌥⇧Z` · diagnostic dump · structured logging · single-instance `flock`.

**Privacy/Packaging:** 100% offline (no `URLSession` in `Sources/`) · no telemetry · local `UserDefaults`+JSON · no Screen Recording · no root/SIP · `LSUIElement` · MIT · reproducible packaging with version stamp + signature + checksum.


## 12. Keyboard Shortcuts & Navigation

All defaults use `Control + Option` (`⌃⌥`) plus key. Optional legacy `⌥`-only fallbacks enable in **Settings → Shortcuts** (additive, skipped when would collide).

### 12.1 Default Keybindings

| Shortcut | Action | Description |
| :--- | :--- | :--- |
| `⌃⌥ + H` / `⌃⌥ + ←` | **Focus Previous Window** | Focus column left, scroll viewport |
| `⌃⌥ + L` / `⌃⌥ + →` | **Focus Next Window** | Focus column right, scroll viewport |
| `⌃⌥ + K` / `⌃⌥ + ↑` | **Focus Window Above** | Up within vertically stacked column |
| `⌃⌥ + J` / `⌃⌥ + ↓` | **Focus Window Down** | Down within stacked column |
| `⌃⌥⇧ + H` / `⌃⌥⇧ + ←` | **Move Column Left** | Reorder active column one left |
| `⌃⌥⇧ + L` / `⌃⌥⇧ + →` | **Move Column Right** | Reorder active column one right |
| `⌃⌥ + Return` / `⌃⌥ + F` | **Full Width Column** | Toggle active column between current width and full screen width |
| `⌃⌥ + W` | **Close Window** | Triggers active window's close action |
| `⌃⌥ + Tab` | **Cycle Windows / Tabs** | Cycles managed windows; inside tab group switches tabs |
| `⌃⌥⇧ + Tab` | **Cycle Backward** | Reverse cycle / reverse tab switch |
| `⌃⌥⇧ + T` | **Toggle Tab vs. Stack** | Toggles active column between tab strip and vertical stack |
| `⌃⌥ + T` | **Tab Same-App Windows** | Combines open windows of active app into Chrome-style tab group |
| `⌃⌥⌘ + T` | **Tab All Same-App Windows** | Groups all windows across workspace by app into tabs |
| `⌃⌥⌘ + ]` / `⌃⌥⌘ + [` | **Next / Prev Tab** | Switches tabs within focused group |
| `⌃⌥⌘ + N` | **New Tab in Group** | Spawns new window for current app, attaches as tab |
| `⌃⌥⇧ + W` | **Close Active Tab** | Closes only active tab's window (locked tabs protected) |
| `⌃⌥⌘ + D` | **Detach Active Tab** | Pops active tab into its own column/window |
| `⌃⌥⇧ + U` | **Ungroup All Tabs** | Explodes focused group into one column per tab |
| `⌃⌥⇧ + P` | **Keep Tab Bar Visible** | Pins tab bar open, including single-window groups |
| `⌃⌥⌘ + 1–8` | **Select Tab 1–8** | Activates tab at position 1–8 directly |
| `⌃⌥⌘ + 9` | **Select Last Tab** | Activates rightmost tab |
| `⌃⌥⇧ + [` / `⌃⌥⇧ + ]` | **Reorder Active Tab** | Moves active tab left/right within group strip |
| `⌃⌥ + O` / `⌥ + O` | **Strip Overview & Drag-Adjust** | Panoramic preview of all apps with live drag-to-reorder |
| `⌃⌥ + R` / `⌥ + R` | **Cycle Column Width** | 33→50→66→75→100% (target: 25/33/50/66/75 + separate full-width) |
| `⌃⌥ + C` / `⌥ + C` | **Center Active Column** | Centre active column on display |
| `⌃⌥ + G` | **Toggle Apps Edge Together** | Zero-gap mode |
| `⌃⌥ + B` / `⌃⌥⇧ + B` | **Snap Actions / Custom Box Studio** | Halves/thirds/quarters/max/centre radial menu |
| `⌃⌥ + A` / `⌃⌥⇧ + ↩` | **Balance / Equalise / Swap with Main** | Layout rebalancing |
| `⌃⌥ + N` / `⌃⌥⇧ + N` | **Send to Next Display / Follow** | Moves focused column, proportional width |
| `⌃⌥⇧ + ⌘ + ←/→` | **Throw to Space** | Dedicated factory chords for Space throwing |
| `⌃⌥ + 1…9` / `⌃⌥⇧ + 1…9` | **Switch Workspace / Send Window** | Per-display virtual workspaces 1–9 |
| `⌃⌥ + Z` / `⌃⌥⇧ + Z` | **Re-evaluate Windows / Relaunch** | Rescan vs relaunch in place |
| `⌃⌥ + /` | **Shortcut Cheatsheet** | Floating list rendered from live `ShortcutCatalog` |
| `⌃⌥ -` / `⌃⌥ =` | **Width Nudge** | ±5% steps |
| `⌃⌥⇧ -` / `⌃⌥⇧ =` | **Stack Height Nudge** | Taller/shorter for stacked column |
| `⌃⌥ + 0` | **Equalize Stack Heights** | Resets even splits |

> **Shortcut system details (FEATURE_MAP / FIX docs):**
> - `ShortcutBinding.swift`: `ShortcutChord` (Carbon keycode + modifiers, layout-aware glyphs), `ShortcutBinding` (per action, up to two chords), `ShortcutCatalog` (defaults, groups, normalisation, conflicts, reassignment, reset).
> - `ShortcutManager`: registration reads catalog (`applyBindings`), reports chords macOS refused, suspends hotkeys while recorder listens.
> - `SettingsStore`: `shortcutBindings` persisted as JSON, normalised on launch, reset with factory defaults.
> - Settings → Shortcuts: clickable keycaps, live recorder (`⌃⌥`/`⌘` required, Esc cancels), add/remove alternative chord, per-action reset, duplicate-chord banner with one-click resolution.
> - `ShortcutCheatsheetController`: `⌃⌥/` floating cheatsheet grouped by action family.
> - `KeyTranslator` now serialises Text Input Source lookups; concurrent layout queries previously aborted test runner.
> - Verified by `ShortcutCustomizationTests` (18 tests) and full suite 160 tests / 17 suites.
> - Properties: never register chord twice (`ShortcutCatalog.conflicts`), never resurrect deliberately unbound action (`normalized`), never let settings control exist without testable model.
> - **Legacy migration:** existing users keep current bindings, new ones only where keys free + one-click "Switch to new defaults". Proposed new defaults are `⌃⌥` (not bare `⌥` which blocks typing `˙`, `@` on German, `ç`/`®`/`å` elsewhere, and was restricted in macOS 15.0–15.1 for Carbon `RegisterEventHotKey`).

### 12.2 Trackpad & Mouse Navigation

- **Horizontal Trackpad Scroll:** 2-finger horizontal swipe pans infinite strip; smart intent + gesture latching prevents leaking into documents.
- **Chrome-Style Tab Strip (28 pt floating):** click to switch (no reload), live titles + dirty `•` + count + lock, drag to reorder (fluid animation), drag vertically beyond tear-off threshold to detach, drag window over column for luminous drop preview to combine into tabs, right-click context menu (duplicate/rename/reset/lock/move left-right/move to other group/detach/close others/close to right/ungroup), `[ Group Name ▾ ]` pill (rename/color/collapse/ungroup), `+` add tab (new or pick existing same-app window), `x` close, double-click rename, pin via `…` or `⌃⌥⇧P`.
- **Center Activity Capsule:** click middle of Minimap HUD to expand panoramic Strip Overview; drag app cards to rearrange strip.
- **Natural Scrolling:** configurable in Settings → Navigation.
- **Column Snapping:** viewport glides and snaps to nearest column boundary when scrolling stops; spring with velocity continuity.
- **How to add a feature (pattern):** 1) Model first (`Models/` `Codable, Sendable, Equatable`) → 2) Pure logic in `LayoutEngine` → 3) Tests before UI → 4) Persist in `SettingsStore` with safe default + `resetToDefaults()` → 5) Wire Settings row + status bar + `ShortcutAction` + default chord → 6) React live in `WorkspaceManager.setupBindings()` → 7) Docs/CHANGELOG/`scripts/package.sh` + verify installed app.

---

## 13. Permissions & Security Model

### 13.1 Principles — Privacy First, Minimum Permissions

- **No Root:** never runs as root / no sudo.
- **No SIP Disabling:** fully compatible with SIP enabled.
- **No Screen Recording:** does not capture screens/pixels/video buffers (no `CGWindowListCreateImage`, no ScreenCaptureKit, no `kCGWindowName` from `CGWindowListCopyWindowInfo` — only window numbers/owner PIDs/bounds/layer).
- **No Network / Telemetry:** 100% offline — zero analytics, zero crash telemetry, zero cloud accounts. (`PERMISSIONS.md` says "No Network" — once Sparkle ships this becomes "No telemetry; update check only, toggleable").
- **No Input Monitoring for Core Shortcuts:** Carbon `RegisterEventHotKey` (active `.defaultTap` for scroll needs only Accessibility, not Input Monitoring; `.listenOnly` would need Input Monitoring — never use).

### 13.2 Required Permission: Accessibility — Why

macOS requires Accessibility grant to inspect/reposition/resize/focus other apps' windows. Iume uses it to:
1. Enumerate top-level app windows `AXUIElementCopyAttributeValue(app, kAXWindowsAttribute)`.
2. Read geometry `kAXPositionAttribute`, `kAXSizeAttribute`.
3. Set position/size to arrange columns.
4. Focus/raise windows `kAXMainAttribute`, `kAXRaiseAction`.
5. Receive window created/closed notifications `AXObserver`.

### 13.3 Granting Accessibility

1. Launch Iume → if not granted, **do not auto-prompt on launch** (FIX requirement). Show onboarding/permission card with one button "Open Accessibility Settings" — only that click calls `AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true])` once.
2. System Settings → Privacy & Security → Accessibility → toggle Iume ON → admin password / Touch ID.

### 13.4 Troubleshooting & Revoking

- If granted but not moving windows (rebuild / stale code-signature hash): System Settings → Privacy & Security → Accessibility → select Iume → "−" remove → re-launch Iume or run `./scripts/build.sh` → add back when prompted. **But this should be last resort — real fix is stable signing (below).**
- To revoke: same pane → toggle OFF or "−" → Iume ceases window-management without crashing.
- **Look-alike prompts:** since Sequoia macOS re-asks Screen Recording roughly monthly — ensure Iume never triggers it (see 13.1). Keep scroll tap active (`.defaultTap`).

### 13.5 Permission Loop — Root Causes & Hardened Fixes (P0)

| # | Cause | Confidence |
|---|---|---|
| A | Ad-hoc signing (`codesign -s -`) or different identity each build → new cdhash → TCC treats each build as new app | High |
| B | Calls `AXIsProcessTrustedWithOptions` with prompt on every launch / polling timer | High |
| C | Runs from DerivedData/build folder/Downloads/translocated path `/private/var/folders/.../AppTranslocation/...` | Medium |
| D | Several copies with same bundle ID (debug + release + `/Applications` copy) | Medium |
| E | Launched as bare executable from Terminal/Xcode → grant attaches to wrong process | Medium |
| F | Embedded helper with different identity | Low |

**Confirm:**
```bash
codesign -dvvv --requirements - /Applications/Iume.app 2>&1 | egrep "Identifier|Signature|Authority|TeamIdentifier|designated"
# Signature=adhoc or TeamIdentifier=not set => cause A
spctl -a -vvv -t install /Applications/Iume.app  # should: accepted, source=Notarized Developer ID
mdfind "kMDItemCFBundleIdentifier == 'com.yourco.iume'"  # >1 path => cause D
log stream --predicate 'subsystem == "com.apple.TCC"' --info  # live decision
```

**Fixes (source-verified — IUME_FIXES_AND_UPGRADES §1):**
1. **Stable identity — never ad-hoc again:** Apple Developer ID Application cert OR free `Iume Local Signer` self-signed cert (Keychain → Certificate Assistant → Create Certificate → Code Signing → login keychain). `package.sh:40-56` must **fail** if no identity found instead of falling back to `--sign -`. Drop `--deep` (deprecated) + custom `--requirements`; drop `allow-jit`/`allow-unsigned-executable-memory` entitlements.
2. **Install without deleting bundle:** `pkill -x Iume || true; ditto "$APP_DIR" "/Applications/Iume.app"` — keep path constant. Never run `.build/` executable day-to-day; always launch bundle. Ship `.dmg` with Applications shortcut; if bundle not in `/Applications` or contains `AppTranslocation`, show "Move to Applications" and offer to move + relaunch before asking for Accessibility. Fix bundle ID forever (e.g. `com.yourco.iume`; `com.yourco.iume.dev` for debug).
3. **Prompt at most once per install, only from onboarding:** remove unconditional `promptForAccessibility()` + `openSettings()` from `main.swift:40-41`; `PermissionManager.requestPermissionExplicitly()` (`Permissions/PermissionManager.swift:63`) currently prompts + opens Settings repeatedly — keep 1 s poll but stop once trusted, start strip from one place, single permission owner (multicast `@Published var isTrusted` or `NotificationCenter`, not competing `onPermissionStateChanged` closures between `main.swift:15` and `WorkspaceManager`).
4. **Watchdog:** if trusted flips to false at runtime → stop engine, show menu bar warning, **do not re-prompt**; if trusted but AX returns `.apiDisabled` → show **Restart Engine** button. `DistributedNotificationCenter` for `com.apple.accessibility.api` → 0.5 s debounce → `engine.start()/stopGracefully()`.
5. **Stale-entry repair** (`repairStaleTCCEntry`, `tccutil reset Accessibility com.iume.Iume`) only from button in Mac Setup ("Permission looks granted but doesn't work → Repair"), never automatically.

**Done when:** 20 consecutive release builds installed over each other + reboot + Sparkle update never re-prompt (source-verified acceptance: 5 rebuild/reinstall cycles no prompt, fresh install exactly one permission card, grant starts strip within 1 s without relaunch).

---

## 14. Troubleshooting & Diagnostics

### 14.1 Quick Diagnostic Checklist

If windows not managed or shortcuts dead:
1. **Accessibility:** menu bar yellow warning → Settings → Advanced → check Accessibility active. If granted but inactive, remove/re-add (but see 13.5 — last resort).
2. **Management Enabled:** menu bar must show "Iume: Active" — if disabled click Enable Management.
3. **Excluded Apps:** Settings → Windows → check bundle identifier not in exclusion list.

### 14.2 Common Scenarios

| Scenario | What Happens | Handling |
|---|---|---|
| **Window stuck / not resizing** | Legacy/non-standard apps enforce fixed aspect or strict min size (System Settings, Calculator, 3rd-party utilities) | Iume reads app's minimum allowable size, respects it, adjacent columns don't overlap; after read-back store `column.minWidth = actual.width` and re-pack neighbours |
| **External monitor disconnected** | `didChangeScreenParametersNotification` | Auto-migrates columns from disconnected display to primary, re-aligns strip — no windows lost off-screen; debounced, remembers origin for restore on reconnect |
| **Resetting preferences** | Settings → Advanced → Reset Preferences to Defaults | Resets gaps, widths, policies to factory defaults (`resetToDefaults()` must share constants with init — e.g. `presetWidthRatios`) |
| **Exporting diagnostic report** | Settings → Advanced → Export Report | Copies to clipboard: window counts, columns, recent events, error counts; extended diagnostics: per-app AX latency, tap-disabled counts, classification decisions, persistence restore results |

### 14.3 Mac Setup Checker (Shipped + Hardening Needed)

**Live checklist — each item turns green when fixed:**

| Check | How to Read (verify with `defaults read`) |
|---|---|
| Accessibility granted | `AXIsProcessTrusted()` |
| Running from `/Applications`, not translocated | Bundle path |
| Displays have separate Spaces: **On** | `com.apple.spaces` → `spans-displays` |
| Auto-rearrange Spaces by recent use: **Off** | `com.apple.dock` → `mru-spaces` |
| Stage Manager: **Off** | `com.apple.WindowManager` → `GloballyEnabled` |
| macOS 15+ tiling drag-to-edge/menu-bar/`⌥`-drag: **Off** | `com.apple.WindowManager` (`EnableTilingByEdgeDrag`, `EnableTopTilingByEdgeDrag`, `EnableTilingOptionAccelerator`) |
| Trackpad gesture conflict with chosen finger count | `com.apple.AppleMultitouchTrackpad` + `com.apple.driver.AppleBluetoothMultitouch.trackpad` (3/4-finger swipe keys, `TrackpadThreeFingerDrag`) — **FIX:** also read `com.apple.trackpad.threeFingerHorizSwipeGesture`/`fourFingerHorizSwipeGesture` in `-currentHost` global domain; built-in vs Magic Trackpad domains differ; `MacSetupChecker.swift:151-152` only reads built-in today |
| `workspaces-auto-swoosh` (switch to Space with app windows) | `com.apple.dock` → `workspaces-auto-swoosh` — recommend **Off** (prevents `app.activate()` jumps to other Space on settle) |
| Conflicting window apps running | Rectangle, Magnet, Loop, BetterSnapTool, Moom, Amethyst, AeroSpace, yabai, Stage Manager tools — **FIX:** also detect BetterTouchTool snapping, Divvy, Spectacle, Hammerspoon, PaperWM.spoon/Swish; verify bundle IDs |

**Guided first run (target 4 steps — FIX doc):** 1) move to Applications → 2) grant Accessibility via single user-click prompt → 3) Mac Setup checklist → 4) interactive "try five shortcuts" (focus left/right, move, cycle width, stack). End with menu bar `Running`.

**Extra diagnostics:** Engine heartbeat each second; watchdog restarts engine if heartbeat stops/tap disabled/observers dead/`cannotComplete` spike; menu bar shows `Running`/`Stopped`/`Needs permission` + Start/Restart Engine/Rescan Windows; Engine Log + Reveal Engine Log; Diagnostics export already exists.


## 15. Known Issues — Root Causes & Fixes (11 Source-Verified)

Source: `IUME_FIXES_AND_UPGRADES.md` (491 + 552 lines) and `IUME_FIX_PARITY_UPGRADE_INSTRUCTIONS.md` (667+ lines) — 11 issues with fixes, Top 12 actions.

| # | Issue | Severity | Root Cause | Fix (shipped / planned) | Verification |
|---|-------|----------|------------|-------------------------|--------------|
| **1** | **Accessibility permission loop — re-prompts every rebuild / reboot** | P0 — must-fix | Ad-hoc signing (`codesign -s -`) → new cdhash each build; unconditional `promptForAccessibility()` on every launch; running from `DerivedData`/Downloads translocated path; duplicate bundle IDs; bare-executable launch | Stable identity (Developer ID or `Iume Local Signer` self-signed cert, `package.sh` must **fail** if none instead of `sign -`), install via `ditto` to `/Applications/Iume.app` without deleting bundle, single prompt only from onboarding button, single permission owner (`@Published isTrusted`), watchdog without re-prompt, `tccutil reset` repair only via Mac Setup button | 20 consecutive installs over each other + reboot + Sparkle update never re-prompt; 5 rebuild cycles no prompt, fresh install exactly one card, grant starts strip <1 s |
| **2** | **Window eligibility — single `kAXStandardWindowSubrole` check misclassifies** | P0 | Only standard windows tiled → dialogs floated incorrectly, floating palettes tiled causing chaos, Java/Electron/DRM windows crash path | Target eligibility table (§10): role→minimized→fullscreen→subrole→settable→buttons→per-app rule→float+log; handle `accessory` apps via KVO, leave small/fixed-size windows floating | Unit tests for each subrole; manual with Photoshop/Xcode/1Password/Java |
| **3** | **Discovery race — windows missing on app launch / slow apps** | P0 | Single query at t=0 misses windows still creating; subrole not set for ~100 ms; no per-window observer | Queries at 0, 0.15, 0.5, 1.5, 4 s + per-app `AXObserver` on dedicated thread + re-check 100 ms after `kAXWindowCreated` + self-healing reconcile on activation/unhide/space change/wake/idle/⌃⌥Z | Launch Finder/Safari/VS Code slowly; kill and relaunch app; verify no missing windows after 4 s |
| **4** | **Re-entrancy loop — `AXObserver` `kAXWindowMoved` fires on our own `setPosition`** | P0 | Setting position triggers observer → re-layout → infinite loop / jitter | Loop suppression: `isApplyingLayout` flag + `AXEnhancedUserInterface` suppression + coalescing `pendingAXEvents` + synchronous frame 0 + debounce | Move window programmatically; ensure observer callback ignored during apply; no oscillation |
| **5** | **Parking — windows clamped when placed entirely off-screen** | P1 | macOS WindowServer clamps windows with zero visible pixels back on screen | Leave ≥1 px visible at safe corner not intersecting neighbour display; parked once not per frame; SkyLight ordering | Place window at `-2000` and `4500`; verify it stays parked off-screen |
| **6** | **AX timeout blocks main thread — beachball on slow apps** | P1 | Synchronous `AXUIElementCopyAttributeValue` on main thread with default timeout | 15 ms AX timeout + per-PID async queues + `CGWindowID` caching + viewport filtering + `AXEnhancedUserInterface` suppression + exponential backoff attach | Stress with 50 windows; profile main thread <16 ms/frame |
| **7** | **Launch at Login broken — toggle does nothing** | P1 | `SettingsView` only writes `UserDefaults`; `MacSetupChecker.setLaunchAtLogin` exists but nothing calls `SMAppService.mainApp.register()`; `requiresApproval` unhandled | Wire `SettingsStore.launchAtLogin.didSet` → `SMAppService` + handle `.requiresApproval` with System Settings deep link | Toggle on/off; verify `SMAppService.status == .enabled` and survives reboot |
| **8** | **Persistence race — JSON torn on crash / quit** | P1 | Direct `UserDefaults` + non-atomic file writes; no debouncing; no `applicationWillTerminate` flush | Atomic `FileManager` writes + 500 ms debounce + flush on `terminate`/`sleep` + stable UUID keys + bounds guards on restore | Kill -9 and relaunch; verify no corrupt JSON; reboot persistence |
| **9** | **Scroll physics seam flicker / jitter at loop boundary** | P1 | Seam ratio snap without velocity continuity; spring reset on lap | Analytical damped oscillator with velocity handover + seam ratio snapping (18→32 pt) + `CADisplayLink` pacing + gesture latching | Scroll continuously across seam 20 laps; verify zero flicker, tick per lap |
| **10** | **Multi-display migration loses / misplaces windows** | P1 | `didChangeScreenParameters` not debounced; no origin memory; width not proportional | Debounced topology cache per display ID + migrate to primary on disconnect + restore origin on reconnect + proportional width migration | Unplug display with 10 windows; verify all on primary; replug → restore |
| **11** | **Shortcut conflicts & legacy migration resurrects unbound actions** | P2 | Duplicate chord registration; `normalized()` resurrects user-unbound actions; bare `⌥` blocks typing and was restricted in macOS 15.0–15.1 | `ShortcutCatalog.conflicts` prevents double registration + `normalized` never resurrects deliberately unbound + factory defaults use `⌃⌥` not bare `⌥` + optional legacy layer skipped on collision + one-click Switch to new defaults | Bind duplicate chord → banner + resolution; unbind action → persists unbound after relaunch; test German layout `˙/@/ç` |

> All 11 Fixes docs mark **P0 gaps as fully shipped** (per-app editor, space throwing defaults, cheatsheet) — §11.5. Remaining P0 is hardening the 11 fixes above to acceptance criteria.

---

## 16. Parity Matrix — Iume vs. Established Window Managers

Legend: ✅ shipped/parity · 🟡 partial · ⬜ not in Iume · — n/a

| Capability | Iume 2.6.0 | Rectangle / Magnet | AeroSpace / yabai | Loop / Moom | Amethyst / PaperWM |
|---|---|---|---|---|---|
| **Tiling model** | Infinite horizontal strip + per-column stacks | Halves/thirds/quarters, no strip | BSP / tiling per Space, no strip | Radial / grid snap, no strip | Tall/Wide/BSP per Space (Amethyst) · horizontal strip (PaperWM) |
| **Continuous strip scrolling** | ✅ endless, spring, seam tick | ⬜ | ⬜ | ⬜ | ✅ (PaperWM) |
| **Focus follows mouse / mouse follows focus** | ✅ (120 ms hysteresis) | ⬜ | ✅ (yabai) / ⬜ | ⬜ | ✅ (PaperWM) |
| **Per-display independent strip** | ✅ | — | ✅ | — | ✅ |
| **Virtual workspaces 1–9 per display+Space** | ✅ | ⬜ | ✅ (AeroSpace workspaces) | ⬜ | ⬜ |
| **Column stacks & tabbed columns** | ✅ | ⬜ | ⬜ | ⬜ | 🟡 (PaperWM stacks) |
| **Chrome-style tab strip inside columns** | ✅ 28 pt floating | ⬜ | ⬜ | ⬜ | ⬜ |
| **Per-app rules (`alwaysTile`/`alwaysFloat`/`fixedSlot`)** | ✅ | 🟡 (exclusions only) | ✅ | ⬜ | 🟡 |
| **Frame undo / history (`⌃⌥⌫`)** | ⬜ P1 roadmap | ✅ (Rectangle undo) | ⬜ | ✅ | ⬜ |
| **Scratchpad / sticky** | ⬜ P1 | ⬜ | ✅ | ⬜ | ⬜ |
| **Named layouts / profiles** | ⬜ P1 | ⬜ | ⬜ | ✅ (Moom) | ⬜ |
| **Config file / CLI (`iume apply-profile`)** | ⬜ P3 | ⬜ | ✅ (config) | ⬜ | ✅ |
| **Global `⌃⌥` shortcuts, no Input Monitoring** | ✅ Carbon hotkeys | ✅ | ✅ | ✅ | ✅ |
| **Accessibility-only (no Screen Recording)** | ✅ | ✅ | ✅ | ✅ (Loop needs SR for preview) | ✅ |
| **Mac Setup conflict checker** | ✅ (Rectangle/Magnet/AeroSpace/yabai/Loop/Moom + trackpad + TCC repair) | — | — | — | — |
| **Minimap HUD + focus border + dimming + Slide Launch Control** | ✅ | ⬜ | ⬜ | 🟡 (Loop preview) | 🟡 |
| **Rust physics core / zero hot-path alloc** | ✅ | ⬜ | ⬜ | ⬜ | ⬜ |
| **Offline, no telemetry** | ✅ | ✅ | ✅ | — (Loop telemetry) | ✅ |

**Takeaway for positioning (from FEASIBILITY_REPORT):** Iume's differentiator is the *PaperWM-style infinite strip + per-column stacks + 120 Hz Rust spring + minimap* without requiring SIP disable (yabai) or tiling-only. Gap to close for Rectangle/Loop parity is **frame undo**, for AeroSpace parity is **scratchpad + named layouts + config file**.

---

## 17. Marketing — Hero Features, Claims & Proof Sheet

### 17.1 Hero Narrative (MARKETING_FEATURES §1)

1. **Infinite horizontal strip** — PaperWM/niri-style, focus-driven viewport that glides with spring settle.
2. **120 Hz physics** — analytical damped oscillator, `CADisplayLink`-paced, zero hot-path allocations (Rust core).
3. **Per-display, per-Space strips** — independent columns per display and per Mission Control Space.
4. **Column stacks & tabs** — proportional stacks, tab bar overlay, Chrome-style tab strip you can click/drag/detach.
5. **Magnetic snapping & zero-gap tiling** — 32 pt attraction, seam ratio snaps, Apps Edge Together.
6. **Trackpad-native** — 2-finger strip panning, 3/4-finger swipes, momentum handover, gesture latching.
7. **Setup in 60 seconds** — Mac Setup checker, one-click Accessibility grant, guided shortcut tour.
8. **Privacy-first** — 100% offline, no Screen Recording, no telemetry, MIT-licensed.

### 17.2 Claim → Proof Mapping (must substantiate before publishing)

| Marketing Claim | Proof Required | Status |
|---|---|---|
| "Sub-ms focus" | `CADisplayLink` trace + Instruments Time Profiler, median <1 ms | Needs benchmark artifact |
| "Zero hot-path alloc" | Allocations instrument, scroll 60 s shows 0 alloc in engine | Rust core tested, Swift side needs proof |
| "120 Hz / ProMotion 120 Hz" | `CADisplayLink.preferredFrameRateRange` log on ProMotion | Implemented, needs screen recording |
| "Bundle < 4 MB" | `du -sh Iume.app` | Check `scripts/package.sh` output |
| "79 Swift tests + 30 Rust tests" | `swift test` + `cargo test` CI logs | Reported in MARKETING_FEATURES |
| "Universal Binary arm64 + x86_64" | `lipo -info` | MARKETING says arm64-only — reconcile |
| "No Screen Recording / no Input Monitoring" | `codesign -d --entitlements` + `CGEventTap` audit (active `.defaultTap` only) | Architecture supports, needs audit |
| "No telemetry, 100% offline" | `grep -r URLSession Sources/` == 0 + network monitor | True today; Sparkle will add update check |

### 17.3 Full Feature Count (for App Store / website)

MARKETING_FEATURES inventory counts ~80+ distinct toggles/actions. Use §11.7 as canonical list — every bullet there is a shipped feature that can be named in marketing. Do not invent features not in §11.7.

---

## 18. Roadmap & Implementation Order

**Rule:** each roadmap item is a vertical slice — model → engine → persistence → UI → shortcut → tests. Order by Value ÷ Effort (FEATURE_MAP §6).

### 18.1 Shipped — No Further Work (P0 done)

- [x] Per-app rules editor (Application Rules pane)
- [x] Space throwing factory chords (`⌃⌥⇧⌘←/→`)
- [x] Shortcut cheatsheet (`⌃⌥/`)

### 18.2 Next — High Value, Low Effort (P1 — build next)

| # | Feature | Effort | Why Next |
|---|---------|--------|----------|
| 1 | **Frame undo / history** (`⌃⌥⌫`) — per-window undo stack, last size | S | Rectangle/Loop parity, tiny model (array of `CGRect`) |
| 2 | **Named layouts** — save/restore strip as profile, builds on `LayoutPersistenceManager` | S | Unlocks dotfiles & sharing |
| 3 | **Scratchpad / sticky** — one hidden slot per display, toggled with chord, floats above strip | S | AeroSpace parity |

### 18.3 Medium Horizon (P2 — after P1)

| # | Feature | Effort |
|---|---------|--------|
| 4 | Per-workspace layout mode (`layoutMode` per `WorkspaceKey`) | M |
| 5 | Named workspaces + workspace bar (labels vs 1…9) | M |
| 6 | Per-display gaps/margins (today one `EdgeMargins` for all screens) | M |

### 18.4 Lower Priority (P3–P4 — when P1–P2 done or requested)

| Priority | Feature | Effort |
|---|---|---|
| P3 | Config file / export-import (TOML/JSON) + `iume apply-profile` CLI | M |
| P3 | URL scheme / Shortcuts.app actions (`iume://layout/grid`) | S |
| P3 | Gesture tuning (finger count, inversion, per-device sensitivity) | S |
| P4 | Window switcher palette (searchable titles vs blind cycling) | M |
| P4 | Menu bar per-app pause (suspend tiling for one app) | S |
| P4 | VoiceOver labels + keyboard-only Settings navigation | M |

### 18.5 Hardening Track (parallel to features — from FIX docs Top 12)

1. Stable signing + no ad-hoc fallback
2. Single-prompt permission flow + single owner
3. Eligibility table + accessory-app handling
4. Discovery schedule + per-window observers + reconcile
5. Loop suppression + `AXEnhancedUserInterface`
6. ≥1 px parking + safe corner
7. 15 ms AX timeout + per-PID queues
8. Atomic persistence + debounce + stable UUIDs
9. Proportional multi-display migration
10. `SMAppService` wiring + `requiresApproval`
11. `ShortcutCatalog` conflicts + legacy migration
12. Mac Setup checker: `-currentHost` trackpad + `workspaces-auto-swoosh` + extra conflicting apps + bundle-ID audit

---

## 19. QA Matrix & Acceptance Criteria

### 19.1 Test Suites (reported)

- **Swift:** 79 tests, 12 suites → now 160 tests / 17 suites after `ShortcutCustomizationTests` (18 tests). Run: `swift test` (or `xcodebuild test`).
- **Rust:** 30 tests. Run: `cargo test -p iume-engine` (or workspace).
- **Key suites:** `ShortcutCustomizationTests`, `LayoutEngineTests`, `WorkspaceManagerTests`, `MacSetupCheckerTests`, `PersistenceTests`, `SpringPhysicsTests`.

### 19.2 Manual QA Matrix

| Area | Scenario | Expected | How to Verify |
|---|---|---|---|
| Permissions | Fresh install → one card → grant → strip starts <1 s, no relaunch | Single prompt, no loop | Install .dmg, check TCC log |
| Permissions | 5 rebuilds + reboot + Sparkle update | Never re-prompts | `codesign -dvvv` stable cdhash |
| Windows | Launch app with 10 windows slowly | All adopted by 4 s | Visual + `Export Report` count |
| Windows | Photoshop inspector / Xcode inspector | Floats, not tiled | Check classification log |
| Windows | Minimized → de-minimize | Re-adopted | Minimize then click Dock |
| Windows | Full-screen → exit | Re-adopted | Enter/exit full-screen |
| Scroll | 20 laps across loop seam | Zero flicker, tick per lap | Continuous 2-finger swipe |
| Scroll | Momentum handover | Coasts then settles on column | Flick and release |
| Display | Unplug with 10 windows | All on primary | Unplug cable |
| Display | Replug | Restore origin display | Replug cable |
| Shortcuts | Duplicate chord | Banner + one-click fix | Bind same chord twice |
| Shortcuts | Unbind action | Stays unbound after relaunch | Unbind, quit, relaunch |
| Shortcuts | German layout `⌥` | `⌃⌥` defaults don't block `˙/@/ç` | Switch input source |
| Persistence | `kill -9` | JSON not corrupt, restores | `kill -9` then launch |
| Focus | Focus follows mouse 120 ms | No focus steal | Move mouse across columns |

### 19.3 Acceptance Predicates (FIX docs — all must pass)

- 20 consecutive release installs over each other + reboot + Sparkle update → never re-prompts Accessibility.
- Fresh install → exactly one permission card, grant → strip starts within 1 s without relaunch.
- `MacSetupChecker` reads `-currentHost` trackpad + `workspaces-auto-swoosh` + detects BetterTouchTool/Divvy/Spectacle/Hammerspoon/PaperWM.spoon/Swish by bundle ID.
- `SettingsStore.resetToDefaults()` shares constants with init (e.g. `presetWidthRatios`).
- `ShortcutCatalog.normalized` never resurrects deliberately unbound action; never registers duplicate chord.
- `KeyTranslator` serialises Text Input Source lookups (no concurrent abort).
- Persistence: atomic writes + 500 ms debounce + flush on terminate/sleep + stable UUID keys.

### 19.4 `scripts/package.sh` Gate (reproducible packaging)

Must stamp version + signature + checksum, fail if no signing identity (no `sign -` fallback), drop `--deep` + custom `--requirements`, drop `allow-jit` entitlements, produce `.dmg` with Applications shortcut, `LSMinimumSystemVersion` correct.

---

## 20. Documentation Corrections & Guardrails

Corrections where source docs contradict code or each other — fix docs before shipping.

| # | Doc Error / Drift | Correction |
|---|---|---|
| 1 | `COMPATIBILITY.md` says `SMAppService` needs macOS 14 | Actually macOS 13 (Ventura). Deployment target 14.0 is choice, not API floor. |
| 2 | `COMPATIBILITY.md` says Intel "Supported" | ChainYourMac is Apple-silicon-only; Tahoe is last Intel macOS — Intel support doubles test matrix with diminishing return — decide deliberately. |
| 3 | `ARCHITECTURE.md` / `COMPATIBILITY.md` display table missing Tahoe note | Add macOS 26 Tahoe "needs testing" row (already in §8). |
| 4 | `PERMISSIONS.md` "No Network" absolute | Once Sparkle ships: "No telemetry; update check only, toggleable, offline by default." |
| 5 | `MacSetupChecker.swift:151-152` only reads built-in trackpad domain | Must also read `-currentHost` global + `com.apple.trackpad.threeFingerHorizSwipeGesture`/`fourFingerHorizSwipeGesture`; Magic Trackpad uses different domain. |
| 6 | `SettingsStore.presetWidthRatios` duplicated between init and `resetToDefaults()` | Extract shared `static let defaultPresetWidthRatios`. |
| 7 | `MacSetupChecker.swift:40,74,103` uses read-then-write (`integer(forKey:)` defaults to 0) | Use `object(forKey:) == nil` to distinguish "not set" from 0. |
| 8 | `IUME_FIX_PARITY_UPGRADE_INSTRUCTIONS` suggests `allow-jit` entitlements + `--deep` + custom requirements | Drop all three — deprecated / over-broad. |
| 9 | `MARKETING_FEATURES` says binary is `arm64` only vs `COMPATIBILITY` Universal Binary | Reconcile — decide arm64-only vs Universal and reflect in `lipo` + marketing. |
| 10 | `FEATURE_MAP` P0 items still shown as ⬜ in some copies | They are shipped — mark ✅ and strike through. |

**Guardrails to keep docs honest:**

- `ShortcutCheatsheetController` renders from live `ShortcutCatalog` — cannot drift from code.
- `MacSetupChecker` checks are live — each row turns green when fixed; verify with `defaults read` commands in §14.3.
- `scripts/package.sh` must fail without signing identity — prevents ad-hoc drift.
- Single source for defaults: `SettingsStore` init and `resetToDefaults()` share constants.
- Re-export diagnostics: `Export Report` copies live counts, not stale docs.

---

## 21. Appendix — File Map, Glossary & Build

### 21.1 Source File Map (key files referenced across 10 docs)

| Path | Role |
|---|---|
| `Sources/Iume/Models/…` | Codable/Sendable/Equatable models (columns, workspaces, bindings, rules) |
| `Sources/Iume/Engine/LayoutEngine.swift` | Pure layout logic, no AX |
| `Sources/Iume/Engine/WorkspaceManager.swift` | Orchestrates engine + AX + persistence + bindings |
| `Sources/Iume/Engine/RustBridge/` | C++ WindowServer bridge + Rust spring/filter/hit-test |
| `crates/iume-engine/` | Rust physics core (~3,000 lines, 30 tests, zero hot-path alloc) |
| `Sources/Iume/Permissions/PermissionManager.swift` | Single owner for `isTrusted` |
| `Sources/Iume/Settings/SettingsStore.swift` | JSON persistence, `UserDefaults`, debounce, atomic writes |
| `Sources/Iume/Settings/ShortcutCatalog.swift` | Defaults, groups, conflicts, normalisation |
| `Sources/Iume/Settings/ShortcutBinding.swift` | `ShortcutChord` + `ShortcutBinding` |
| `Sources/Iume/Settings/ShortcutManager.swift` | Carbon `RegisterEventHotKey` registration |
| `Sources/Iume/Settings/KeyTranslator.swift` | `UCKeyTranslate` with serialised TIS lookups |
| `Sources/Iume/Settings/MacSetupChecker.swift` | Live checklist (Spaces, Stage Manager, tiling, trackpad, `auto-swoosh`, conflicting apps) |
| `Sources/Iume/UI/SettingsView.swift` | 8-pane Settings window |
| `Sources/Iume/UI/ShortcutCheatsheetController.swift` | `⌃⌥/` floating cheatsheet |
| `Sources/Iume/UI/MinimapHUD.swift` | Minimap + focus border + dimming + Slide Launch Control |
| `Sources/Iume/main.swift` | Entry point — must not contain unconditional `promptForAccessibility()` |
| `scripts/build.sh` / `scripts/package.sh` | Build + reproducible packaging (version stamp + signature + checksum) |
| `Tests/` | 160 Swift tests / 17 suites + Rust tests |

### 21.2 Glossary

| Term | Meaning |
|---|---|
| **Strip** | Infinite horizontal sequence of columns; viewport shows one display-width window onto it. |
| **Column** | Vertical container holding 1 stacked window or N tabbed windows; has width ratio. |
| **Workspace** | Virtual desktop 1–9 per display per Mission Control Space (`WorkspaceKey`). |
| **Box** | User-defined snap region (halves/thirds/quarters/custom) from `⌃⌥B` / Custom Box Studio. |
| **Parking** | Placing unmanaged windows ≥1 px visible at safe off-screen corner to preserve ordering without clamping. |
| **Seam** | Boundary between last and first column in Loop Mode; tick per lap. |
| **TCC** | Transparency, Consent, and Control — macOS privacy database for Accessibility etc. |
| **cdhash** | Code directory hash — TCC identity for signed bundle; changes when signing identity changes. |
| **Translocation** | macOS quarantine path randomisation for unsigned Downloads — breaks TCC. |
| **`AXEnhancedUserInterface`** | AX flag to suppress animations during programmatic moves. |

### 21.3 Build & Packaging

```bash
./scripts/build.sh          # debug build
./scripts/package.sh        # release .dmg — fails if no signing identity
swift test                  # 160 tests / 17 suites
cargo test -p iume-engine   # 30 Rust tests
codesign -dvvv --requirements - /Applications/Iume.app
spctl -a -vvv -t install /Applications/Iume.app
mdfind "kMDItemCFBundleIdentifier == 'com.yourco.iume'"
log stream --predicate 'subsystem == "com.apple.TCC"' --info
defaults read com.apple.spaces spans-displays
defaults read com.apple.dock mru-spaces
defaults read com.apple.WindowManager GloballyEnabled
defaults read -currentHost com.apple.trackpad.threeFingerHorizSwipeGesture  # global domain
```

### 21.4 Version Context

- **Inventory version:** Iume 2.6.0 — 2026-10-24
- **Sources:** 10 docs listed in header — this file is single source of truth consolidating them.
- **Bundle:** `LSMinimumSystemVersion 14.0` (Sonoma), `LSUIElement = true`, MIT, `com.yourco.iume` (and `com.yourco.iume.dev` for debug).

---

> **End of inventory.** This file consolidates all features, issues, fixes, compatibility, shortcuts, permissions, troubleshooting, parity, marketing, roadmap, QA, and corrections from the 10 source docs. For live truth, prefer `ShortcutCheatsheetController` (shortcuts), `MacSetupChecker` (system health), `Export Report` (diagnostics), and `codesign`/`spctl`/`log stream` (signing/TCC) over any static doc.

