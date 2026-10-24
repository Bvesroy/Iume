# Iume — Feature Inventory & Marketing Video Brief

**Product:** Iume
**Version:** 2.6.0
**Platform:** macOS 14.0+ · Apple Silicon (arm64)
**Type:** Menu-bar app (`LSUIElement`), no Dock icon
**License:** MIT
**Build:** Swift 6 + Rust strip engine
**Repo:** `/Users/bves/projects/Iume`

---

## 0. One-Line Snapshot

> Iume turns your desktop into one continuous, horizontally scrolling strip of windows — like PaperWM or niri, but native on macOS.

No grid. No overlapping pile. No window hunting. Every window has a place, and the desktop slides to it.

---

## 1. Positioning

### 1.1 The problem you're selling against
macOS window management is a pinboard: windows stack on top of each other, get buried, and you spend the day Cmd-Tabbing and dragging things around. Grid tiling (Rectangle, Magnet, Amethyst) fixes the overlap but creates a new problem — a fixed grid fills up, then starts shrinking windows or refuses new ones.

### 1.2 The Iume idea
Your desktop is a **timeline, not a pinboard**.

Windows live side-by-side on an endless horizontal strip. Nothing overlaps, nothing gets hidden, and the strip scrolls to whatever you're focused on. When you run out of screen, the desktop doesn't run out of room — it just keeps going.

### 1.3 Pitch options

| Length | Line |
| :--- | :--- |
| 6 words | Your windows, on a rail. |
| 1 sentence | A native macOS window manager that turns your desktop into one endless, sliding strip. |
| 2 sentences | Iume puts every window side-by-side on a continuous horizontal strip — no overlap, no grid, no lost windows. Swipe the trackpad and the whole desktop glides to what you need. |
| Technical | Native macOS continuous-strip tiling with a Rust layout engine, 120 Hz spring physics, magnetic adhesion, and per-display/per-Space workspace strips. |

### 1.4 Audience segments

| Segment | What they care about | Lead feature |
| :--- | :--- | :--- |
| Developers / terminal-heavy | Many windows, keyboard flow, no mouse | Strip + `⌃⌥` chords + stacks |
| Designers / researchers | Visual comparison, lots of references | Side-by-side columns + width presets |
| Laptop + external monitor users | Displays, Spaces, continuity | Per-display strips + send-to-display |
| Linux tiling converts (niri/PaperWM/sway) | They already want this | "The macOS niri" angle |
| Productivity / "desk setup" audience | Aesthetics, smoothness, HUDs | 120 Hz glass scrolling + minimap |
| Window-manager power users | Rules, floats, recovery, no lock-in | Rules, stop/restore, Mac Setup checker |

---

## 2. Hero Features — The Video Spine

These are the eight that carry a trailer. Each has a what / why / proof / shot.

### HERO 1 — The Infinite Horizontal Strip
**What:** Every window becomes a tall, half-screen column on one continuous horizontal rail. Columns never overlap; off-screen windows stay parked and invisible until the strip scrolls to them.
**Why it sells:** This is the whole product in one visual. A single drag or keypress shows a desktop that keeps going.
**Proof:** `LayoutEngine`, Rust `layout`/`viewport` modules; offscreen parking with SkyLight alpha fade so windows never clamp or stack at the screen edge.
**Shot:** Start on one window. Swipe right — three, four, six columns glide past. Pull back to a minimap of the whole strip.

### HERO 2 — New Windows Open Beside You
**What:** Launch an app and its window slots in immediately to the right of your focused column, not at the end of the strip. It gets focused, and the strip scrolls just enough to reveal it.
**Why it sells:** This is the "it just knows" moment. It kills the Cmd-Tab → hunt → drag loop.
**Proof:** `InsertionPolicy.afterFocused`, `handleWindowCreated` with a retry ladder up to 10s for Electron/VS Code/Xcode/browser windows, 2s anti-focus-steal window for background popups.
**Shot:** Split screen: left, you're typing in an editor; right, you hit a launcher and a browser appears *next to the editor*, already focused, no overlap.

