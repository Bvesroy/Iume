# Technical Feasibility & macOS Platform Investigation Report

## Project: Iume — Native macOS Scrolling Window Manager (PaperWM / niri Experience)

### Executive Summary

Linux scrolling window managers like **PaperWM** (GNOME extension) and **niri** (Wayland compositor) operate with complete compositor authority: they control surface allocation, input dispatch, rendering pipelines, and coordinate systems. In contrast, macOS does **not** allow third-party applications to act as native compositors without disabling System Integrity Protection (SIP) or injecting code into WindowServer (as old haxies like mach_inject attempted).

This report investigates the official, supported APIs on modern macOS (macOS 14 Sonoma, macOS 15 Sequoia, and beyond on Apple Silicon) to deliver an authentic, rock-solid, production-quality PaperWM/niri scrolling desktop experience **without** root privileges, SIP disabling, or private undocumented symbols.

---

### 1. API Evaluation & Platform Capabilities

| Capability | macOS API | Permission Required | Feasibility & Behavior |
| :--- | :--- | :--- | :--- |
| **Window Enumeration** | `AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute, ...)` | Accessibility (`AXIsProcessTrusted`) | Fully supported. Discovers all top-level UI windows for running GUI processes. |
| **Window Geometry Inspection** | `AXUIElementCopyAttributeValue(window, kAXPositionAttribute, ...)` & `kAXSizeAttribute` | Accessibility | Fully supported. Returns CGPoint and CGSize in desktop coordinates (top-left origin). |
| **Window Repositioning** | `AXUIElementSetAttributeValue(window, kAXPositionAttribute, axValue)` | Accessibility | Fully supported. macOS allows windows to be placed at coordinates beyond visible screen bounds (e.g. `x = -2000` or `x = 4500`). |
| **Window Resizing** | `AXUIElementSetAttributeValue(window, kAXSizeAttribute, axValue)` | Accessibility | Supported, subject to app-enforced min/max constraints. |
| **Window Focusing** | `AXUIElementSetAttributeValue(window, kAXMainAttribute, kCFBooleanTrue)` + `NSRunningApplication.activate(options: .activateIgnoringOtherApps)` | None extra (AppKit + Accessibility) | Fully supported. Reliably raises window and transfers keyboard input. |
| **Window Event Monitoring** | `AXObserverCreate`, `AXObserverAddNotification` on CFRunLoop | Accessibility | Supported for `kAXWindowCreatedNotification`, `kAXUIElementDestroyedNotification`, `kAXWindowMovedNotification`, `kAXWindowResizedNotification`, `kAXFocusedWindowChangedNotification`. |
| **App Lifecycle Tracking** | `NSWorkspace.didLaunchApplicationNotification`, `NSWorkspace.didTerminateApplicationNotification` | None | Supported natively via Combine / NotificationCenter. |
| **Display Topology & Geometry** | `NSScreen.screens`, `NSScreen.visibleFrame` (accounts for Dock & Menu Bar), `NSApplication.didChangeScreenParametersNotification` | None | Supported natively. Real-time updates when displays are connected, detached, or rotated. |
| **Global Keyboard Shortcuts** | Carbon `RegisterEventHotKey` / `NSEvent.addGlobalMonitorForEvents` | None for `RegisterEventHotKey`; Accessibility/Input Monitoring for CGEventTap | `RegisterEventHotKey` is the gold standard on macOS: zero lag, works system-wide in background, requires no dangerous Input Monitoring permission. |
| **Horizontal Scrolling Input** | `CGEventTapCreate` or `NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel)` | Accessibility / Input Monitoring | Supported for capturing two-finger horizontal trackpad gestures and mouse wheels. |
| **Launch at Login** | `SMAppService.mainApp.register()` (macOS 13+) | None | Modern native ServiceManagement API, user-toggleable in System Settings. |

---

### 2. Architecture Trade-Offs: Custom Viewport vs. Actual Window Movement

Three potential architectures were evaluated:

#### Option A: Virtual Offscreen Desktop / Fake Composite Layer
- *How it works:* Capture windows using ScreenCaptureKit / CGWindowListCreateImage, render them onto a custom scrolling canvas, and redirect clicks.
- *Verdict:* **Rejected.** High latency, extreme GPU/battery drain, broken text selection, broken IME (Input Method Editor), video rendering glitches, and requires permanent Screen Recording permissions.

#### Option B: macOS Spaces Simulation
- *How it works:* Create dozens of native Spaces and programmatically switch between them.
- *Verdict:* **Rejected.** macOS provides no public API to create, reorder, or instantly scroll through Spaces without slow Mission Control animations.

