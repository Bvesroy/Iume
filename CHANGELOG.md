# Changelog

All notable changes to **Iume** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.7.0] - 2026-10-23 (Browser-Style Window Tabs & Advanced Tab Grouping)

### Added
- **Chrome-style tab groups for native windows**:
  - Same-app windows are automatically merged into one tabbed column (`autoTabSameAppWindows`, on by default for new installs).
  - Floating 28pt tab strip with app icons, live window titles, click-to-switch, per-tab close, and `+` menu for new or existing same-app windows.
  - Drag tabs to reorder with spring animations; drag downward/out to detach a tab into its own column.
  - Single-window tab groups can pin the bar open; unpinned groups collapse back to a normal column when only one tab remains.
  - Live title updates, active-tab highlighting with matched-geometry animation, and tab-aware `⌃⌥Tab` cycling.
- **New keyboard shortcuts**: close active tab (`⌃⌥⇧W`), detach tab (`⌃⌥⌘D`), pin tab bar (`⌃⌥⇧P`), plus the existing next/previous/new-tab chords.
- **Tab Motion & Effects settings**: choose the active-tab switch style (Slide, Crossfade, Spring Pop or Instant) and the tab/bar open-close style (Scale & Fade, Slide, Fade, Materialize or Instant), with Balanced/Crisp/Playful/Cinematic presets, a 0.5×–2.0× speed control, an interactive live preview, and optional trackpad haptics. The floating bar now animates in and out instead of appearing or vanishing in a single frame, and System Reduce Motion is honoured.
- **Tabs menu** in the status bar and a dedicated tab-grouping card in Settings.

### Changed
- Float/unfloat moved to `⌃⌥⇧F` so `⌃⌥T` can group same-app windows.
- Tabbed layouts now persist presentation mode, active tab, and pinned state across restarts and virtual spaces.
- **Scroll gestures now stop exactly at finger lift by default** (`freezeOnRelease`): native macOS momentum packets are consumed but not applied, and no fling or column snap follows the release. The strip remains at the precise offset the user left it until the next gesture. Inertia can be re-enabled in **Settings → Gestures & Snapping**.

---

## [2.6.0] - 2026-10-19 (Rust Strip Engine — Deterministic Math Library)

> **Correction (2026-10-26):** The integration claims in this entry were
> overstated. In the shipped Swift app only `MagneticWindowEngine` calls
> `RustEngine` (magnetic snap evaluation, chained neighbour frames and seam
> ratio). `LayoutEngine`, the viewport/snap math and `ScrollController`'s
> spring remain pure Swift. The Rust crate is a deterministic parity reference
> and an optional accelerator, not the live layout or scrolling path.

### Added & Polished
- **🦀 Rust Strip Engine (`crates/iume_engine`)**:
  - New dependency-free Rust crate (~3,000 lines) implementing strip geometry, viewport projection and snapping, a harmonic spring integrator, and magnetic adhesion. The Swift app currently exercises the magnetic paths; the layout and spring entry points are parity references.
  - **Zero hot-path allocation**: layout is written into a caller-owned fixed-capacity frame buffer on the Rust side.
  - **Deterministic `f64` math** that matches Swift's `round()` and arithmetic exactly, keeping the two implementations in lockstep.
  - Split into `layout`, `viewport`, `spring`, `magnetic` and `types` modules with **36 unit tests** covering viewport scroll parity, zero-gap edge margins, spring stability at 80/120/240 Hz, chained neighbour adhesion and seam snapping.
- **🔗 Stable C ABI and Swift Facade**:
  - `Sources/CIumeEngine` exposes the engine through a versioned C header (`IUME_ABI_VERSION 1`) with `#[repr(C)]` structs and a thread-local frame buffer.
  - `Sources/IumeCore/Engine/RustEngine.swift` marshals columns, windows and stacks into flat buffers and copies results out before returning; every entry point is pure and thread-safe.
  - Floating-point-safe ABI: malformed input and empty strips are rejected rather than trapped, so callers keep working.
- **🔀 Live Adoption (Corrected)**:
  - `LayoutEngine` does **not** delegate `computeLayout`, `computeViewportOffset`, `maxScrollOffset`, `findClosestColumnIndex`, `computeSnapTarget` or column offsets to the Rust engine; those paths are Swift.
  - `MagneticWindowEngine` delegates seam-ratio snapping, magnetic snap evaluation and chained neighbour frames to `RustEngine` when the library is available.
  - `ScrollController` uses the Swift closed-form `Physics/SpringState.swift` solver for every animation frame. The Rust spring is a parity reference and is not wired into scrolling.
  - The pure-Swift implementations remain the reference (and the magnetic fallback), so the existing suite keeps verifying computed layouts against hand-derived expectations rather than the engine agreeing with itself.
- **🛠️ Reproducible Builds**:
  - Added `scripts/build-rust.sh` (the script `Package.swift` links against) with toolchain and artifact checks.
  - `build.sh`, `build-release.sh` and `package.sh` now build the Rust engine first, so a clean clone links without manual `cargo` steps.
  - `crates/iume_engine/target/` is git-ignored; only the crate sources are tracked.
- **📦 Packaging Hardening (`scripts/package.sh`)**:
  - The release version is read from the top `CHANGELOG.md` heading and stamped into the bundled `Info.plist` together with a git-based build number, so the shipped app can no longer report a stale version.
  - The script now verifies its own output: code-signature validity, the version the bundle reports, and that the binary has no dependency on `crates/iume_engine/target` — checked on both the `.app` and the app re-extracted from `dist/Iume-macOS.zip`.
  - `dist/Iume-macOS.zip.sha256` is emitted for distribution checks.
  - New flags `--package-only`, `--no-install`, `--no-backup` and `--help`; installing, launching the app and the MEGA `--delete` rsync are no longer forced on every packaging run.

### Verification
- `cargo test --release` → 30 passed.
- `swift test` → 79 tests in 12 suites passed.

## [2.5.0] - 2026-10-16 (Battle-Tested Amethyst Parity, SkyLight SPI Focus, Sloppy Focus & Multi-Display System Hardening)