### HERO 3 — Trackpad-Native Glass Scrolling
**What:** Two-finger horizontal scroll moves the strip 1:1 with your fingers. Optional three- and four-finger swipes move it without any modifier. Lifting your fingers hands momentum into a spring that settles exactly on a column.
**Why it sells:** Feels like the desktop is made of glass. This is the "whoa" in a 10-second clip.
**Proof:** `CGEventTap` + `MultitouchSupport.framework`, `CADisplayLink` at 80–120 Hz, analytical harmonic spring, velocity carried through settle, gesture ownership latched to the strip so momentum never leaks into documents.
**Shot:** Overhead trackpad shot + screen capture side by side, fingers moving, columns tracking frame-for-frame. Slow to 50% for the settle.

### HERO 4 — Magnetic Windows
**What:** Drag a window near its neighbor and it snaps flush. Keep dragging and the neighbor travels with it, like chained links. Resize an edge and it snaps to clean splits: 25 / 33.3 / 50 / 66.7 / 75%.
**Why it sells:** Devs understand "magnetic" instantly. It looks like physics, not snapping.
**Proof:** `MagneticWindowEngine` — 32pt attraction radius, 18pt seam radius, chained neighbor frames, zero-flicker drag lockout, 120 Hz spring settle on mouse-up.
**Shot:** Cursor drags one window toward another; both slide together and land flush with a soft settle. Add a slow-motion beat on the snap.

### HERO 5 — Columns, Stacks & Tabs
**What:** A column can hold multiple windows two ways. **Stacked:** split vertically with draggable heights. **Tabbed:** full height with a 28pt floating tab bar above the column, clickable icons and titles.
**Why it sells:** It answers "what if I have five terminals?" without giving up the strip.
**Proof:** `ColumnPresentationMode`, `TabBarOverlayController` (`NSPanel`), stack height nudge/equalize commands, 200pt minimum clamp.
**Shot:** Three terminals stacked in one column, then `⌃⌥⇧T` flips to tabs — the tab bar pops in and you click between them.

### HERO 6 — Displays, Spaces & Virtual Workspaces
**What:** Every physical display gets its own strip. Every Mission Control Space gets its own strip. On top of that, each display gets **nine virtual workspaces**. Move a column to the next display with proportional width scaling. Throw a window to the left or right Space.
**Why it sells:** It's the "this scales with my setup" proof — laptop + monitor, work vs. chat.
**Proof:** `WorkspaceKey(displayId, spaceId, workspaceIndex 1...9)`, `sendFocusedColumnToNextDisplay` proportional scaling, `throwFocusedWindowToSpace`, display hot-plug recovery.
**Shot:** Timelapse: laptop alone → monitor plugged in → second strip appears → send a window across → unplug → window recovers on the laptop.

### HERO 7 — The HUDs (Minimap, Launch Control, Focus Ring)
**What:** A floating translucent **minimap** shows the whole strip and where the viewport sits while you scroll. A **Slide Launch Control** panel gives you Kickstart, Stop & Restore, column-width presets, gap presets, and a live window list. An optional **focus border** outlines the active window.
**Why it sells:** Pure production value. These are the shots that make a screen recording look designed.
**Proof:** `MinimapHUDController` (throttled subpixel updates), `LaunchHUDController`, `FocusBorderOverlay` (animated ease-out), `DimmingOverlayController`.
**Shot:** Scroll fast with the minimap visible; the little viewport tracker slides across the strip. Cut to the Launch Control panel with its gradient buttons.

### HERO 8 — Non-Destructive by Design
**What:** **Kickstart** tiles everything. **Stop & Restore** puts every window back exactly where it was before Iume touched it — geometry captured at discovery. Quit, SIGTERM, or disabling management all restore. Layouts persist across restarts.
**Why it sells:** Removes the #1 objection: "will this mess up my desktop?"
**Proof:** `initialFrame` retained per window, `restoreAllWindowFrames()` with on-screen bounds guards, atomic JSON `LayoutPersistenceManager`.
**Shot:** Before/after toggle. Messy desktop → Kickstart → strip → Stop & Restore → the exact original mess, pixel for pixel. End on the "nothing is permanent" line.