#### Option C: Physical Desktop Coordinate Translation (The PaperWM Model)
- *How it works:*
  - All managed windows in a workspace live on an ordered horizontal strip: `Col 0, Col 1, Col 2, ...`
  - Each column has a width and an assigned X-offset in the infinite strip space.
  - The visible screen acts as a "camera" or "viewport" positioned at `viewportOffset.x`.
  - The actual physical screen position of any window $i$ is calculated as:
    $$\text{ScreenX}_i = \text{DisplayVisibleOrigin.x} + \text{StripX}_i - \text{ViewportOffset.x}$$
  - When the user scrolls horizontally or presses navigation hotkeys (e.g., `Option+H` / `Option+L`), the Layout Engine updates `ViewportOffset.x` with smooth animation, repositioning the physical windows.
  - Windows scrolled out of view rest comfortably to the left or right offscreen in the desktop coordinates space.
- *Verdict:* **Adopted.** This is 100% compliant with standard macOS Accessibility, provides true zero-lag native input, crisp text rendering, flawless multi-monitor support, and zero battery overhead when idle.

---

### 3. Window Types Classification & Management Policies

Not every window on macOS should be placed in a horizontal tiling strip. Attempting to force utility dialogs into columns causes layout chaos. We establish strict classifications:

| Category | Examples | Layout Engine Action |
| :--- | :--- | :--- |
| **Standard Tiled Windows** | Safari, Xcode, Terminal, Notes, VS Code, Finder main windows | **Managed in Columns**. Positioned, moved, and resized according to active layout mode. |
| **Modal & System Dialogs** | File Open/Save dialogs, print sheets, permission alerts | **Floating (Ignored by Strip)**. Allowed to float above parent window without breaking column strip. |
| **Popovers & Menus** | Autocomplete popups, contextual menus, tooltips | **Ignored**. Filtered out via `kAXWindowSubrole != kAXStandardWindowSubrole`. |
| **Floating Utility Palettes** | Photoshop color pickers, Xcode inspectors, 1Password mini | **Floating**. User-configurable via application denylist or window role rules. |
| **Native Full-Screen Apps** | Apps in macOS native full-screen space | **Excluded**. Ignored while in full-screen space; recovered when returned to normal desktop. |
| **Inaccessible / Custom Windows** | Certain Java/Electron games or DRM windows lacking AX attributes | **Safe Fallback**. Detected, logged gracefully, and left untouched rather than crashing or oscillating. |

---

### 4. Critical macOS Limitations & Robust Solutions

1. **Accessibility Notification Feedback Loops:**
   - *Issue:* When Iume moves a window to scroll the viewport, macOS emits `kAXWindowMovedNotification`. If treated as a manual user drag, the engine might re-compute layouts in an infinite cycle.
   - *Solution:* An atomic lock flag `isProgrammaticUpdate` and coordinate caching ensure programmatic moves are immediately recognized and suppressed from triggering re-layouts.

2. **Window Minimum/Maximum Size Constraints:**
   - *Issue:* Some applications (e.g. System Settings, Calculator) enforce a fixed or minimum window size and reject smaller `kAXSizeAttribute` requests.
   - *Solution:* Read back the actual window size after applying layout, adapt the column width to the app's enforced minimum, and maintain seamless adjacent gaps.

3. **Multi-Display Edge Cases:**
   - *Issue:* Moving a window to coordinates completely disconnected from any active screen can cause macOS to snap the window back or lose track of it if a monitor is unplugged.
   - *Solution:* `DisplayManager` maintains independent strips per active display. If a monitor is unplugged, all its windows are safely migrated to the primary display's strip.

4. **Multi-Spaces Behavior:**
   - *Issue:* macOS does not provide a public API to move a window across Spaces.
   - *Solution:* Windows on inactive Spaces are detected via CGWindowList offscreen flags and preserved in their column positions until their Space becomes active again.

---

### 5. Architectural Blueprint

The implementation is partitioned into decoupled components:
- **`LayoutEngine`**: Pure mathematical calculations for column packing, gaps, strip boundaries, and target rects. 100% unit-tested without AppKit dependencies.
- **`WindowRegistry` & `WindowDiscovery`**: Fast in-memory state tracking of managed windows with stable identity hashes.
- **`WindowObserver`**: Event-driven notification listener with debounced updates.
- **`ScrollController`**: Viewport physics, smooth animation easing (ease-out cubic / display link), and snapping.
- **`FocusManager`**: Bidirectional focus synchronization between active column and macOS keyboard focus.
- **`DisplayManager`**: Topology observer and per-screen workspace organizer.
- **`ShortcutManager`**: Carbon global hotkey dispatch with customizable keybindings.
- **`SettingsStore` & `SettingsUI`**: Native SwiftUI settings interface with persistence via `UserDefaults`.
- **`Menu Bar`**: Lightweight status item for instant control and visual status.
