# Iume — Native macOS Scrolling Window Manager

> **A native macOS scrolling window manager bringing the continuous horizontal workflow of Linux's PaperWM and niri to the Mac desktop.**

[![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue.svg)](https://apple.com/macos)
[![Architecture](https://img.shields.io/badge/Architecture-Apple%20Silicon%20(M1--M4)-orange.svg)]()
[![Language](https://img.shields.io/badge/Swift-6.0%2B-FA7343.svg)](https://swift.org)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## The Vision

Every application window lives on **one continuous horizontal strip**. You navigate by scrolling smoothly across your workspace rather than searching through layers of overlapping windows or juggling tiny, arbitrarily shrunk tiles.

- **Horizontal continuity:** Windows live in an ordered, predictable sequence of columns extending infinitely.
- **No arbitrary shrinking:** Opening another application does not suddenly shrink every window on your screen to a fraction of its usable size.
- **Scroll to navigate:** Glide through columns using your trackpad or keyboard shortcuts.
- **Focus follows navigation:** The visible viewport, keyboard focus, and window activation remain seamlessly synchronized.
- **100% Native & Safe:** Built with Swift, AppKit, and SwiftUI. Requires **zero** root privileges, **zero** SIP tampering, and **zero** private undocumented hacks.

---

## Core Features

- **Continuous Strip Tiling:** Columns arrange naturally side-by-side with configurable gaps.
- **Multiple Layout Modes:**
  - `Scroll Strip` *(Default)*: Infinite horizontal sequence with smooth viewport tracking.
  - `Focus Column`: Snaps active column with adjacent columns visible when space permits.
  - `Centered Focus`: Centers the focused column dynamically on screen.
  - `Manual Layout`: Reconciles user manual adjustments without aggressive snapback.
- **Keyboard-Driven Workflow:** Fast directional navigation (`⌥ + H`, `⌥ + L`, `⌥ + J`, `⌥ + K`, `⌥ + Return`, `⌥ + W`, `⌥ + Tab`).
- **Smooth Animations:** Cubic ease-out transitions for fluid, responsive movement.
- **Multi-Monitor Awareness:** Maintains independent workspaces per display, automatically migrating columns if an external monitor is disconnected.
- **Native Menu Bar App:** Operates in the background with a lightweight status icon and quick controls.
- **Native SwiftUI Settings:** Full preferences window for configuring gaps, insertion policies, animations, exclusions, and diagnostics.
- **Privacy First:** 100% offline, local metadata only, zero telemetry.

---

## Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| **`⌥ + H`** | Focus previous window / column |
| **`⌥ + L`** | Focus next window / column |
| **`⌥ + K`** | Focus window above (if stacked) |
| **`⌥ + J`** | Focus window below (if stacked) |
| **`⌥ + ⇧ + H`** | Move column one position left |
| **`⌥ + ⇧ + L`** | Move column one position right |
| **`⌥ + Return`** | Toggle window zoom / maximize |
| **`⌥ + W`** | Close focused window |
| **`⌥ + Tab`** | Cycle through managed windows |
| **`⌥ + ⇧ + Tab`** | Cycle backward through windows |
| **`⌥ + ← / →`** | Scroll horizontal viewport |

---

## Quick Start & Installation

### Option 1: Run the Pre-packaged App Bundle
Download `Iume-macOS.zip` from `dist/` or build it locally:
```bash
./scripts/package.sh
open .build/bundle/Iume.app
```

### Option 2: Build & Run from Source
```bash
# Clone the repository
git clone https://github.com/your-username/Iume.git
cd Iume

# Run the test suite
swift test

# Build debug binary
./scripts/build.sh

# Run Iume
swift run Iume
```

---

## Granting Permissions

On first launch, macOS requires granting **Accessibility permissions** so Iume can position and focus application windows:

1. A system dialog will prompt you to open **System Settings**.
2. Go to **System Settings > Privacy & Security > Accessibility**.
3. Toggle the switch next to **Iume** to **ON**.
4. Iume will immediately begin managing your desktop windows.

---

## Project Architecture

```
Iume/
├── Package.swift               # Swift Package definition (macOS 14+, Swift 6)
├── Resources/
│   └── Info.plist              # Application bundle properties and privacy descriptions
├── Sources/
│   ├── Iume/                   # Executable application entry point (AppKit lifecycle)
│   │   └── main.swift
│   └── IumeCore/               # Core framework library
│       ├── Models/             # WindowId, ManagedWindow, LayoutMode, DisplayGeometry
│       ├── LayoutEngine/       # Pure decoupled mathematical layout calculations
│       ├── Registry/           # In-memory thread-safe window store
│       ├── Permissions/        # Accessibility permission validation
│       ├── Discovery/          # Application & window enumeration
│       ├── Observer/           # AX notification listener & debounce
│       ├── Controller/         # Window manipulation, focus, and scroll animation
│       ├── Display/            # Multi-monitor topology and recovery
│       ├── Shortcuts/          # Carbon global hotkey dispatcher
│       ├── Settings/           # UserDefaults persistent store
│       ├── Diagnostics/        # Structured logging & metrics
│       └── UI/                 # StatusBarController & SwiftUI SettingsView
├── Tests/
│   └── IumeCoreTests/          # Comprehensive unit & integration test suites
├── scripts/
│   ├── build.sh                # Debug build script
│   ├── build-release.sh        # Production release build script
│   └── package.sh              # macOS .app bundle packager with ad-hoc signing
└── docs/                       # Technical reports & guides
    ├── ARCHITECTURE.md         # Detailed subsystem architecture
    ├── FEASIBILITY_REPORT.md   # macOS platform investigation
    ├── PERMISSIONS.md          # Security & privacy guide
    ├── SHORTCUTS.md            # Keyboard navigation reference
    ├── TROUBLESHOOTING.md      # Diagnostics & issue resolution
    └── COMPATIBILITY.md        # macOS version & hardware matrix
```

---

## License

This project is licensed under the permissive **MIT License** — see the [LICENSE](LICENSE) file for details.