---

## 3. Complete Feature Inventory

### 3.1 Layout & Tiling

| Feature | What it actually does | Marketing angle |
| :--- | :--- | :--- |
| Continuous strip tiling | Ordered horizontal columns, no overlap, viewport scroll | "The rail" |
| Four layout modes | Scroll Strip, Focus Column, Centered Focus, Manual Layout | "Works the way you think" |
| Apps Edge Together | Zero-gap mode: columns sit flush, wallpaper never shows between them | "One pane of glass" |
| Configurable inner gap | 0 / 4 / 8 / 12 / 16 pt presets plus free slider | "Tune the rhythm" |
| Independent outer margins | Top, bottom, left, right, down to 0 px | "Pixel-perfect framing" |
| Smart margins | Margins collapse to 0 when only one column is on screen | "Full screen when it's just you" |
| Built-in display exemption | Zero margins on the MacBook panel, generous margins on externals | "Laptop-tight, monitor-roomy" |
| Default column width ratio | Default 50% half-screen; presets 25 / 33 / 50 / 60 / 66 / 75 / 100% | "Half-screen by default, yours to change" |
| Half-screen elongated sizing | Tall symmetrical columns by default | Looks like a designed system, not a grid |
| Center modes | `never`, `onOverflow`, `always` | "Center only when you want it" |
| Full-width column | `⌃⌥F` or `⌃⌥Return` maximizes one column | "One thing, full attention" |
| Manual layout mode | Honors your own resize/position without snapback | "Iume doesn't fight you" |
| Per-column custom widths | Resize the seam; width is remembered | "Every column earns its size" |

### 3.2 Navigation & Input

| Feature | What it actually does | Marketing angle |
| :--- | :--- | :--- |
| Directional focus | `⌃⌥←/→/↑/↓` and `⌃⌥H/J/K/L` move focus between columns and stacked windows | "Vim hands, Mac desktop" |
| Move columns | `⌃⌥⇧←/→` and `⌃⌥⇧H/L` reorder columns | "Rearrange the story" |
| Window cycling | `⌃⌥Tab` / `⌃⌥⇧Tab` cycle managed windows | "Never lose a window" |
| First / last column | `⌃⌥⌘←` / `⌃⌥⌘→` jump to strip ends | "Teleport to the edge" |
| Viewport scroll keys | `⌃⌥` + scroll bindings move the strip without changing focus | "Look ahead" |
| 2-finger scroll modes | Seamless Horizontal (smart), Option-gated, Control-gated, Always | "Your gestures, your rules" |
| 3- and 4-finger swipes | Modifier-free strip movement via `MultitouchSupport` | The signature gesture |
| Momentum coasting | Inertial fling with elastic boundary resistance | "Flick the desktop" |
| Scroll sensitivity | Adjustable multiplier | Accessibility + taste |
| Natural scroll direction | Honors macOS natural scrolling | No relearning |
| Gesture latching | Once a horizontal swipe starts, it stays with Iume until it ends | No accidental document scrolling |
| Drag titlebar to reorder | Drag a window's titlebar and drop it elsewhere on the strip | Direct manipulation |
| Focus follows mouse | Optional hover-to-focus with 120 ms hysteresis | "Amethyst users feel at home" |
| Mouse follows focus | Cursor warps to the newly focused window | Keyboard-only workflow |
| Legacy ⌥ shortcut set | Optional `⌥H/J/K/L` fallbacks for muscle memory | Migration path from other managers |
| International keymap support | `UCKeyTranslate` for AZERTY, QWERTZ, Dvorak | "Works on your keyboard" |

### 3.3 Column & Window Management

