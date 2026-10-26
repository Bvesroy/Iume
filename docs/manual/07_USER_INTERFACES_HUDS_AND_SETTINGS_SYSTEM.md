# Module 07: User Interfaces, HUDs & Settings System

## 1. Overview of the UI Architecture

Iume features a user interface layer built on **SwiftUI** embedded within **AppKit** (`NSHostingView` / `NSWindow`). Rather than intrusive modal dialogs, Iume employs non-activating HUD panels (`NSWindow.Level.floating`, `canBecomeKey = false`) that provide real-time visual feedback without stealing keyboard focus from active terminal sessions or text editors.

```
+─────────────────────────────────────────────────────────────────────────────────────────+
|                                  USER INTERFACE ARCHITECTURE                            |
+─────────────────────────────────────────────────────────────────────────────────────────+
        │                                  │                                  │
        ▼                                  ▼                                  ▼
+──────────────────────────+   +──────────────────────────+   +──────────────────────────+
|  StatusBarController     |   |  LaunchHUDController     |   |  MinimapHUDController    |
|  • System Menu Bar Item  |   |  • Floating Kickstart UI |   |  • 7 Visual HUD Styles   |
|  • Layout Switcher Menu  |   |  • Live Physics Controls |   |  • Circular Dial & Strip |
|  • Quick Toggles         |   |  • Column Width Presets  |   |  • Screen Edge Rails     |
+──────────────────────────+   +──────────────────────────+   +──────────────────────────+
        │                                  │                                  │
        └──────────────────────────────────┼──────────────────────────────────┘
                                           ▼
+─────────────────────────────────────────────────────────────────────────────────────────+
|                                    SettingsView (SwiftUI)                               |
|   8 Dedicated Panes: General · Appearance · Layout · Scrolling · Box · Rules · Shortcuts|
+─────────────────────────────────────────────────────────────────────────────────────────+
```

---

## 2. Launch & Kickstart HUD (`LaunchHUDController`)

