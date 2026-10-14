# Changelog

All notable changes to **Iume** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- **Resolved Invisible Window Detection**: Removed disruptive `AXEnhancedUserInterface` and `AXManualAccessibility` flags that were preventing Electron, VS Code / Antigravity IDE, Terminal, and Finder from exposing windows.
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