| Feature | What it actually does | Marketing angle |
| :--- | :--- | :--- |
| Width cycling | `⌃⌥R` forward, `⌃⌥⇧R` backward through 25→33→50→66→75→100% | "One key, six sizes" |
| Width nudging | `⌃⌥-` / `⌃⌥=` in ±5% steps | "Dial it in" |
| Center column | `⌃⌥C` centers the active column | "Put it in the spotlight" |
| Pull / stack into column | `⌃⌥[` / `⌃⌥]` pulls a window into the left/right neighbor column | "Combine related work" |
| Pop / unstack | `⌃⌥⇧[` / `⌃⌥⇧]` returns a window to its own column | "Split it back out" |
| Stacked vs tabbed | `⌃⌥⇧T` flips a column between vertical split and tabs | "Two ways to multitask" |
| Stack height nudging | `⌃⌥⇧=` / `⌃⌥⇧-` grow or shrink the focused stack pane | "Give the important one room" |
| Equalize stack heights | `⌃⌥0` resets a stack to even splits | "Tidy in one key" |
| Tab bar overlay | 28pt floating tab strip with live icons and titles, click to switch | Very strong b-roll |
| Live edge resizing | Drag a seam; the adjacent column absorbs the delta in real time, no gap or overlap | "The wall moves with you" |
| Magnetic seam snapping | 18pt capture radius on 25/33/50/66/75% splits | Tactile feel |
| Zoom / close | `⌃⌥Return` and `⌃⌥W` | Completeness |
| Smart floating | Non-resizable windows (Calculator, inspectors, fixed dialogs) float above the strip automatically | "It knows what shouldn't tile" |
| Small-window threshold | Windows under 500pt auto-float, configurable | "Dialogs stay dialogs" |
| Manual float / unfloat | `⌃⌥T` overrides per window | User control |
| Per-app rules | Always Tile / Always Float / Fixed Slot per bundle ID | "Teach it your apps" |
| Excluded apps list | Apps that never get managed | "Leave my menu bar utilities alone" |

### 3.4 Displays & Spaces

| Feature | What it actually does | Marketing angle |
| :--- | :--- | :--- |
| Independent per-display strips | Each display keeps its own columns | "Two screens, two stories" |
| Mission Control Space tracking | Each Space gets its own strip | "Work and chat never mix" |
| Nine virtual workspaces per display | `⌃⌥1…9` to switch, `⌃⌥⇧1…9` to send a window | "Nine desktops on top of your Spaces" |
| Send to next display | `⌃⌥N` moves the focused column | "Hand it to the other screen" |
| Send and follow | `⌃⌥⇧N` moves it and takes focus with it | "Follow your work" |
| Proportional width on migration | 50% on a 1080p screen becomes 50% on a 4K screen | "It scales, not stretches" |
| Throw to adjacent Space | `⌃⌥⇧←` / `⌃⌥⇧→` | "Banish it to Space 2" |
| Follow thrown windows | Option to switch Space with the thrown window | "Don't lose it" |
| Direct display focus | `⌃⌥⌘1/2/3` | Multi-monitor power move |
| Disable per display | Exclude a display from management | "Leave the projector alone" |
| Hot-plug recovery | Disconnect a monitor and windows migrate back; reconnect and the strip rebuilds | "Undocking doesn't break it" |
| Refresh-rate aware | 120 Hz ProMotion or 60 Hz external, detected per display | "Smooth on every panel" |

### 3.5 Physics & Performance

| Feature | What it actually does | Marketing angle |
| :--- | :--- | :--- |
| Rust strip engine | ~3,000-line dependency-free crate for layout, viewport, spring, magnetic math | Credibility + "why it's fast" |
| Zero hot-path allocation | Layout written into a caller-owned fixed-capacity buffer | Engineering proof point |
| `CADisplayLink` pacing | Locked to display refresh, 80–120 Hz | "Frame-perfect" |
| Analytical harmonic spring | Damped oscillator, not a cubic ease curve | "Real physics" |
| Synchronous frame 0 | First frame executes on keypress | "Zero perceived latency" |
| 15 ms AX timeout | Slow apps can't stall the run loop | "One hung app can't freeze your desktop" |
| Per-PID async AX queues | Window writes are serialized per app with latest-wins coalescing | "No IPC storms" |
| `CGWindowID` caching | Removes SPI calls during scroll | "Nothing wasted per frame" |
| Viewport filtering | Only windows near the viewport get updated | "75% fewer window calls" |
| `AXEnhancedUserInterface` suppression | Stops slow accessibility tree walks in Chrome/Spotify/Electron | Compatibility moat |
| Idle reconcile sweep | Low-frequency background sweep for missed windows | "No apps left behind" |
| Exponential backoff attach | Retries slow-launching apps up to 3 times | Handles Electron and Xcode |

