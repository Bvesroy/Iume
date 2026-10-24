# Iume — Feature Map & Roadmap

*A single, honest inventory of what Iume does today and the order in which the gaps should be closed.*

Status legend: **✅ shipped** · **🟡 partial** · **⬜ not started**

---

## 1. What is implemented

### 1.1 Tiling & navigation
| Area | State | Notes |
| :--- | :--- | :--- |
| Scroll strip (PaperWM/niri style) | ✅ | Infinite horizontal strip, focus-driven viewport, spring settle |
| Focus Column / Centered Focus | ✅ | Minimal-scroll and always-centred camera modes |
| Manual / free layout | ✅ | Windows keep the frame you drag them to; no snap-back |
| Grid / Tall / Wide / BSP / Row / Column | ✅ | Adaptive grid (`3+2`, `3+2+2`, `4+3+3`) fills every row |
| Column stacks & tabbed columns | ✅ | Proportional stacks, tab bar overlay, stack/pop shortcuts |
| Gaps, margins, presets | ✅ | Per-screen margins, zero-gap mode, width presets, smart margins |
| Multi-display | ✅ | Independent strip per display, send-to-display, proportional width migration |

### 1.2 Resize, snapping & box control
| Area | State | Notes |
| :--- | :--- | :--- |
| Neighbour-aware resize | ✅ | Edges push/pull adjacent boxes, clamped to min size and screen |
| Free edge/corner resize | ✅ | Cursor picks the edge or nearest corner; axes stay locked |
| Keyboard box resize | ✅ | ⌃⌥=/− and ⌃⌥⇧=/− grow the box from its neighbours |
| Snap actions (halves, thirds, quarters, max, centre) | ✅ | Radial menu (⌃⌥B) + Custom Box Studio (⌃⌥⇧B) |
| Balance / equalise / swap with main | ✅ | ⌃⌥A, ⌃⌥⇧↩ |
| Adaptive re-tile on open/close | ✅ | Stale hand-placed boxes are dropped per display + Space |
| Magnetic snapping & adhesion | ✅ | 32 pt attraction, seam ratio snaps, zero-flicker settle |

### 1.3 Window, space & app management
| Area | State | Notes |
| :--- | :--- | :--- |
| Virtual workspaces 1–9 | ✅ | Per display + Mission Control Space, switch/move shortcuts |
| Space throwing | ✅ | Dedicated factory chords ⌃⌥⇧⌘←/→ (and ⌃⌥⇧⌘H/L), moves window between Spaces |
| Persistence | ✅ | Atomic JSON restore of columns, widths, stacks, focus |
| Stop & restore | ✅ | Returns every window to its pre-tiling frame |
| Native tab detection | ✅ | Safari/Finder/Ghostty tab swaps reuse the column |
| App exclusions (float list) | ✅ | Settings → Application Rules |
| Per-app policies (`alwaysTile`, `alwaysFloat`, `fixedSlot`) | ✅ | Full editor in Settings → Application Rules with running apps quick-select and live re-evaluation |
| Small-window auto-float | ✅ | Configurable width threshold |
| Focus follows mouse / mouse follows focus | ✅ | 120 ms hysteresis, anti-focus-steal guard |

### 1.4 Interaction & performance
| Area | State | Notes |
| :--- | :--- | :--- |
| 120 Hz spring physics | ✅ | Analytical damped oscillator, `CADisplayLink` paced |
| Trackpad gestures | ✅ | 3/4-finger centroid panning, 2-finger modes, momentum handover |
| Loop seam tick (Loop Mode) | ✅ | **New:** quiet wooden tick on every completed lap; toggle in Appearance → Sound Feedback |
| Modifier-drag move/resize | ✅ | ⌃⌥-drag with live footprint preview |
| Off-screen parking | ✅ | SkyLight ordering + alpha, no WindowServer clamping |
| Rust physics core / C++ WindowServer bridge | ✅ | Spring solver, filtering, hit-testing, CGS window ordering |
| Titlebar drag-to-reorder | ✅ | Column midpoint hit-test on drop |
| Focus border, dimming, minimap HUD | ✅ | 3 HUD styles, dial, sound cues |

### 1.5 Shortcuts & settings
| Area | State | Notes |
| :--- | :--- | :--- |
| **User-remappable shortcuts** | ✅ | **New:** every action editable, live recorder, conflict detection, per-action reset, JSON persistence |
| **Shortcut cheatsheet** | ✅ | **New:** ⌃⌥/ floating list rendered from the live binding table |
| Global Carbon hotkeys | ✅ | Work while Iume is in the background, no Input Monitoring |
| Legacy ⌥ shortcuts | ✅ | Optional additive layer, skipped when it would collide |
| Settings window (8 panes) | ✅ | System Settings conventions, searchable sidebar, immediate apply |
| Menu bar + launch HUD | ✅ | Layout switcher, quick controls, status, stop/restore |
| Mac Setup checker & diagnostics | ✅ | Permissions, Spaces settings, conflicting managers, TCC repair |