The **Launch HUD** ([`LaunchHUDController.swift`](file:///Users/bves/projects/Iume/Sources/IumeCore/UI/LaunchHUDController.swift)) serves as the primary operational dashboard for Iume.

### Key Features:
1. **The Primary Kickstart Button**:
   - Single-click action that initializes workspaces, verifies Accessibility permissions, dispatches window discovery, and snaps all open desktop windows into a continuous linear strip.
   - Enforces full activation of all 5 scrolling physics dimensions:
     ```swift
     settings.freezeOnRelease = false
     settings.inertialScrolling = true
     settings.momentumScrolling = true
     settings.smoothScrollingEnabled = true
     ```
2. **Scrolling Dynamics & Physics Card**:
   - Live interactive toggles for **Inertial Scrolling** and **Smooth Scrolling**.
   - **Momentum Multiplier Slider**: Adjusts velocity release projection from $0.5\times$ to $2.5\times$.
   - **Deceleration / Friction Slider**: Fine-grained decay factor adjustment ($0.880$ to $0.995$) with one-click presets:
     - `Snappy (0.910)` — Quick, crisp stop.
     - `Natural (0.965)` — Standard macOS trackpad glide.
     - `Slick (0.985)` — Extended, low-friction coast.
   - **Kinetic Profile Segmented Control**: Instant switching between `.natural`, `.viscous`, `.highInertia`, and `.snappy`.
3. **Column Width Presets**:
   - Rapidly reconfigures active column width: `50% Symmetrical`, `60% Focus`, `75% Wide`, or `100% Full Screen`.
4. **Stop & Restore Action**:
   - Restores all windows back to their original pre-tiled positions and floating geometries.

---

## 3. The Multi-Instrument Minimap HUD System (`MinimapHUDController`)

Iume features a multi-mode heads-up navigation display ([`MinimapHUDController.swift`](file:///Users/bves/projects/Iume/Sources/IumeCore/UI/MinimapHUDController.swift)) that visualizes the user's position along the infinite strip:

### 3.1 The 7 Visual Instrument Styles

| Style Name | Implementation View | Description & Visual Treatment |
| :--- | :--- | :--- |
| **Circular Dial** | [`MinimapHUDView`](file:///Users/bves/projects/Iume/Sources/IumeCore/UI/MinimapHUDView.swift) | Aviation-style altimeter dial with rotating needle, tick marks, and colored window pips representing column locations. |
| **Linear Strip** | [`MinimapLinearView`](file:///Users/bves/projects/Iume/Sources/IumeCore/UI/MinimapLinearView.swift) | Ultra-compact horizontal bar indicating the visible viewport camera aperture relative to total strip length. |
| **Loop Carousel** | [`MinimapLoopCarouselView`](file:///Users/bves/projects/Iume/Sources/IumeCore/UI/MinimapLoopCarouselView.swift) | 3D pseudo-cylindrical carousel rendering columns on a rotating cylinder; ideal for circular Loop Mode. |
| **Horizon Ellipse** | [`MinimapHorizonEllipseView`](file:///Users/bves/projects/Iume/Sources/IumeCore/UI/MinimapHorizonEllipseView.swift) | Curved radar horizon arc displaying column azimuths and distance from current focus. |
| **Ticker Tape** | [`MinimapTapeView`](file:///Users/bves/projects/Iume/Sources/IumeCore/UI/MinimapTapeView.swift) | High-precision numeric tape ruler displaying exact point coordinates and column boundaries. |
| **Spectrum Band** | [`MinimapSpectrumView`](file:///Users/bves/projects/Iume/Sources/IumeCore/UI/MinimapSpectrumView.swift) | Vibrant multi-color spectrum where each application class is assigned a unique spectral hue. |
| **Timeline** | [`MinimapTimelineView`](file:///Users/bves/projects/Iume/Sources/IumeCore/UI/MinimapTimelineView.swift) | Chronological track visualizing recent window activations and navigation history. |

### 3.2 Screen Edge Rails (`MinimapEdgeRailView`)
Subtle translucent glowing edge indicators rendered at the left and right borders of the monitor. When windows are parked off-screen, the rail renders glowing tick marks indicating how many windows reside in each direction.

---

## 4. The 8-Pane Native Settings Suite (`SettingsView`)

The preferences window ([`SettingsView.swift`](file:///Users/bves/projects/Iume/Sources/IumeCore/UI/SettingsView.swift)) follows standard macOS System Settings design conventions with a searchable sidebar:

1. **General**: Launch at login (`SMAppService`), UI animations toggle, window gaps ($0\text{ pt}$ to $64\text{ pt}$), outer margins, and smart margin collapse.
2. **Appearance**: Minimap instrument selector, dial geometry, auto-hide delay, HUD opacity, and audio sound cues toggle.
3. **Layout & Strip**: Layout mode selector (Strip, Focus, Centered, Manual), insertion policies (`afterFocused`, `atEnd`, `beforeFocused`), off-screen peek sliver width, and Loop Mode toggle.
4. **Scrolling & Physics**: Full kinetic parameter editor (inertial toggle, smooth filter, friction factor, velocity multiplier, and profile descriptions).
5. **Box Tiling & Snapping**: Magnetic adhesion radius, seam-ratio quantization toggles, and adaptive grid ratios.
6. **Application Rules**: Comprehensive per-app policy editor (`alwaysTile`, `alwaysFloat`, `fixedSlot`) with running apps picker and live re-evaluation.
7. **Shortcuts**: Interactive shortcut manager with live keystroke recorder, conflict detection, and individual action reset buttons.
8. **Diagnostics & Setup**: System compatibility verification, TCC Accessibility repair actions, and display configuration status.

---

## 5. Procedural Audio Engine (`HudSoundEngine`)

To provide tactile haptic feedback without requiring physical trackpad actuation, Iume synthesizes low-latency procedural audio cues via `AudioToolbox` / CoreAudio:
- **Loop Seam Tick (`playLoopTick`)**: A gentle, organic wooden acoustic tick triggered whenever the viewport completes a full $360^\circ$ lap in Loop Mode.
- **Magnetic Snap Cue (`playSnapSound`)**: A subtle metallic click when a dragged window adheres to an adjacent edge.
- **Tab Switch Haptic (`playTabSwitchSound`)**: A soft click when cycling between stacked tabs.