### 3.6 Visual Feedback

| Feature | What it actually does | Marketing angle |
| :--- | :--- | :--- |
| Strip minimap HUD | Translucent whole-strip overview with live viewport tracker, auto-hides | Signature visual |
| Focus border | Accent outline on the active window | Clean, optional |
| Inactive window dimming | Subtle veil over unfocused windows | Focus mode aesthetic |
| Slide Launch Control | Floating panel: Kickstart, Stop, width presets, gap presets, live window list, status badge | The "control room" shot |
| Status badge | `🟢 ACTIVE` / `⚪ STOPPED` | State clarity |
| Smooth transitions | Animated camera shifts, ease-out focus ring | Polish |
| Live layout preview in Settings | Miniature strip that reacts to gap/margin/ratio changes | Great for a settings b-roll |
| Interactive trackpad test track | Swipe inside Settings to feel smoothness changes | Demo-friendly |
| Rotary smoothness wheel | 360° dial with gradient arc, response ms, damping ζ, VSYNC badge, 4 presets | The most "screenshotable" UI in the app |

### 3.7 Rules & Automation

| Feature | What it actually does | Marketing angle |
| :--- | :--- | :--- |
| Per-app policies | Always Tile / Always Float / Fixed Slot | "Your apps, your rules" |
| Small window auto-float | Threshold-based heuristic (default 500pt) | "Dialogs behave" |
| Excluded bundle IDs | Hard ignore list, sensible defaults (Notification Center, Control Center, Spotlight, System Settings) | "Respect the system" |
| Insertion policy | After Focused / At End / In Current Column | "Where new windows land" |
| Launch at login | `SMAppService` registration | Set and forget |
| Layout persistence | Atomic JSON, restores order, widths, stacks after restart | "Tomorrow, same desk" |
| Restoration bounds guards | Stranded windows are re-centered on screen | "Never lost off-screen" |

### 3.8 Setup, Diagnostics & Recovery

| Feature | What it actually does | Marketing angle |
| :--- | :--- | :--- |
| Mac Setup & Conflict Checker | Audits Accessibility, install path, "Displays have separate Spaces", MRU Spaces, Stage Manager, macOS 15 edge tiling, and conflicting managers (Rectangle, Magnet, AeroSpace, Amethyst, yabai, Loop, Moom) | Trust + friction removal |
| Trackpad swipe conflict check | Detects the system gesture that fights the strip | "We found the thing that was fighting you" |
| One-click permission repair | `tccutil reset Accessibility com.iume.Iume` | Support cost killer |
| Re-evaluate windows | `⌃⌥Z` full rescan | "Fix it without restarting" |
| Relaunch in place | `⌃⌥⇧Z` | Recovery |
| Diagnostic dump | Structured export of windows, displays, workspaces | Power-user support |
| Structured logging | `Diagnostics` subsystem | Engineering credibility |
| Single-instance mutex | `flock` on a lock file | No duplicate daemons |

### 3.9 Privacy, Security & Packaging