---

## 2. Gaps worth closing

Ordered by value ÷ effort. Each item is a vertical slice: model → engine → persistence → UI → shortcut → tests.

### P0 — Finish what already half-exists
1. ~~**Per-app rules editor** (`alwaysTile` / `alwaysFloat` / `fixedSlot`)~~ — shipped in Settings → Application Rules with running apps quick-select and live re-evaluation.
2. ~~**Space throwing defaults**~~ — shipped with default factory chords ⌃⌥⇧⌘←/→ (and ⌃⌥⇧⌘H/L).
3. ~~**Cheatsheet overlay**~~ — shipped alongside remappable shortcuts; one panel fed by `ShortcutCatalog`, so documentation cannot drift.

### P1 — Window-level safety net
4. **Frame undo / history** — keep a small undo stack of applied frames per window; ⌃⌥⌫ restores the previous size. Rectangle/Loop parity.
5. **Named layouts** — save the current strip as a named profile and restore it later; builds on `LayoutPersistenceManager`.
6. **Scratchpad / sticky window** — one hidden slot per display, toggled with a chord; floats above the strip.

### P2 — Layout model depth
7. **Per-workspace layout mode** — `layoutMode` is global today. Scope it to `WorkspaceKey` and fall back to the global default.
8. **Named workspaces + workspace bar** — labels instead of 1…9, visible in the menu bar and minimap.
9. **Per-display gaps/margins** — one `EdgeMargins` for all screens today.

### P3 — Extensibility
10. **Config file / export-import** — TOML or JSON for bindings, rules, gaps, layouts; a CLI (`iume apply-profile`) for dotfiles users.
11. **URL scheme / Shortcuts.app actions** — `iume://layout/grid`, expose actions to Apple Shortcuts.
12. **Gesture tuning** — finger count, direction inversion, per-device sensitivity.

### P4 — Polish
13. **Window switcher palette** — searchable titles instead of blind cycling.
14. **Menu bar per-app pause** — suspend tiling for one app without editing the exclusion list.
15. **VoiceOver labels and keyboard-only settings navigation.**

---

## 3. How to add a feature (the pattern that works here)

1. **Model first.** Add the value type to `Models/` and make it `Codable, Sendable, Equatable`.
2. **Pure logic second.** Put geometry/decision code in `LayoutEngine` (or a new pure helper) with no AppKit or AX calls.
3. **Tests before UI.** Cover the happy path, clamping, empty input and the regression that motivated the change.
4. **Persist it.** Add a `SettingsStore` key, decode with a safe default, and include it in `resetToDefaults()`.
5. **Wire every surface.** Settings row, status-bar item where it matters, and a `ShortcutAction` + default chord in `ShortcutCatalog.defaults()`.
6. **React live.** Subscribe in `WorkspaceManager.setupBindings()` so changes apply without a restart.
7. **Document & ship.** CHANGELOG entry, README/shortcut table, `scripts/package.sh`, then verify the installed app — not just the test suite.

**Guardrails:** never register a chord twice (`ShortcutCatalog.conflicts`), never resurrect a deliberately unbound action (`ShortcutCatalog.normalized`), and never let a settings control exist without a testable model behind it.

---

## 4. Shipped in this pass — remappable shortcuts

- `ShortcutBinding.swift`: `ShortcutChord` (Carbon keycode + modifiers, layout-aware glyphs), `ShortcutBinding` (per action, up to two chords), `ShortcutCatalog` (defaults, groups, normalisation, conflicts, reassignment, reset).
- `ShortcutManager`: registration now reads the catalog (`applyBindings`), reports chords macOS refused, and suspends hotkeys while the recorder listens.
- `SettingsStore`: `shortcutBindings` persisted as JSON, normalised on launch, reset with factory defaults.
- Settings → Shortcuts: every action listed with clickable keycaps, a live recorder (⌃⌥/⌘ required, Escape cancels), add/remove alternative chord, per-action reset, duplicate-chord banner with one-click resolution.
- `ShortcutCheatsheetController`: ⌃⌥/ floating cheatsheet grouped by action family, rendered from the same persisted bindings (no second list to maintain).
- `KeyTranslator` now serialises Text Input Source lookups; concurrent layout queries previously aborted the test runner.
- Verified by `ShortcutCustomizationTests` (18 tests) and the full suite: 160 tests / 17 suites.
