# Iume 📜✨
### *Because macOS thinks "multitasking" means overlapping 47 windows until your fan sounds like a jet engine.*

[![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue.svg)](https://apple.com/macos)
[![Architecture](https://img.shields.io/badge/Architecture-Apple%20Silicon%20%26%20Intel-orange.svg)]()
[![Language](https://img.shields.io/badge/Swift-6.0-FA7343.svg)](https://swift.org)
[![Engine](https://img.shields.io/badge/Rust-Inside%20🦀-dea584.svg)](crates/iume_engine)
[![Release](https://img.shields.io/badge/Release-v2.7.0-8A2BE2.svg)](https://github.com/Bvesroy/Iume/releases/tag/v2.7.0)
[![Vibe](https://img.shields.io/badge/Vibecoded-BvesRoy%20%F0%9F%98%89-ff69b4.svg)]()
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

> Look, we love macOS, but default window management on Mac is an unsolved crime. Stage Manager was an avant-garde art project that nobody asked for, Mission Control turns into an illegible postage-stamp mosaic the moment you open more than five apps, and dragging window borders with a mouse in 2026 is an insult to your trackpad.
>
> Linux nerds have had PaperWM and niri for years while Mac users were paying $20 for utility apps that spontaneously combust whenever Apple tweaks a single Cocoa API.
>
> **Iume** fixes this by giving you one infinite, silky-smooth horizontal strip. Windows line up side-by-side like civilized adults instead of piling on top of each other like laundry on "the chair".

---

## 📦 Downloads & Installation

Grab the latest pre-built binary and stop fighting your desktop:

| Package | Purpose | Direct Download | Verification |
| :--- | :--- | :--- | :--- |
| **Iume-v2.7.0.dmg** | Recommended Drag & Drop Installer | [Download .dmg](https://github.com/Bvesroy/Iume/releases/download/v2.7.0/Iume-v2.7.0.dmg) | [SHA-256](https://github.com/Bvesroy/Iume/releases/download/v2.7.0/Iume-v2.7.0.dmg.sha256) |
| **Iume-v2.7.0.zip** | Standalone .app Archive | [Download .zip](https://github.com/Bvesroy/Iume/releases/download/v2.7.0/Iume-v2.7.0.zip) | [SHA-256](https://github.com/Bvesroy/Iume/releases/download/v2.7.0/Iume-v2.7.0.zip.sha256) |

---

## 🏛️ The Three Pillars (Or: Basic Sanity Restored)

### 1. 🚪 New windows open beside you, not on top of your face
Launch an app, and it politely slots into the strip right next to the window you were just using. It doesn't hijack your entire screen, and it doesn't bury your music player or terminal under four layers of browser windows. Revolutionary concept, we know.

### 2. 🎯 The camera follows your focus without motion sickness
Move focus with keyboard shortcuts or swipe with two fingers. The strip glides smoothly to bring the window into view on a spring animation that starts the exact millisecond you press the key. Zero perceived latency because we actually respect your 120Hz ProMotion display.

### 3. 🧠 Your layout is still there tomorrow
Ever restarted your Mac and spent the first 20 minutes dragging windows back to where they belong? Yeah, never again. Column order, custom widths, vertical stacks, and multi-display setups persist across reboots and sleep cycles.

---

## ⚡ Features (Written for Humans, Not Corporate Marketing)

- 🛑 **Zero Snap-Back Scrolling (New in v2.7.0)**  
  You know that cursed bug where you scroll to inspect a window, let go of the trackpad, and the camera violently snaps back to where you started like an angry rubber band? **Dead. Buried.** In Iume, when you stop scrolling, it *actually stays there*. No recoil, no camera seizures.
- 🗂️ **Chrome-Style Tabs for Any Native App**  
  Got 14 terminal windows or 9 Finder instances cluttering your strip? Press `⌃⌥ + T` to merge them into a single tabbed window. You get a slick 28pt floating tab bar with app icons, live window titles, and reorderable tabs. Drag a tab out to detach it, click `+` to open a new one. Browser convenience, now for your whole OS.
- 📐 **Pixel-Perfect Alignment (Yes, Even Your Weird Terminals)**  
  Terminal emulators (Apple Terminal, Ghostty, Alacritty, Kitty, iTerm2) have character-cell grids that love leaving awkward 3-pixel voids on screen. We spent way too many late nights wrestling AppKit's geometry engine so your borders snap flush with zero gaps and zero clipping.
- 🦀 **Swift 6 + Rust Strip Engine**  
  Swift handles the macOS AppKit lifecycle, while a dependency-free Rust engine (`crates/iume_engine`) does the heavy mathematical lifting for deterministic strip geometry and magnetic seam adherence. Because floating-point rounding errors are not a lifestyle choice.
- ⌨️ **Throw Away Your Mouse (Full Keyboard Navigation)**  
  Directional vim-like navigation with `⌃⌥ + H / J / K / L`. Zoom a window full-width with `⌃⌥ + Return`. Cycle tabs with `⌃⌥ + Tab`. Keep your hands on the keyboard and pretend you're in a 90s cyberpunk movie.
- 🖥️ **Multi-Monitor That Doesn't Lose Its Mind**  
  Independent strips per monitor. Unplugging your external display gracefully migrates your windows instead of dumping them into an existential black hole in the corner of your screen.
- 🕵️ **100% Offline & Anti-Spyware**  
  Zero network calls. Zero telemetry. Zero analytics trackers. We don't want your data, your usage habits, or your crash logs. We have our own bugs to worry about.

---

## ⌨️ Keyboard Shortcuts (The "Throw Away Your Mouse" Cheat Sheet)

All default shortcuts use `Control + Option` (`⌃⌥`). Prefer classic bindings? You can tweak them anytime in **Settings → Shortcuts**.

| Shortcut | What It Does | Why You Care |
| :--- | :--- | :--- |
| **`⌃⌥ + H`** / **`⌃⌥ + ←`** | Focus left window / column | Glide left across the strip |
| **`⌃⌥ + L`** / **`⌃⌥ + →`** | Focus right window / column | Glide right across the strip |
| **`⌃⌥ + K`** / **`⌃⌥ + ↑`** | Focus window above (if stacked) | Climb the vertical stack |
| **`⌃⌥ + J`** / **`⌃⌥ + ↓`** | Focus window below (if stacked) | Descend the vertical stack |
| **`⌃⌥⇧ + H`** / **`⌃⌥⇧ + ←`** | Move column left | Reorder your workspace strip |
| **`⌃⌥⇧ + L`** / **`⌃⌥⇧ + →`** | Move column right | Reorder your workspace strip |
| **`⌃⌥ + Return`** / **`⌃⌥ + F`** | Toggle window zoom / full width | Instant distraction-free focus |
| **`⌃⌥ + W`** | Close focused window | Bye bye, window |
| **`⌃⌥ + Tab`** | Cycle windows or switch tabs | Fast in-group tab switching |
| **`⌃⌥⇧ + Tab`** | Cycle windows / tabs backward | Reverse gear |
| **`⌃⌥ + T`** | Tab same-app windows together | Merges all instances into one tabbed group |
| **`⌃⌥⌘ + T`** | Tab all same-app windows workspace-wide | Instant nuclear declutter |
| **`⌃⌥⌘ + ]`** / **`[`** | Next / previous tab in group | Standard browser tab cycling |
| **`⌃⌥⌘ + N`** | Open a new tab in current app | Spawns fresh window right into the tab bar |
| **`⌃⌥⇧ + W`** | Close only the active tab | Closes current tab without killing the whole column |
| **`⌃⌥⌘ + D`** | Detach active tab into its own column | Pulls the tab out into freedom |
| **`⌃⌥⇧ + U`** | Ungroup all tabs in column | Dissolves the tab group back into columns |
| **`⌃⌥⇧ + P`** | Pin tab bar visible | Keeps the bar open even for single tabs |
| **`⌃⌥⇧ + F`** | Float / unfloat active window | For calculator, PiP, or floating notes |
| **`⌃⌥ + O`** | Toggle Strip Overview | Zoom out and see your entire empire |

*Need more? Check out the full reference in [`docs/SHORTCUTS.md`](docs/SHORTCUTS.md).*

---

## 🗂️ How Tab Groups Work

Tab groups treat several windows of the same app as one browser-like window. Under the hood, windows are never destroyed or frozen: switching tabs parks the inactive window off-screen and brings the chosen one forward. Your scroll position, active input, and video playback stay completely untouched.

- **Group:** Hit `⌃⌥ + T` to merge same-app windows in the current column, or click **Tabs → Group Same-App Windows** in the menu bar.
- **Switch:** Click a tab, hit `⌃⌥⌘ + ]` / `[`, or use `⌃⌥ + Tab` while focused.
- **Add:** Click `+` in the floating tab bar to spawn a fresh window, or pick **Add Existing Window**.
- **Reorder:** Drag tabs left or right with smooth spring physics.
- **Detach:** Drag a tab downward and out of the bar, or hit `⌃⌥⌘ + D`.
- **Motion Vibes:** Customize switch highlights and animations in **Settings → General → Tab Motion & Effects** (Balanced, Crisp, Playful, or Cinematic presets).

---

## 🛠️ Quick Start & Installation

### Option 1: Pre-packaged App Bundle (Fast & Painless)
1. Download **`Iume-v2.7.0.dmg`** from [Releases](https://github.com/Bvesroy/Iume/releases/tag/v2.7.0).
2. Open the `.dmg` and drag **Iume.app** into `/Applications`.
3. Launch Iume. When macOS asks for **Accessibility permissions**, flip the switch ON (details below).
4. Enjoy desktop peace.

### Option 2: Build from Source (For The Hackers)

**Prerequisites:** macOS 14+, Xcode 16+ (Swift 6), and a working [Rust toolchain](https://rustup.rs).

```bash
# Clone the repository
git clone https://github.com/Bvesroy/Iume.git
cd Iume

# Build the Rust engine + debug binary (builds Rust static lib automatically)
./scripts/build.sh

# Run the test suite (413 audit checks, all green)
swift test

# Launch Iume directly
swift run Iume
```

---

## 🔒 Granting Permissions (No, We Aren't Keylogging You)

On first launch, macOS requires granting **Accessibility permissions**. This is required because macOS (rightfully) doesn't let random programs move, resize, or focus your windows without your blessing.

1. A system alert will politely suggest visiting **System Settings**.
2. Go to **System Settings → Privacy & Security → Accessibility**.
3. Toggle the switch next to **Iume** to **ON**.
4. Iume instantly starts organizing your strip. No reboots or terminal voodoo required.

---

## 📐 Project Architecture

```
Iume/
├── Package.swift               # Swift Package definition (macOS 14+, Swift 6)
├── crates/
│   └── iume_engine/            # Rust strip engine (deterministic math, springs & magnetic seams)
├── Resources/
│   └── Info.plist              # Bundle properties & privacy descriptions
├── Sources/
│   ├── CIumeEngine/            # C ABI header bridging Rust engine to Swift
│   ├── Iume/                   # Executable application entry point (AppKit lifecycle)
│   │   └── main.swift
│   └── IumeCore/               # Core framework
│       ├── Models/             # WindowId, ManagedWindow, LayoutMode, DisplayGeometry
│       ├── LayoutEngine/       # Pure decoupled layout math
│       ├── Registry/           # Thread-safe in-memory window registry
│       ├── Permissions/        # Accessibility permission validation & recovery
│       ├── Discovery/          # AX window & app enumeration
│       ├── Observer/           # AX notification observer with debouncing
│       ├── Controller/         # Window movement, focus & spring animation
│       ├── Display/            # Multi-monitor topology and migration
│       ├── Shortcuts/          # Carbon global hotkey dispatcher
│       ├── Settings/           # UserDefaults persistent store
│       ├── Diagnostics/        # Structured logging & metrics
│       └── UI/                 # StatusBarController, HUD & SwiftUI SettingsView
├── Tests/
│   └── IumeCoreTests/          # Unit & integration test suites
├── scripts/
│   ├── build-rust.sh           # Builds universal Rust static library (x86_64 + arm64)
│   ├── build.sh                # Debug build runner
│   ├── build-release.sh        # Production release runner
│   └── package.sh              # Production .app packager with codesigning & DMG generation
└── docs/                       # Comprehensive technical knowledge base
    ├── ARCHITECTURE.md         # Subsystem deep dive
    ├── FEASIBILITY_REPORT.md   # macOS platform internals & AX quirks
    ├── PERMISSIONS.md          # Security & privacy documentation
    ├── SHORTCUTS.md            # Complete keyboard bindings reference
    ├── TROUBLESHOOTING.md      # Diagnostics & triage guide
    └── COMPATIBILITY.md        # macOS version & hardware matrix
```

---

## 👨‍💻 Developer & Credits

- **Author & Architect:** BvesRoy
- **Signature:** Vibecoded by BvesRoy 😉
- **Philosophy:** Software should feel fast, look clean, and stay out of your way.

---

## 📄 License

Distributed under the **MIT License**. See [`LICENSE`](LICENSE) for details. Now go enjoy your wide screen.