| Feature | What it actually does | Marketing angle |
| :--- | :--- | :--- |
| 100% offline | No `URLSession`, no network code anywhere in `Sources/` | "It literally cannot phone home" |
| No telemetry | No analytics, no crash reporting SDK | Privacy-first |
| Local metadata only | `UserDefaults` + local JSON | "Your layout stays on your Mac" |
| No Screen Recording | Uses Accessibility + WindowServer metadata, not screen capture | Fewer scary permissions |
| No root, no SIP changes | User-level Accessibility only | "Install and go" |
| Menu-bar only | `LSUIElement`, no Dock icon | Stays out of the way |
| MIT license | Forkable, auditable | Developer trust |
| Reproducible packaging | Version stamped from CHANGELOG, signature verified, checksum emitted | Professional release hygiene |
| Signed distribution path | Developer ID + notarization supported by `package.sh` | Enterprise-friendly |

---

## 4. What Makes It Unique

### 4.1 Against the field

| Alternative | What they do | What Iume does differently |
| :--- | :--- | :--- |
| **Rectangle / Magnet** | Keyboard shortcuts to snap a window into a zone | Iume manages the *whole desktop* as a persistent structure, not one-off snaps |
| **Amethyst / yabai / AeroSpace** | Grid or BSP tiling, config-file driven | Iume is a **continuous strip**, configured in a GUI, with trackpad-native motion |
| **Stage Manager** | Hides inactive windows in a side rail | Iume keeps them *visible and adjacent*, with real geometry you control |
| **PaperWM / niri / sway** | The same idea, on Linux | Iume is the native macOS answer — Accessibility, SkyLight, ProMotion, Mission Control |
| **macOS 15 window tiling** | Edge-drag halves and quarters | No strip, no persistence, no stacks, no physics |

### 4.2 Five things you can say nobody else does on macOS

1. **A true infinite strip with offscreen parking that doesn't fight WindowServer.** Windows fade out and park without clamping, teleporting, or spilling onto the next monitor.
2. **Chained magnetic windows.** Drag one, its neighbor comes with it, and both settle on a 120 Hz spring.
3. **Tabbed *and* stacked columns inside a horizontal strip.** A floating 28pt tab bar per column, not a global tab system.
4. **Per-display × per-Space × 9 virtual workspaces.** Three levels of isolation, all persisted.
5. **A Rust layout/spring core behind a versioned C ABI in a Mac app.** Deterministic math, 30 Rust tests, Swift parity tests.

### 4.3 The emotional differentiators (use these in VO)

- **"Nothing is ever behind anything."**
- **"The desktop moves, not the windows."**
- **"Your mess comes back exactly as it was."**
- **"It feels like the trackpad is connected to the wallpaper."**

---

## 5. Proof Sheet (for captions, landing page, and trust)

| Claim | Evidence |
| :--- | :--- |
| 120 Hz ProMotion scrolling | `CADisplayLink` with `CAFrameRateRange(80, 120, 120)`, 8.33 ms frame budget |
| Real spring physics | Analytical damped harmonic oscillator, damping ratio tuned ~0.90, velocity carried through settle |
| Native, not Electron | Swift 6 + AppKit + SwiftUI, arm64, app bundle under 4 MB |
| Rust core | `crates/iume_engine`, ~3,000 lines, 30 unit tests, zero hot-path allocation |
| Test coverage | 79 Swift tests across 12 suites + 30 Rust tests |
| Zero network | No `URLSession` / `NSURLConnection` / HTTP strings in `Sources/` |
| No root required | Accessibility permission only; no SIP changes, no kernel extensions |
| No Screen Recording | Window identity via Accessibility + WindowServer metadata |
| macOS 14+ | `LSMinimumSystemVersion 14.0` |
| Menu-bar only | `LSUIElement = true` |
| MIT | `LICENSE` |

---

## 6. Video Storyboards

### 6.1 The 45–60s Hero Film

