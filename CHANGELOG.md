# Changelog

All notable changes to **Iume** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