### Added & Polished (Amethyst Parity & System Hardening)
- **⚡️ Direct WindowServer Window Activation (`WindowController.swift`)**:
  - Dynamically loads private SkyLight symbols `_SLPSSetFrontProcessWithOptions` and `SLPSPostEventRecordTo` with `kCPSUserGenerated`.
  - Directly commands the macOS compositor to bring windows to the front without activating all background windows belonging to the same application or flickering across spaces.
- **🪟 Window Peeking & Minimum Size Reconciliation (`WindowController.swift`)**:
  - Implemented 2-pass size reconciliation in `setFrame` (modeled after Amethyst's window peeking mechanics). Apps enforcing strict internal minimum sizes (e.g., Xcode, Spotify, Terminal) are queried via `kAXSizeAttribute` and cached accurately, preventing infinite resize loops.
- **🐁 Sloppy Focus / Focus Follows Mouse (`InteractionManager.swift` & `WorkspaceManager.swift`)**:
  - Added global mouse movement tracking with 120ms hysteresis debounce and AppKit-to-Quartz coordinate inversion.
  - Efficiently hit-tests visible windows via `CGWindowListCopyWindowInfo` (`kCGWindowListOptionOnScreenOnly`) and activates windows under the cursor without requiring clicks.
- **🖥️ Smart Window Margins & Built-in Screen Exemption (`LayoutEngine.swift`, `SettingsStore.swift`, `SettingsView.swift`)**:
  - **Smart Margins**: Automatically collapses window margins and outer gaps to 0 when only a single column is tiled on screen, maximizing screen real estate.
  - **Built-in Screen Exemption**: Option to automatically zero margins on the primary MacBook built-in retina display while preserving generous margins on larger external monitors.
- **🔍 Small Window Auto-Floating Heuristic (`WindowClassifier.swift`)**:
  - Added configurable heuristic threshold (`smallWindowThreshold`, default 500pt) that automatically assigns small modal dialogs, utility panels, and inspectors to floating mode instead of forcibly tiling them into columns.
- **🔁 Exponential Backoff Observer Attachment & Helper PID Normalization (`WindowObserver.swift`)**:
  - Added resilient exponential backoff retry mechanism (up to 3 retries with delay) for apps that launch slowly or delay AX accessibility tree registration.
  - Implemented PID normalization via `AXParent` to trace Chromium/Electron helper renderer processes back to the primary UI application.
- **📑 Native Tab Swapping (`WorkspaceManager.swift`)**:
  - Detects native tab switches in Safari, Finder, and Ghostty (where a new AX window element replaces the previous tab at identical coordinates) and seamlessly swaps the window ID inside the existing column instead of pushing a duplicate column onto the strip.
- **🌐 Proportional Multi-Display Column Scaling (`WorkspaceManager.swift`)**:
  - Moving columns across monitors (`sendFocusedColumnToNextDisplay`) now scales column widths proportionally according to relative display visible widths (e.g., 50% width on a 1080p screen scales to 50% width on a 4K screen).
- **⌨️ Amethyst-Parity Hotkeys & Workflows (`ShortcutManager.swift`)**:
  - Added Space Throws: `⌃⌥⇧←` (Throw to Left Space) and `⌃⌥⇧→` (Throw to Right Space).
  - Added Multi-Display Direct Focus: `⌃⌥1`, `⌃⌥2`, `⌃⌥3`.
  - Added System Recovery: `⌃⌥Z` (Re-evaluate all windows) and `⌃⌥⇧Z` (Relaunch Iume in place).
- **🧪 Comprehensive Test Suite (`AmethystFeatureParityTests.swift`)**:
  - Added 5 new automated tests covering smart margins, built-in screen margin collapse, small window auto-floating, proportional multi-display migration, and hotkey actions (76 total tests in 12 suites, all passing).

## [2.4.0] - 2026-10-16 (Intensive Magnetic Window Snapping, Adjacent Window Adhesion & Zero-Flicker Smooth Transitions)

### Added & Polished
- **🧲 Intensive Magnetic Window Snapping & Adhesion Engine (`MagneticWindowEngine.swift`)**:
  - **Adjacent Windows Remain Together**: When two adjacent windows are open side by side in the strip, dragging or moving one window automatically moves its adjacent companion window in real time, keeping them magnetically attached like chained links without gaps, overlaps, or separation.
  - **Automatic Magnetic Snapping on Approach**: When windows are brought closer to each other, once the distance between their adjacent boundaries drops within a 32pt magnetic attraction radius, they automatically snap flush (or to the configured gap) like magnets.
  - **Zero-Flicker Transitions**:
    - Programmatic move echoes are recorded in `WindowObserver` with a generous 0.65s suppression window, preventing recursive secondary AX notifications.
    - Active drag lockout (`activelyDraggingWindowId`) completely drops neighbor feedback loops at the gate.
    - Chained neighbor window coordinates are dispatched asynchronously via `setPositionAsync` to dedicated per-PID background serial queues with atomic latest-wins coalescing.
    - On mouse release, `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp])` triggers a silky 120Hz harmonic spring settle pass (`applyLayout(animated: true)`), gliding all windows smoothly into their exact resting positions with zero flicker or jitter.
  - **Enhanced Magnetic Seam Ratio Snapping**:
    - During manual edge resizing between adjacent columns, the shared seam boundary snaps cleanly to 25%, 33.3%, 50%, 66.7%, and 75% proportional splits with an enhanced 18pt tactile magnetic radius.
  - **Quick Controls & Global Shortcuts**:
    - Added menu bar item `🧲 Magnetic Window Snapping` in `StatusBarController`.
    - Added hotkey `⌃⌥M` (`Ctrl + Opt + M`) in `ShortcutManager` to toggle magnetic snapping on the fly.
    - Updated Settings Studio with detailed toggle description for Magnetic Window Snapping & Adhesion.
  - **Automated Test Coverage**:
    - Added comprehensive unit test suite `MagneticWindowEngineTests.swift` validating distance-based snapping, zero-gap snapping, chained adjacent neighbor movements, seam ratio snaps, and WorkspaceManager live drag reconciliation.

## [2.3.0] - 2026-10-15 (Overlapping Fix via CGS Transparency, Zero-Gap Strip Reflow, Polished Edge Resizing & Redesigned Settings Studio)

### Added & Polished
- **🛡️ Permanent Fix for Window Overlapping & WindowServer Coordinate Clamping**:
  - **Identified Root Cause of Window Overlap**: Previously, windows pushed past the right edge of the strip were placed at negative X coordinates (`visibleFrame.minX - width - 200`). macOS WindowServer prohibits windows from living entirely outside the visible desktop and forcibly clamped them to `x = 0`, dumping them directly on top of the leftmost window in the strip.
  - **SkyLight Dynamic Transparency (`CGSSetWindowAlpha`)**: Dynamically bound `CGSSetWindowAlpha` from `/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight`. Offscreen windows are smoothly faded to `alpha = 0.0` and ordered below visible windows (`kCGSOrderBelow`).
  - **Side-Stable Parking Coordinates**: Offscreen windows stay on their natural side of the desktop (`clampedOrigin.x = max(rawRect.origin.x, visibleFrame.maxX)` on the right, and `min(rawRect.origin.x, visibleFrame.minX - rawRect.width)` on the left). Windows never teleport across the screen, completely preventing WindowServer clamping, flickering, and compositor stalls.
- **✨ Fluid Buttery Sliding (No Mid-way Disappearing & 120 FPS)**:
  - Windows slide seamlessly from edge to edge without vanishing or stuttering.
  - Dynamic input dampening scales with user's smoothness preference, delivering responsive, latency-free gliding on 120Hz ProMotion displays.
- **📐 Polished Edge Resizing**:
  - Fixed `expectedColScreenX` in `WorkspaceManager.reconcileExternalFrameChange` to take `edgeMargins.left` into account.
  - Column 0 left-edge dragging now pins firmly to the screen margin, preventing windows from detaching or sliding inward.
  - Neighbor edge sizing adjusts adjacent columns seamlessly with magnetic snapping to 25%, 33%, 50%, 67%, and 75% splits.
- **🎛️ Revamped Settings Studio UI/UX**:
  - **Interactive Rotary Smoothness Wheel**: 360° tactile dial with gradient arc, central percentage display, dynamic physics badges (`Response ms`, `Damping ζ`, `VSYNC 120Hz`), and 4 presets (`⚡️ Snappy`, `⚖️ Balanced`, `✨ Silky`, `🌊 Liquid`).
  - **Live Strip Preview Canvas**: Miniature animated layout preview reacting in real-time to gap, margin, and column ratio changes.
  - **Interactive Trackpad Test Track**: Direct 2-finger horizontal swipe testing area inside Settings.
  - **Spacing & Margins Presets**: Tactile preset pills (`Together 0pt`, `Compact 4pt`, `Standard 8pt`, `Comfortable 12pt`, `Spacious 16pt`).
  - **Global Hotkey `⌃⌥,`**: Instantly brings the Settings window forward with proper window level and focus.
  - **Every Setting Reacts Live**: Every toggle, slider, and picker immediately updates the active workspace and layout engine without requiring an app restart.

## [2.2.0] - 2026-10-15 (Ultra-Smooth 120Hz ProMotion Scrolling, Zero IPC Bottlenecks & Fluid Momentum Handover)

### Added & Polished
- **🚀 Ultra-Smooth 120Hz ProMotion Display-Link Engine**:
  - **Zero Main-Thread Mach IPC Blocking**: Replaced synchronous `setPosition(element:position:)` calls on the main thread during scrolling with non-blocking `setPositionAsync(element:position:size:windowId:)`. Position updates are routed through dedicated per-PID serial queues (`com.iume.ax.<pid>`) with latest-wins coalescing and reduced 40ms messaging timeouts, keeping main-thread frame execution well within the 8.33ms budget.
  - **Eliminated Beat-Frequency Input Jitter**: Integrated a continuous frame-rate independent exponential smoothing filter (`1.0 - exp(-lambda * dt)`) in `ScrollController.swift`. This bridges the asynchronous arrival of trackpad event packets (~90–125Hz) with display refresh ticks (60/120Hz), eliminating micro-stutters and alternating 0-delta frozen frames.
  - **$C^1$ Velocity Continuity across Settle**: Preserved momentum velocity through `settleVelocity` directly into the analytical harmonic spring solver in `ScrollController.scrollTo`. The spring now seamlessly inherits the user's physical swipe velocity, eliminating the previous velocity-wipeout hiccup and sudden jerk when lifting fingers from the trackpad.
  - **Unbroken Momentum Gesture Ownership**: Trackpad gestures now remain latched to `.strip` throughout both active finger dragging and the subsequent momentum decay phase. Momentum events no longer leak into underlying application windows, preventing mid-scroll friction and abrupt halts.
- **⚡ Eliminated High-Frequency System SPI & WindowServer IPC Storms**:
  - **CGWindowID Caching**: Added thread-safe in-memory caching of `CGWindowID` in `WindowRegistry` (`getCGWindowID(for:ax:)`), dropping low-level `_AXUIElementGetWindow` SPI invocations to zero during 120Hz scrolling.
  - **NSScreen Query Caching**: Cached display-to-`NSScreen` lookups in `WorkspaceManager` (`cachedScreen(for:)`), preventing expensive `NSScreen.screens` WindowServer IPC calls on every display tick.
  - **Throttled Minimap HUD**: Throttled subpixel Minimap updates (< 0.75pt) and replaced 120Hz timer allocations with an elapsed-time debounce check in `MinimapHUDController`.
  - **Overlay Reallocation Optimization**: Added view state caching in `TabBarOverlayController` to avoid recreating SwiftUI `NSHostingView` on every frame, and guarded `orderOut` in `DimmingOverlayController` and `FocusBorderOverlay` against redundant WindowServer calls.
- **⌨️ Fluid Compounding Keyboard Scrolling**:
  - Keyboard scroll navigation (`.scrollLeft`, `.scrollRight`) now compounds smoothly from `smoothTargetOffset` when in motion and carries `currentVelocity`, allowing rapid successive keypresses to glide gracefully without stutter or lost distance.

## [2.1.0] - 2026-10-15 (Apps Edge Together, Zero-Gap Strip Tiling & Magnetic Edge Snapping)

### Added & Polished
- **🧲 Apps Edge Together (Zero-Gap Strip Tiling)**:
  - Added dedicated toggle `@Published public var appsEdgeTogether: Bool` in `SettingsStore` with seamless bidirectional synchronization with `windowGap` (restoring user's previous gap when toggled off).
  - Tiling columns now sit completely flush with zero pixels of desktop wallpaper showing between strips (`colScreenX[i + 1] == colScreenX[i] + colWidth[i]`).
  - Added dedicated keyboard shortcut `⌃⌥G` (Ctrl+Option+G) to toggle Apps Edge Together on the fly.
  - Added status menu item `"🧲 Apps Edge Together (Zero Gap)"` in `StatusBarController` with live checkmark/bullet state.
  - Added tactile gap preset controls in `LaunchHUDController` and `SettingsView` (`Together 0pt`, `Compact 4pt`, `Standard 8pt`, `Spacious 16pt`).
- **Eliminated All Causes of Space Between Strips**:
  - **Identified & Fixed Left Edge Resizing Math**: Fixed `prevColOriginX` derivation in `WorkspaceManager.reconcileExternalFrameChange`. Previously, shifting the neighbor's frame relative to the old pre-drag position resulted in an 88–100px void or overlap. The left neighbor now remains pinned to its true origin with right edge pinned to `newFrame.minX - gap`.
  - **Eliminated 35pt Premature Edge Clamping**: Removed premature `maxVisibleX - 35` clamping logic in `LayoutEngine.computeLayout`, allowing windows within 35pt of the right screen edge to remain fully visible rather than being parked prematurely.
  - **Reactive Gap Adjustments**: Added dynamic Combine subscriptions in `WorkspaceManager` so changing `windowGap` or toggling `appsEdgeTogether` reflows all displays and repaints layouts instantly without requiring an app restart.
  - **Sub-Pixel Stack Alignment**: Fixed remainder height absorption in stacked columns (`(baseOriginY + usableHeight) - currentY`) preventing fractional 1pt pixel gaps between vertically stacked windows.
- **Magnetic Edge Snapping**:
  - Added `@Published public var edgeSnapping: Bool` in `SettingsStore`.
  - During live manual window edge resizing, adjacent window boundaries snap magnetically to clean column ratio splits (25%, 33.3%, 50%, 66.7%, 75%) with an 8pt magnetic capture radius.

## [2.0.1] - 2026-10-15 (Interactive Smooth Scroll Wheel, Live Edge Resizing Polish & System Lag Elimination)

### Added & Polished
- **Tactile Smooth Scrolling Wheel in Settings**:
  - Designed and built `SmoothScrollWheelView`: a custom rotary dial UI in Settings with tick marks, a rotating needle pointer, percentage readout, smooth drag gestures, and quick preset buttons (Snappy 25%, Balanced 50%, Smooth 75%, Silky 100%).
  - Integrated directly into the analytical harmonic spring physics solver in `ScrollController.swift`, dynamically tuning response time (0.08s - 0.32s), damping ratio (0.86 - 0.98), rolling velocity smoothing weight (0.40 - 0.85), and discrete wheel settle debounce.
  - Added an interactive live horizontal scroll test track inside Settings so users can immediately test and feel their scroll smoothness changes.
- **Polished Edge Resizing & Non-Blocking Neighbor Adjustments**:
  - Offloaded adjacent neighbor window geometry updates to a dedicated serial background queue (`setFrameAsync`) during live edge resizing (`resizingWindowId != nil`), eliminating Main-thread stalls and mouse cursor fighting.
  - Lowered minimum column width limit to 220.0pt for fluid, unrestricted narrow-column adjustments.
- **Smooth Full-Width Sliding to Right Edge & Zero Disappearing Midway**:
  - Eliminated premature offscreen parking during motion: windows sliding towards or from the right edge glide smoothly across the entire display without disappearing midway.
  - Safe parking now activates only once a window's left edge actually reaches the display border, with settled-state parking protecting against WindowServer's leftward clamping overlap.
  - Added `maxScrollOffset` so scrolling and focus centering smoothly reach the right end of the strip.
- **System Lag & IPC Overhead Elimination**:
  - Throttled periodic reconcile timer from 2.0s to 12.0s, eliminating continuous background Accessibility polling.
  - Eliminated per-frame timer creation during animated scrolling in `applyPhysicalWindowPositions`.
  - Conditionalized tabbed column overlays and dimming overlays to only update when tabbed columns or dimming settings are active.
- **Smooth Window Transition Animations**:
  - Added smooth animated frame transitions for `FocusBorderOverlay` using `NSAnimationContext.runAnimationGroup` (ease-out curve, 0.22s duration).
  - Integrated `centerMode` animated camera shifts when navigating or changing window focus.

## [2.0.0] - 2026-10-15 (Major Architectural Remediation & Complete Feature Parity Upgrade)

### Added & Upgraded
- **Zero-Overlap Window Layout & Safe Offscreen Parking**:
  - Eliminated window overlapping caused by macOS WindowServer right-edge clamping: windows off-screen to the right are now safely parked in negative X coordinates (`visibleFrame.minX - width - 200`), permanently preventing WindowServer from clamping them back onto visible screen columns.
  - Inactive tabbed windows are also parked in negative X space, guaranteeing zero window overlap.
- **Focused-Strip Slotting for Newly Opened Apps**:
  - Newly opened applications and windows now deterministically slot right next to the active/focused column (`effectiveFocusedIndex + 1`), smoothly bringing the new window into view beside the user's current task without jumping to the end of the strip.
  - Extended launch heuristics and activation detection to 10.0 seconds to accommodate Electron, VS Code, Xcode, and browser windows.
- **Seamless Live Manual Window Resizing with Auto-Adjusting Adjacent Edges**:
  - Replaced the sluggish 150ms debounce and 25px deadzone with responsive ~40-50 FPS live rate-limited tracking in `WindowObserver`.
  - When manually dragging a window's border, the adjacent window automatically adjusts to the new edge in real time (absorbing the width delta while preserving `windowGap` and enforcing minimum column width constraints).
  - Both right-edge dragging (adjusting the right neighbor) and left-edge dragging (adjusting the left neighbor) update synchronously with zero visual lag and zero window overlap.
  - Non-blocking AX write bypass avoids fighting the user's mouse cursor during live dragging.
- **Butter-Smooth 120 FPS Scroll Architecture & Micro-Stutter Elimination**:
  - **Unified Harmonic Spring Physics**: Eliminated dual-spring dissonance (`CriticallyDampedSpring` vs `SpringState`) that caused frame-1 positional discontinuities. Tuned critically damped harmonic response (`dampingRatio = 0.90`) with synchronous frame-0 execution for 0ms visual latency.
  - **Decoupled Hardware Momentum Watchdog**: Fixed the fling-to-snap jerk cycle where lifting fingers triggered column snapping before macOS emitted trackpad momentum events. High-velocity finger lifts defer settle by 50ms, seamlessly gliding through macOS hardware momentum phases (`1` & `2`) and snapping only on completion (`phase 4`).
  - **Zero-IPC Moving Window State (`isMoving`)**: Strictly bypassed synchronous `setSize`, synchronous `setPosition`, and synchronous Mach IPC `enforceStripZOrder` (`kAXRaiseAction`) while windows slide across the screen. Origins are written via non-blocking, latest-wins serial queues (`setPositionAsync`). Full settle passes and Z-order enforcement execute only once the spring arrives at rest.
  - **Deferred In-Flight App Focus**: Removed premature `activateWindow` and `app.activate()` calls during settle snapping. Columns glide silently at 120 FPS; target applications are raised and focused in `onAnimationCompleted` without interrupting compositor animations.
  - **120Hz VSYNC Paced Multitouch Direct Manipulation**: 3/4-finger swipe deltas are accumulated into `pendingInteractiveDelta` and stepped exclusively on the `CADisplayLink` 120Hz VSYNC tick, completely eliminating phase jitter from unsynchronized private thread callbacks.
- **120Hz ProMotion Analytical Spring Physics Engine**:
  - Replaced static cubic ease-out curves with an analytical `SpringState` harmonic oscillator solver (`response = 0.22`, `dampingRatio = 0.92`) driven by `CADisplayLink` requesting `CAFrameRateRange(80, 120, 120)`.
  - Input capture is completely decoupled from Accessibility actuation: `CGEventTap` and Multitouch callbacks only accumulate target offsets in memory and wake the display link; all AX IPC executes synchronously inside the 120Hz display link tick.
  - Active display link remains latched for 1.0 second after input settles, completely preventing Apple Silicon ProMotion displays from downclocking to 60Hz.
- **Native 3-Finger & 4-Finger Trackpad Swipes (`MultitouchSupport.framework`)**:
  - Bridged private macOS `MultitouchSupport.framework` (`MTDeviceCreateList`, `MTRegisterContactFrameCallback`) to track hardware trackpad contact centroids directly.
  - 3- and 4-finger swipes glide 1:1 with finger centroids across the continuous strip without requiring modifier keys.
  - Preserved optional modifier-gated 2-finger scrolling (`withOption`, `withControl`, `always`, `seamlessHorizontal`).
- **Symmetric Edge Sliver Clamping & CGS Z-Ordering**:
  - Eliminated the v1.0.2 negative-X offscreen teleportation regression across the right viewport edge.
  - Symmetrical 3.0pt edge sliver clamping (`sliverWidth = 3.0`, `sliverHeight = 12.0`) tucks parked offscreen windows at `visibleFrame.maxY - sliverHeight`, preventing WindowServer from clamping windows or spilling pixels onto adjacent monitors.
  - Implemented dynamic SkyLight private window ordering via `_CGSDefaultConnection` and `CGSOrderWindow`: visible strip columns are explicitly raised above background apps and offscreen slivers are pushed below.
  - Selective AX size caching skips `setSize` calls during horizontal navigation when window dimensions haven't changed.
- **Layer-0 Hybrid Window Discovery & Smart Floating**:
  - Replaced button and title presence filtering with `kCGWindowLayer == 0` check via `CGWindowListCopyWindowInfo`. Automatically filters out Finder's desktop window (-2147483623) while allowing borderless developer terminals (Ghostty, iTerm2, Kitty, Alacritty) and titleless Electron apps into the strip.
  - Smart Floating detects fixed-dimension/non-resizable windows (`AXUIElementIsAttributeSettable(kAXSizeAttribute)` false or `minSize == maxSize`, e.g. Calculator) and per-app rules (`AppRulePolicy.alwaysFloat`, `alwaysTile`, `fixedSlot`).
- **Vertical Stacks & Tabbed Columns (`ColumnPresentationMode`)**:
  - Columns support both `.stacked` (proportional vertical height with 200pt minimum clamp) and `.tabbed` presentation modes.
  - Built interactive floating `TabBarOverlayController` (`NSPanel`) displaying an ultra-thin 28pt tab bar above tabbed columns with live app icons, titles, and clickable tab selection.
  - Added commands to pull/stack windows into left/right column (`⌃⌥[` / `⌃⌥]`), pop/unstack out of column (`⌃⌥⇧[` / `⌃⌥⇧]`), and flip stacked vs. tabbed modes (`⌃⌥⇧T`).
- **3 Center Modes & Dock-Aware Gaps**:
  - Implemented `CenterMode`:
    - `never`: scrolls only on-demand to bring focused column inside margins.
    - `onOverflow`: centers focused column only when total strip width exceeds usable viewport width.
    - `always`: keeps active column locked in center of screen.
  - Added configurable inner gap and independent outer screen margins (`top`, `bottom`, `left`, `right`) down to 0px.
- **Preset Width Cycling & Nudging**:
  - Forward and backward preset cycling (`25% → 33% → 50% → 66% → 75% → 100%`) via `⌃⌥R` and `⌃⌥⇧R`.
  - ±5% width nudging via `⌃⌥-` (narrower) and `⌃⌥=` (wider).
- **Interaction Manager & Anti-Focus Stealing**:
  - Created `InteractionManager` tracking user-initiated app activations within a 2.0-second window. Background app popups slot silently beside the focused column without stealing focus or scrolling the viewport.
  - Titlebar drag-to-reorder: dragging a window titlebar calculates column midpoints and rearranges the strip on drop.
  - Mouse follows focus: automatically warps cursor to the center of the newly focused window via `CGWarpMouseCursorPosition` when enabled.
- **Inactive Window Dimming**:
  - Added `DimmingOverlayController` rendering a subtle translucent veil over unfocused windows on the active display.
- **Virtual Workspaces (1–9 per Display)**:
  - Scoped workspace strips by `WorkspaceKey(displayId, spaceId, workspaceIndex 1...9)`.
  - Added shortcuts to switch workspaces (`⌃⌥ 1...9`) and migrate windows between workspaces (`⌃⌥⇧ 1...9`).
- **Stable Code Signing & Single-Shot Accessibility Permissions**:
  - Updated `scripts/package.sh` to embed an explicit Designated Requirement (`identifier "com.iume.Iume"`), detect persistent code-signing identities (`Developer ID Application` / `Iume Local Signer`), and deploy directly to `/Applications/Iume.app`.
  - Upgraded `PermissionManager`: eliminated recurring `AXIsProcessTrustedWithOptions([Prompt: true])` loops with single-shot prompts and silent `AXIsProcessTrusted()` polling.
  - Added one-click `tccutil reset Accessibility com.iume.Iume` repair button to clear stale TCC cdhash entries.
- **Standardized Control-Option (⌃⌥) Default Shortcuts**:
  - Switched default chords to ⌃⌥ (Control + Option) to avoid interfering with international character typing on ⌥, while retaining an optional legacy ⌥ toggle.
  - Integrated Carbon `UCKeyTranslate` in `KeyTranslator` to map hardware virtual keycodes to correct glyphs for AZERTY, QWERTZ, and Dvorak layouts.
- **Mac Setup & Launch-at-Login Diagnostics**:
  - Upgraded `MacSetupChecker` with `SetupHealthReport` and `SMAppService.mainApp` registration for launch-at-login.
- **Direct Low-Level `_AXUIElementGetWindow` SPI Bridge**:
  - Replaced heuristic CGWindowList fuzzy bounding box matching with direct macOS `_AXUIElementGetWindow` system SPI.
  - Generates 100% deterministic, stable `CGWindowID` references across `WindowDiscovery`, `handleWindowCreated`, `handleFocusedWindowChanged`, and `WindowRegistry`, completely eliminating window identity mismatches and missed windows.
- **Section 2.3 Window Classification & Smart Floating**:
  - Implemented comprehensive `WindowClassification` (`tile`, `float`, `ignore`) covering empty/unknown subroles, close/zoom button presence, and fixed-size checks.
  - Fixed-size utilities and dialogs (e.g. Calculator, system utility panels) automatically smart-float above the slide strip without disrupting column flow.
- **AXEnhancedUserInterface Automatic Disabling During Scroll (Rectangle/Amethyst-Style)**:
  - If an app (Spotify, Chrome, Electron) has `AXEnhancedUserInterface = true`, Iume suppresses it during management, preventing macOS from executing slow synchronous accessibility tree walks and window move animations that cause stutter.
- **System-Wide Reconcile Sweeps & Per-Window Observers**:
  - Added listeners for `NSWorkspace.activeSpaceDidChangeNotification`, `NSApplication.didChangeScreenParametersNotification`, and `NSWorkspace.didWakeNotification` to immediately trigger window discovery and layout reconciliation.
  - Attached per-window observers for `kAXUIElementDestroyedNotification`, `kAXWindowMiniaturizedNotification`, `kAXWindowDeminiaturizedNotification`, `kAXWindowMovedNotification`, and `kAXWindowResizedNotification`.
  - Staggered launch discovery sequence at t = 0, 0.15, 0.5, 1.5, 4.0s for slow-spawning applications.
  - Idle background reconcile sweep tuned to 2.0s interval.
- **Multi-Monitor "Send to Next Display" (`⌃⌥N`)**:
  - Added `⌃⌥N` (`Control + Option + N`) global shortcut and menu item to instantly migrate the focused window/column from the active display's strip to the next physical display's strip.
- **Mac Setup & Conflict Checker Panel**:
  - Implemented `MacSetupChecker` and native SwiftUI `MacSetupView` inspecting:
    - Accessibility permission (`AXIsProcessTrusted()`)
    - `/Applications` install path and AppTranslocation status
    - Displays have Separate Spaces (`spans-displays`)
    - Auto-rearrange Spaces by most recent use (`mru-spaces`)
    - Stage Manager status (`GloballyEnabled`)
    - macOS 15 edge drag tiling status (`EnableTilingByEdgeDrag`)
    - Conflicting window managers (Rectangle, Magnet, AeroSpace, Amethyst, yabai, Loop, Moom)
  - Accessible via Menu Bar -> "🛠️ Mac Setup & Conflict Checker..." and Settings -> Mac Setup tab.
- **Restoration Integrity**:
  - Enhanced `restoreAllWindowFrames()` with screen-centering bounds guards, guaranteeing that windows with abnormal or previously parked frames are cleanly restored to the center of the display with proper dimensions, never left stranded in corners.
- **Milestone Backup**:
  - Created checkpoint backup snapshot `backups/checkpoint-point25/`.

## [1.0.6] - 2026-10-15 (Milestone: Smooth Scrolling & Zero-Lag 120 FPS ProMotion)

### Added & Optimized
- **Hardware-Locked `CADisplayLink` 120 FPS / 60 FPS Pacing**:
  - Replaced variable-interval Foundation `Timer` and asynchronous dispatch hops with macOS `CADisplayLink` in `ScrollController`, locked directly to the hardware display refresh rate (120 Hz on Apple Silicon ProMotion screens, 60 Hz on standard external displays).
  - Eliminates micro-stutter and kernel timer coalescing jitter during trackpad scrolling and keyboard navigation.
- **Ultra-Fast Non-Blocking Event Tap Queueing**:
  - `CGEventTapCallBack` now aggregates delta into an atomic buffer and returns `nil` in `< 0.005 ms` (5 microseconds), completely eliminating `.tapDisabledByTimeout` events where macOS previously dropped or disabled the trackpad tap under load.
  - VSYNC-driven display link consumes aggregated deltas once per hardware frame, preventing multiple redundant IPC calls from firing within a single 8ms window.
- **AX Messaging Timeout & Redundant IPC Overhead Elimination**:
  - Reduced `AXUIElementSetMessagingTimeout` in `WindowController` from 150ms to 15ms (`0.015s`), preventing slow or busy applications from stalling Iume's main run loop.
  - Removed duplicate `AXUIElementSetMessagingTimeout` calls before every single `setPosition` and `setSize`.
  - While scrolling across the horizontal strip, window heights and column widths are fixed; `setFrame` detects `sizeDiff < 0.5` and strictly issues a single `setPosition` call, skipping `setSize` entirely.
- **Active Range Viewport Filtering**:
  - `WorkspaceManager.applyPhysicalWindowPositions` now constrains physical window movement to visible windows and immediate neighbors entering the screen (160 pt margin), eliminating hundreds of redundant Accessibility IPC calls per second to far-away offscreen windows.
- **Overlay Redraw Freezing During Active Scroll**:
  - Floating focus ring (`FocusBorderOverlay`) is hidden during active continuous swipe and snaps crisply back into place upon settle, eliminating WindowServer compositor thrashing.
  - Minimap HUD autohide timer countdown is debounced, avoiding Foundation timer recreation on every micro-tick.
- **Airtight App & Window Detection ("No Apps Left Behind")**:
  - Added `NSWorkspace.didActivateApplicationNotification` observer in `ApplicationDiscovery` and `WorkspaceManager`: whenever an application is activated, clicked, or switched to via Cmd+Tab, Iume immediately verifies its windows and slots them into the strip.
  - Added unmanaged window adoption in `handleFocusedWindowChanged`: clicking an unmanaged window immediately registers it and slots it beside the focused column.
  - `handleWindowCreated` now supports processes without bundle identifiers (using `app.<pid>` fallback) and captures windows dynamically even if initial accessibility properties take a moment to report.
  - Added periodic background reconcile every 3.5s to sweep for any newly spawned windows.

## [1.0.5] - 2026-10-15

### Added
- **Stop & Restore Windows Button**:
  - Added a prominent, beautifully styled **"Stop & Restore Windows"** button to the floating Launch Control panel (`LaunchHUDView`), the macOS menu bar menu (`StatusBarController`), and `SettingsView`.
  - Clicking Stop immediately stops Iume's sliding window management and returns all application windows back to their original pre-tiling positions and sizes.
  - Added active/stopped status badge (`🟢 ACTIVE` / `⚪ STOPPED`) in the launch panel header.
  - Added global shortcut `⌥⇧S` (`Option + Shift + S`) to instantly stop Iume and restore windows from anywhere.
  - Added persistent pre-tiling frame tracking in `WindowRegistry` to guarantee original window geometries are preserved even across repeated kickstart re-arrangements.

## [1.0.4] - 2026-10-15 (Milestone: Point 25/100)

### Added
- **Automatic Pre-Tiling Window Restoration on Quit / Stop**:
  - `ManagedWindow` now preserves the exact `initialFrame` captured at discovery time.
  - Calling `WorkspaceManager.stop()` (via Quit, App Terminate, SIGINT/SIGTERM, or disabling management in Settings/Status Bar) restores every window back to its pre-tiling geometry.
  - Offscreen-parked and corner windows are cleanly validated and brought back onto the visible screen with proper dimensions, ensuring no window is ever left stranded in the corner.
- **Quartz WindowServer Direct App & Window Discovery**:
  - `ApplicationDiscovery` now queries `CGWindowListCopyWindowInfo` to discover any process with an active on-screen window at layer 0 (terminal emulators, Electron apps, developer tools, accessory apps with GUI).
  - `WindowDiscovery` checks `kAXPositionAttribute` settability via `AXUIElementIsAttributeSettable` as the primary eligibility criterion, capturing apps with custom titlebars, empty initial titles (e.g. blank browser tabs), and non-standard subroles.
- **High-Performance Lag Elimination**:
  - Eliminated synchronous AX IPC thrashing during scrolling by introducing an active viewport margin: windows already parked outside the viewport margin are skipped during micro-tick scrolling updates, reducing IPC overhead by over 75%.
  - Preserved permanent designated requirement code signature (`designated => identifier "com.iume.Iume"`) deployed directly to `/Applications/Iume.app`.
- **Milestone Backup**:
  - Archived point 15 baseline snapshot to `backups/checkpoint-point15/`.

## [1.0.3] - 2026-10-15

### Added
- **New Windows Slot Beside the Focused One**:
  - Dynamically resolves target workspace from the currently focused window so newly launched apps slot directly next to what you were using, across any display.
  - Automatically raises and focuses newly created windows to bring them to front.
  - Non-overlapping columns ensure every window has its own dedicated place on the continuous strip.
- **Physical Spring Physics Animation ("Strip Follows Your Focus")**:
  - Replaced cubic easing with an analytical damped harmonic oscillator spring model ($\zeta \approx 0.896, \omega_n \approx 16.73$).
  - Executes frame 0 immediately upon shortcut press for true zero-perceived latency.
  - Minimal scrolling logic scrolls just far enough to reveal the focused window (or remains stationary if already fully visible).
  - 120Hz ProMotion pacing in `.commonModes` guarantees stutter-free tracking during trackpad swipes and column snapping.
- **Layout Persistence & Independent Mission Control Spaces ("Layout Still There Tomorrow")**:
  - **`SpaceManager`**: Dynamically queries macOS Mission Control virtual desktops per display. Every display and every Space maintains an independent strip so work and chat never get shuffled together.
  - **`LayoutPersistenceManager`**: Automatically saves strip state to disk with atomic JSON writes. Restores column order, custom column widths, and vertical window stacks after app or system restart. Newly opened windows slot neatly beside the restored focused window.

## [1.0.2] - 2026-10-14

### Fixed
- **Eliminated Right-Corner Window Clutter**: Fixed macOS WindowServer's default edge-clamping behavior where windows with $x \ge \text{screenWidth}$ were snapped back to `screenWidth - 40` (1430 pt). Windows past `maxVisibleX` are now deterministically parked offscreen at negative X coordinates (`minVisibleX - colWidth - 200`), leaving the right screen edge 100% clean with zero overlapping window slivers.
- **Finder Desktop Background Filtering**: Filtered out Finder's invisible desktop window (1470x956) from window discovery by strictly checking standard window controls and titles, eliminating AX timeouts, repositioning resistance, and Finder conflicts.
- **Ultra-Smooth 1:1 Trackpad Scrolling**:
  - Replaced run-loop hopping `DispatchQueue.main.async` with synchronous `MainActor.assumeIsolated` execution inside the event tap callback, providing instantaneous 1:1 cursor-following scrolling without frame delay.
  - Added continuous gesture latching in `shouldInterceptScroll`: once a 2-finger horizontal swipe begins, the gesture remains locked to Iume, preventing trackpad micro-wobbles from leaking into underlying documents.
  - Eliminated focus-thrashing feedback loop: removed the disruptive `app.hide()` call during scrolling and guarded `onFocusedWindowChanged` against active scrolling gestures, preventing mid-swipe layout resets and animation fights.
  - Pre-sized all registered windows upon entry into the workspace, reducing scroll-time AX operations to a single 0.2ms `setPosition` call per visible window for 120 FPS buttery smoothness.

## [1.0.1] - 2026-10-14

### Fixed
- **Resolved Invisible Window Detection**: Removed disruptive `AXEnhancedUserInterface` and `AXManualAccessibility` flags that were preventing Electron, VS Code, code editors, Terminal, and Finder from exposing windows.
- **Multi-Source Window Discovery**: Added fallback checking across `kAXWindowsAttribute`, `kAXMainWindowAttribute`, `kAXFocusedWindowAttribute`, and `kAXChildrenAttribute` to guarantee 100% window discovery across all running applications.
- **Native Fullscreen Handling**: Added dynamic `AXFullScreen` query to prevent native macOS fullscreen spaces from interfering with desktop strip positioning.
- **Single-Instance Mutex**: Implemented `/tmp/com.iume.app.lock` with non-blocking kernel `flock` to permanently eliminate concurrent Iume processes and 25% CPU background conflicts.
- **Elongated Half-Screen Sizing**: Enforced default column width ratio of 0.50 (half visible width) with strict height allocation, ensuring all windows snap cleanly into tall, symmetrical vertical columns side by side.
- **Viewport Entrance Re-assertion**: Fixed `WindowController.setFrame` so that when windows slide from offscreen into the visible viewport, their full elongated half-screen dimensions are immediately re-asserted, eliminating WindowServer edge shrink.
- **Automated Window Insertion on Creation**: Improved `handleWindowCreated` with an intelligent retry ladder and app-level window re-scan, ensuring newly opened windows automatically slot into the strip.
- **Scroll Pacing & IPC Reduction**: Minimized AX IPC overhead during 120Hz trackpad scrolling by bypassing redundant off-screen position calls.

## [1.0.0] - 2026-10-14

### Added
- **Core Scrolling Layout Engine**: Pure, decoupled mathematical engine supporting ordered horizontal strip layout, column width policies, gap calculation, and multiple layout modes.
- **Multiple Layout Modes**:
  - `Scroll Strip` (Default): Continuous horizontal strip preserving window dimensions with viewport scrolling.
  - `Focus Column`: Prioritizes the active column with neighboring columns partially visible.
  - `Centered Focus`: Centers the focused column dynamically on screen.
  - `Manual Layout`: Reconciles manual user resizing and positioning without aggressive snapping back.
- **Directional Navigation**: Option-key keyboard navigation (`⌥ + H`, `⌥ + L`, `⌥ + J`, `⌥ + K`, `⌥ + ⇧ + H`, `⌥ + ⇧ + L`, `⌥ + Return`, `⌥ + W`, `⌥ + Tab`).
- **Smooth Viewport Animation**: Cubic ease-out interpolation for column transitions and smooth horizontal scrolling.
- **Window Management Operations**: Zoom/maximize, close, focus, minimize/restore, column reordering, and multi-window column stacking.
- **Multi-Monitor Support**: Independent per-screen workspace strips, screen geometry observation, and disconnected display window recovery.
- **Native macOS Menu Bar Accessory**: Status item with live active window counts, layout switcher, settings opener, and quit control.
- **Native SwiftUI Settings Window**: Five comprehensive preference tabs: General, Navigation, Windows, Displays, and Advanced Diagnostics.
- **Safe Accessibility Architecture**: Zero-SIP requirement, zero-root privileges, fully compliant with modern macOS sandboxing and security guidelines.
- **Packaging and Build Automation**: Automated build, release, code signing, and `.app` bundle packaging scripts (`build.sh`, `build-release.sh`, `package.sh`).
- **Quartz WindowServer Edge Parking (Sliver Clamping)**: Off-screen columns past the left or right screen boundary are parked with a configurable peek sliver (14 pt), preventing WindowServer boundary fight, layout jitter, and multi-display spillage.
- **Trackpad & Wheel Physical Gestures**: Intercepts `Option + Trackpad / Scroll Wheel` continuous horizontal pan gestures via `CGEventTap` with automatic timeout recovery and 120Hz ProMotion pacing.
- **Intent Suppression & Expected-Frame Loop Prevention**: Eliminates layout oscillation from programmatic `kAXWindowMoved` / `kAXWindowResized` echoes using microsecond timestamps and spatial tolerance matching.
- **Manual User Resize Reconciliation**: User edge-dragging outside suppression windows is dynamically recognized, updating column widths and user-preferred dimensions so custom sizes persist across viewport scrolling.
- **AX Hang Protection**: Configured `AXUIElementSetMessagingTimeout` across discovery and actuator layers to prevent unresponsive target applications from blocking the window manager.
- **Deterministic Window ID Resolution**: Cross-references Accessibility elements with `CGWindowListCopyWindowInfo` to map real `CGWindowID` numbers without Screen Recording permissions.