| Time | Visual | On-screen text / VO |
| :--- | :--- | :--- |
| 0:00–0:04 | Cluttered desktop, windows stacked on each other | "This is how macOS thinks." |
| 0:04–0:06 | Hard cut: everything snaps into tall columns | "This is how Iume thinks." |
| 0:06–0:14 | Slow two-finger swipe; columns glide; minimap tracker moves | "One strip. Every window. No overlap." |
| 0:14–0:22 | Launch an app; it appears beside the current window, focused | "New windows open next to what you're doing." |
| 0:22–0:30 | Drag a window into its neighbor; both move; soft settle | "Magnetic. They travel together." |
| 0:30–0:38 | Three terminals stacked → `⌃⌥⇧T` → tab bar appears | "Stack them. Or tab them." |
| 0:38–0:46 | Monitor plugged in; second strip appears; `⌃⌥N` sends a window across | "Every display. Every Space. Its own strip." |
| 0:46–0:52 | Stop & Restore: strip dissolves back into the original mess | "And when you're done — your desktop comes back exactly as it was." |
| 0:52–0:58 | Menu bar icon, app name, URL | "Iume. Your windows, on a rail." |

**Music:** minimal electronic, one soft impact on each snap. Let the spring settle breathe — don't cut on the snap.

### 6.2 The 20s Vertical Cut (Shorts / Reels / TikTok)

1. **0–3s Hook:** "Your Mac has a window problem." (cluttered desktop)
2. **3–6s:** Snap to strip. "Fixed."
3. **6–12s:** Fast swipe with minimap + one magnetic drag.
4. **12–16s:** Stack → tab flip.
5. **16–20s:** Stop & Restore → "Nothing is permanent. Link in bio."

### 6.3 The 6s Bumper

One motion only: a 4-column strip swiping right, minimap tracking, settle. Logo. Done.

### 6.4 Feature Vignette Series (each 10–15s, one per hero)

| Episode | Working title | Core shot |
| :--- | :--- | :--- |
| 01 | The Rail | Desktop → strip transformation |
| 02 | Beside You | App launch slots next to focus |
| 03 | Glass | Overhead trackpad + 1:1 strip motion |
| 04 | Magnets | Chained drag + seam snap |
| 05 | Stack or Tab | Terminal stack → tabbed column |
| 06 | More Screens | Hot-plug monitor + send to display |
| 07 | The Minimap | Fast scroll with HUD tracker |
| 08 | Undo My Desktop | Stop & Restore before/after |
| 09 | Teach It | Per-app rule for Calculator / Spotify |
| 10 | The Setup Checker | Conflict scan finding Rectangle |

---

## 7. Copy Bank

### 7.1 Taglines

- Your windows, on a rail.
- The desktop that keeps going.
- Nothing behind anything.
- macOS, but horizontal.
- One strip. Zero overlap.
- Built for people who open too many windows.

### 7.2 Hooks by platform

| Platform | Hook |
| :--- | :--- |
| X / Twitter | "I got tired of Cmd-Tabbing, so I built a window manager where the desktop scrolls instead." |
| Reddit r/macapps | "Iume 2.6 — a PaperWM/niri-style infinite horizontal strip for macOS, with 120 Hz trackpad physics and magnetic windows." |
| Hacker News | "Show HN: Iume — continuous strip tiling for macOS, with a Rust layout/spring engine" |
| TikTok / Reels | "POV: your Mac desktop is one long scroll." |
| LinkedIn | "We rebuilt the macOS desktop as a timeline instead of a pile." |
| Product Hunt | "Iume — the infinite scrolling window manager for macOS" |

### 7.3 Feature one-liners (reusable captions)

- **Strip:** Every window side by side, forever.
- **Insertion:** New windows open where you're looking.
- **Trackpad:** The wallpaper moves with your fingers.
- **Magnets:** Windows that hold hands.
- **Stacks:** Five terminals, one column.
- **Tabs:** A tab bar that lives inside your column.
- **Minimap:** See the whole rail while you scroll.
- **Spaces:** Work and chat never share a strip.
- **Workspaces:** Nine desktops per display, per Space.
- **Stop & Restore:** Your mess, exactly as you left it.
- **Privacy:** No account. No cloud. No network code.
- **Rust core:** Because 60 fps was not the goal.

### 7.4 Call to action

- "Download the DMG. Grant Accessibility. Hit `⌃⌥Space`. That's it."
- "Free and MIT-licensed. Bring your own keyboard."
- "Try it for one afternoon. You won't go back to a grid."

