# Iume — Native macOS Scrolling Window Manager

> **A native macOS scrolling window manager bringing the continuous horizontal workflow of Linux's PaperWM and niri to the Mac desktop.**

[![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue.svg)](https://apple.com/macos)
[![Architecture](https://img.shields.io/badge/Architecture-Apple%20Silicon%20(M1--M4)-orange.svg)]()
[![Language](https://img.shields.io/badge/Swift-6.0%2B-FA7343.svg)](https://swift.org)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## The Three Pillars

### 1. New windows open beside the focused one
Launch an app and its window slots in right next to the one you were using. Nothing overlaps and nothing gets lost behind another window, because every window has its own place on the strip.

### 2. The strip follows your focus
Move focus from the keyboard or swipe the trackpad. The strip scrolls just far enough to bring the window into view, on a spring animation that starts the moment you press the key.

### 3. Your layout is still there tomorrow
Column order, widths and stacks come back after a restart. Every display and every Space keeps a strip of its own, so work and chat never get shuffled together.

---

## Core Features

- **Continuous Strip Tiling:** Columns arrange naturally side-by-side with configurable gaps and half-screen elongated tiling.
- **Physical Spring Physics Animation:** Damped harmonic oscillator that starts synchronously on keypress for zero perceived latency.
- **Independent Space & Display Strips:** Dynamic Mission Control Space tracking keeps work and chat completely isolated on their own strips.
- **Automatic Layout Persistence:** Atomic state serialization automatically saves column order, custom widths, and vertical stacks to survive restarts.
- **Multiple Layout Modes:**
  - `Scroll Strip` *(Default)*: Infinite horizontal sequence with minimal viewport tracking.
  - `Focus Column`: Snaps active column with adjacent columns visible when space permits.
  - `Centered Focus`: Centers the focused column dynamically on screen.
  - `Manual Layout`: Reconciles user manual adjustments without aggressive snapback.
- **Chrome-Style Tab Groups:** Merge same-app windows into one tabbed window. Click a tab to switch instantly without reloading, drag to reorder, drag out to detach, and `+` to add a window. Live titles, app icons and per-tab close buttons keep browser-style workflows intact.
- **Keyboard-Driven Workflow:** Directional navigation (`⌃⌥ + H`, `⌃⌥ + L`, `⌃⌥ + J`, `⌃⌥ + K`, `⌃⌥ + Return`, `⌃⌥ + W`, `⌃⌥ + Tab`).
- **Interactive 2-Finger Trackpad Swiping:** Direct 1:1 strip gliding that freezes exactly at finger lift (optional inertia and spring snap).
- **Multi-Monitor Awareness:** Maintains independent strips per display with automatic migration upon disconnect.
- **Native Menu Bar App:** Lightweight status icon, Launch & Kickstart control panel, and full SwiftUI settings.
- **Privacy First:** 100% offline, local metadata only, zero telemetry.

---

## Keyboard Shortcuts

All default shortcuts use `Control + Option` (`⌃⌥`). Option-only legacy bindings can be re-enabled in **Settings → Shortcuts**.

| Shortcut | Action |
| :--- | :--- |
| **`⌃⌥ + H`** / **`⌃⌥ + ←`** | Focus previous window / column |
| **`⌃⌥ + L`** / **`⌃⌥ + →`** | Focus next window / column |
| **`⌃⌥ + K`** / **`⌃⌥ + ↑`** | Focus window above (if stacked) |
| **`⌃⌥ + J`** / **`⌃⌥ + ↓`** | Focus window below (if stacked) |
| **`⌃⌥⇧ + H`** / **`⌃⌥⇧ + ←`** | Move column one position left |
| **`⌃⌥⇧ + L`** / **`⌃⌥⇧ + →`** | Move column one position right |
| **`⌃⌥ + Return`** / **`⌃⌥ + F`** | Toggle window zoom / full width |
| **`⌃⌥ + W`** | Close focused window |
| **`⌃⌥ + Tab`** | Cycle windows — or switch tabs inside a tab group |
| **`⌃⌥⇧ + Tab`** | Cycle backward — or switch tabs backward |
| **`⌃⌥⇧ + T`** | Toggle tab strip vs. vertical stack |
| **`⌃⌥ + T`** | Tab same-app windows together |
| **`⌃⌥⌘ + T`** | Tab all same-app windows in the workspace |
| **`⌃⌥⌘ + ]`** / **`⌃⌥⌘ + [`** | Next / previous tab in the focused group |
| **`⌃⌥⌘ + N`** | Open a new tab (new window of the current app) |
| **`⌃⌥⇧ + W`** | Close only the active tab |
| **`⌃⌥⌘ + D`** | Detach the active tab into its own column |
| **`⌃⌥⇧ + U`** | Ungroup all tabs in the focused column |
| **`⌃⌥⇧ + P`** | Keep the tab bar visible (pin) |
| **`⌃⌥⇧ + F`** | Float / unfloat the active window |
| **`⌃⌥ + O`** | Toggle the Strip Overview |

See [`docs/SHORTCUTS.md`](docs/SHORTCUTS.md) for the full reference, including workspaces, displays and window-width controls.

---

## Tab Groups

Tab groups treat several windows of the same app as one browser-like window. The underlying windows are never destroyed: switching a tab parks the previous window off-screen and brings the new one forward, so scroll position, editor state and media playback survive.

- **Create:** press `⌃⌥ + T` to merge same-app windows in the focused column, `⌃⌥⌘ + T` to group every app on the workspace, or use **Tabs → Group Same-App Windows** in the menu bar.
- **Switch:** click a tab, press `⌃⌥⌘ + ]` / `[`, or use `⌃⌥ + Tab` while the group is focused.
- **Add:** click `+` in the strip to spawn a fresh window, or choose **Add Existing Window** to pull in another same-app window from the strip.
- **Reorder:** drag any tab left or right; the strip spring-animates and the active tab keeps its identity.
- **Detach:** drag a tab down and out of the strip, or press `⌃⌥⌘ + D`, to restore it as an independent column.
- **Motion:** pick the switch highlight and open/close effect in **Settings → General → Tab Motion & Effects**. Choose from Balanced, Crisp, Playful or Cinematic presets, fine-tune speed, and optionally enable trackpad haptics. System Reduce Motion is always respected.
- **Close:** the per-tab `x` (or `⌃⌥⇧ + W`) closes only that window. When one tab remains the group collapses back to a normal column, unless the bar is pinned with `⌃⌥⇧ + P`.
- **Visibility:** the bar appears automatically for multi-tab groups and reserves its own 28pt band, so it never covers app content or scrollbars. Pinning keeps it visible for single-window groups.

Same-app windows are tabbed automatically on first launch (`autoTabSameAppWindows`); ungrouped windows and other apps stay as independent columns.

---

## Quick Start & Installation

### Option 1: Run the Pre-packaged App Bundle
Download `Iume-macOS.zip` from `dist/` or build it locally:
```bash
# Build, sign and verify the app bundle plus dist/Iume-macOS.zip
./scripts/package.sh --package-only

open .build/bundle/Iume.app
```

`package.sh` takes the release version from the top `## [x.y.z]` heading in `CHANGELOG.md`, stamps it (and a build number) into the bundle's `Info.plist`, then verifies the signature, the reported version and the binary's linkage for both the bundle and the extracted archive. Unzip `dist/Iume-macOS.zip` and check it against `dist/Iume-macOS.zip.sha256` before distributing.

Options: `--package-only` skips installing into `/Applications` and the MEGA backup; `--no-install` skips only the install/launch; `--no-backup` skips only the rsync backup. Without a Developer ID in the login keychain the app is signed ad-hoc — fine locally, but Gatekeeper will block it on other Macs, so distribution needs a Developer ID and notarization.

### Option 2: Build & Run from Source

**Prerequisites:** macOS 14+, Xcode 16+ (Swift 6), and the [Rust toolchain](https://rustup.rs) — the strip layout, spring physics and magnetic adhesion math live in `crates/iume_engine` and are linked into `IumeCore` as a static library.

```bash
# Clone the repository
git clone https://github.com/your-username/Iume.git
cd Iume

# Build the Rust engine + debug binary (runs cargo for you)
./scripts/build.sh

# Run the test suite
swift test

# Run Iume
swift run Iume
```

The Swift build scripts call `scripts/build-rust.sh` first, so you never need to invoke `cargo` yourself. If you build with plain `swift build`, run `./scripts/build-rust.sh` at least once beforehand.

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
├── crates/
│   └── iume_engine/            # Rust strip engine (layout, viewport, spring, magnetic)
├── Resources/
│   └── Info.plist              # Application bundle properties and privacy descriptions
├── Sources/
│   ├── CIumeEngine/            # C header exposing the Rust engine ABI
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
│   ├── build-rust.sh           # Builds the Rust engine static library
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

## Developer & Credits

- **Developer:** BvesRoy
- **Signature:** Vibecoded by BvesRoy 😉

---

## License

This project is licensed under the permissive **MIT License** — see the [LICENSE](LICENSE) file for details.