---

## 8. Claims: Safe vs. Avoid

### Safe to say
- "Continuous horizontal strip tiling"
- "Natively built for macOS 14+ on Apple Silicon"
- "120 Hz on ProMotion displays; 60 Hz on standard externals"
- "No telemetry, no account, no network calls"
- "Accessibility permission required; no Screen Recording"
- "MIT licensed"
- "Layouts persist per display, per Space, per virtual workspace"
- "Restores original window geometry on stop or quit"

### Say carefully
| Instead of | Say |
| :--- | :--- |
| "Infinite windows" | "An endless-feeling strip — the desktop keeps scrolling" |
| "Zero latency" | "Starts on the first frame, so it feels instant" |
| "Perfectly smooth everywhere" | "120 Hz on ProMotion; 60 Hz on standard displays" |
| "Works with every app" | "Handles native, Electron, and Chromium windows; fixed-size utilities float automatically" |
| "No permissions" | "One permission: Accessibility" |
| "Never breaks" | "Includes a setup checker and one-click permission repair" |

### Don't say
- "Notarized" unless you actually have a Developer ID and notarization in place — `package.sh` falls back to ad-hoc signing.
- "Intel / Universal" — the shipped binary is arm64.
- "Sandboxed" — it is not; it requires Accessibility.
- "Cloud sync" — there is none.
- "Free forever" unless that's your intent — say "MIT licensed" instead.

---

## 9. Demo Setup Checklist (before you hit record)

1. Build and install the current bundle: `./scripts/package.sh --package-only` then `open .build/bundle/Iume.app`.
2. Confirm Accessibility is granted and the menu bar icon shows `🟢 ACTIVE`.
3. Set a clean wallpaper and hide desktop icons (or use a plain dark gradient for contrast).
4. Set gap to **8 pt**, margins to **8 pt**, default width **50%** — the most legible look on camera.
5. Turn on **Minimap HUD** and **Focus Border** for the hero shots; turn them off for the "clean" cuts.
6. Use apps with strong visual identity: a dark editor, a browser, a terminal, Figma, Spotify. Avoid windows with white chrome against a white background.
7. Pre-open 6–8 windows so no shot requires waiting for an app to launch.
8. Record at 120 fps if possible, then conform to 24/30 for the cinematic cut. Keep a 60 fps version for GIFs.
9. Capture the trackpad from above with a phone; sync it to screen capture in post.
10. Do a `Stop & Restore` rehearsal — know exactly what the "before" desktop looked like.

---

## 10. Asset Checklist

- [ ] 60s hero film (16:9, 4K)
- [ ] 20s vertical cut (9:16)
- [ ] 6s bumper (1:1 and 16:9)
- [ ] 10 × feature vignettes (15s)
- [ ] 6–8 stills at 2× for the landing page
- [ ] Minimap HUD close-up GIF
- [ ] Magnetic drag slow-motion GIF
- [ ] Stack → tab flip GIF
- [ ] Before/after Stop & Restore comparison image
- [ ] App icon on transparent background
- [ ] Menu bar icon close-up
- [ ] Settings Studio screenshot (smoothness wheel + live preview)
- [ ] Caption/subtitle file for silent autoplay
- [ ] Press kit: one-paragraph description, feature list, proof sheet, download link

---

## 11. Short Version (if you only read one section)

Make the video about **three motions**:

1. **The reveal** — clutter becomes a strip.
2. **The glide** — fingers on the trackpad, desktop moving 1:1.
3. **The return** — Stop & Restore gives the mess back.

Everything else (magnets, stacks, tabs, workspaces, minimap) is seasoning. If those three land, the product is understood in under 15 seconds.

---

*Generated from the Iume 2.6.0 source tree: `README.md`, `CHANGELOG.md`, `Sources/IumeCore/**`, `crates/iume_engine`, and `Resources/Info.plist`. Feature names reflect the shipping build, not the roadmap.*
