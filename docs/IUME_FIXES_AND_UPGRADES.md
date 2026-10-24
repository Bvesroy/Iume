# Iume — Fixes, Changes & Upgrades (source-verified)

> Supersedes `docs/IUME_FIX_PARITY_UPGRADE_INSTRUCTIONS.md`, which was written without reading the source.
> Every root cause below was traced to code in this repository (paths relative to `Sources/IumeCore/` unless noted).
> Target behaviour: ChainYourMac / TileMyMac — one endless horizontal strip per display, 1:1 smooth scrolling,
> edges always flush, nothing overlaps, nothing is left behind, only the Accessibility permission.

---

## 0. Summary — reported issue → root cause → fix section

| # | Reported issue | Main root causes (verified) | Fix |
|---|---|---|---|
| 1 | Scroll is not smooth | Four overlapping motion models fight each other (1:1 tracking, custom coast, exponential follow, spring). Custom coasting runs *while* macOS momentum events also arrive. The snap runs twice. The display link is bound to `NSScreen.main` only. | §3 |
| 2 | Apps/windows left behind or not taken into the strip | Windows floated at creation are never re-classified. Small-window threshold is not passed from settings. IDs fall back to `CFHash` (unstable). Hidden apps, other-Space windows and later native fullscreen are not handled. Destroy/minimize/terminate only look at `activeDisplayId`. | §7 |
| 3 | Scroll is very laggy | Per frame: `@Published workspaces` mutated (SwiftUI re-renders at 120 Hz), full layout recompute, `CGSOrderWindow` IPC for every window, overlays and minimap updated, `recordExpectedFrame` for every window. Settled frames written **synchronously on the main thread** with a 100 ms timeout per window. | §2 |
| 4 | Asks for Accessibility again and again | Ad-hoc signing (new cdhash every build) plus `rm -rf /Applications/Iume.app` on every install. `main.swift` prompts and opens Settings on *every* untrusted launch. Two owners of `onPermissionStateChanged`. | §1 |
| 5 | Overlapping windows | Off-screen columns are parked on a 12 px sliver *on top of* the visible edge column. A 35 px threshold jump. Floated windows sit over tiles. Z-order calls don't work on other apps' windows. App min-widths are larger than the column width. | §5 |
| 6 | Big gap between two apps / edges not together | Gap and width are derived in 4+ different ways (`visibleFrame.width` vs `usableWidth`, `windowGap` vs `appsEdgeTogether` vs `smartWindowMargins`). Mouse-up overwrites **every** column width from AX frames. Geometry reflow resets widths. Preset math ignores the gap. `computeLayout` skips empty columns but the offset helpers don't. | §6 |
| 7 | Switches to the next desktop while scrolling | macOS "swipe between full-screen apps" (3/4 fingers) runs alongside Iume's passive MultitouchSupport swipe. `app.activate()` on settle jumps to a Space where the app has a window (`workspaces-auto-swoosh`). | §4 |
| 8 | New app should open right next to the focused window | Insert index comes from `ws.focusedColumnIndex`, which goes stale because focus changes are ignored while `scrollController.isMoving`. | §8 |
| 9 | Manual resize must be seamless; the neighbour must follow the new edge | Edge guessed from `abs(deltaLeft) < 10`. Only the adjacent column is adjusted (zero-sum), columns further away are not moved, a global suppression flag drops the user's own events, and the result is not clamped to real app min sizes. | §9 |
| 10 | Working smoothness wheel in settings | `SmoothScrollWheelView` exists (`UI/SettingsView.swift:956`), but `scrollSmoothness` feeds three unrelated formulas (`ScrollController.swift:388, 520, 691`), so the dial feels like it does nothing. | §3.3 |
| 11 | Transitions during scroll and window change | Only focus/viewport moves animate. Open, close, resize, preset and reorder jump. No Reduce Motion support. | §10 |

---

## 1. Accessibility permission loop (P0)

### Root causes
1. `scripts/package.sh:40-56` — if no "Developer ID Application" or "Iume Local Signer" identity is found it signs **ad-hoc** (`--sign -`). Each build gets a new cdhash, and TCC treats ad-hoc builds as a new app, so the old grant silently stops matching.
2. `scripts/package.sh:65` — `rm -rf /Applications/Iume.app` followed by a fresh copy on every install. With an unstable identity this guarantees a new TCC record.
3. `scripts/build.sh` / `build-release.sh` produce a bare executable in `.build/`. Running that binary is yet another TCC identity (it's the terminal's or the binary's, not the app bundle's).
4. `Sources/Iume/main.swift:40-41` — every launch without trust calls `promptForAccessibility()` **and** `openSettings()`. `PermissionManager.requestPermissionExplicitly()` (`Permissions/PermissionManager.swift:63`) prompts once and afterwards opens System Settings every time. The user sees this as "asking again and again".
5. `main.swift:15` reassigns `PermissionManager.shared.onPermissionStateChanged`, which `WorkspaceManager` also assigns. The last writer wins, so the strip sometimes never starts after the grant, and the user re-grants.
6. `Resources/Iume.entitlements` contains `allow-jit` and `allow-unsigned-executable-memory`. Neither is needed, and they weaken hardened runtime.

### Fixes
1. **Create one stable signing identity once** and never sign ad-hoc again:
   - Best: an Apple "Developer ID Application" certificate (also required for notarization and Sparkle, §12.2).
   - Free alternative: Keychain Access → Certificate Assistant → Create a Certificate… → name `Iume Local Signer`, type *Code Signing*, saved in the login keychain. `package.sh` already looks for this name.
   - In `package.sh`, **fail the build** instead of falling back to ad-hoc:
     ```bash
     if [[ -z "$SIGN_IDENTITY" ]]; then
       echo "ERROR: No 'Developer ID Application' or 'Iume Local Signer' identity found. Refusing to ad-hoc sign (breaks TCC)." >&2
       exit 1
     fi
     ```
   - Drop the custom `--requirements '=designated => identifier …'`. With a real certificate the default designated requirement (identifier + certificate leaf) is what keeps TCC stable.
   - Drop `--deep` (deprecated; sign nested code explicitly if any is added later).
2. **Install in place without deleting the bundle**:
   ```bash
   pkill -x Iume || true
   ditto "$APP_DIR" "/Applications/Iume.app"   # overwrite contents, keep path
   ```
   Keep the path `/Applications/Iume.app` constant. Never run the `.build/` executable for day-to-day use; always launch the bundle.
3. **Prompt at most once per install, only from onboarding**:
   - Remove the unconditional `promptForAccessibility()` and `openSettings()` from `main.swift:40-41`.
   - On an untrusted launch, show the onboarding/permission card in Settings (one window, one button "Open Accessibility Settings"). No system dialog unless the user clicks.
   - Keep the 1 s poll in `PermissionManager`, but stop polling once trusted and start the strip from **one** place.
4. **Single permission owner**: change `onPermissionStateChanged` to a multicast publisher (`@Published var isTrusted` or `NotificationCenter`). `WorkspaceManager` and the status bar subscribe; nobody assigns the closure.
5. **Stale-entry repair** (`repairStaleTCCEntry`, `tccutil reset Accessibility com.iume.Iume`) should only run from a button in Mac Setup ("Permission looks granted but doesn't work → Repair"). Never run it automatically.
6. Remove both entitlements from `Resources/Iume.entitlements` (leave the file empty or delete it and the `--entitlements` flag).
7. `package.sh` also runs `rsync --delete` to the MEGA folder. Keep it, but move it behind a `--backup` flag so day-to-day builds don't touch the sync folder.

**Acceptance**: rebuild and reinstall 5 times in a row. Accessibility stays granted and no dialog or Settings window appears.

---

## 2. Lag — the per-frame pipeline (P0)

### Root causes (per animation frame, at 80–120 Hz)
| Where | What happens each frame |
|---|---|
| `Workspace/WorkspaceManager.swift:48, 560-565` | `workspaces` is `@Published`. `onViewportOffsetChanged` writes `workspaces[activeDisplayId] = ws` → `objectWillChange` → every SwiftUI view observing the manager re-diffs. |
| `WorkspaceManager.swift:1627` `applyPhysicalWindowPositions` | Full `computeLayout` for all columns, a copy of `registry.windowMap()`, `recordExpectedFrame` for every window, tab bar, dimming and focus-border updates. |
| `WorkspaceManager.swift:568-581` `onScrollActivity` | Minimap rebuilt every frame (also recomputes `totalStripWidth`). |
| `Controller/WindowController.swift:378` `enforceStripZOrder` | `CGSOrderWindow` for **every window, every frame** — synchronous WindowServer IPC. It also has no effect on other processes' windows without SIP disabled. |
| `WindowController.swift:266` | `ensureEnhancedUIDisabled` (lock + AX call) per placement per frame. |
| `WindowController.swift:333, 494` | Settled pass: **synchronous** `setFrame` on the main thread with `AXUIElementSetMessagingTimeout(…, 0.10)` per window, plus a size re-read, inside `CGSDisableUpdate`. One slow app (Electron, Xcode) freezes everything for 100 ms × windows. |
| `Registry/WindowRegistry.swift` | `focusedId` setter iterates all windows; `findWindowId(matchingAXElement:)` is an O(n) `CFEqual` scan for every AX notification. |

### Fixes
1. **Split hot state from published state.** Add a non-published `ViewportState` (offset, velocity, isMoving) owned by `ScrollController`. During motion, *do not* touch `workspaces`. Write `ws.viewportOffset` back once in `onAnimationCompleted` / settle. Views that need live offset (minimap) read it through a throttled publisher (30 Hz max).
2. **Precompute once per gesture, not per frame.** At gesture start, build a `StripSnapshot`:
   ```swift
   struct StripSnapshot {
       let displayId: CGDirectDisplayID
       let geometry: StripGeometry            // §6.1
       let columnX: [CGFloat]                 // strip-space left edge per column
       let placements: [(WindowId, AXUIElement, CGRect)]  // strip-space frames, stacks resolved
   }
   ```
   Per frame, the only maths is `screenX = geometry.originX + columnX[i] - offset` for columns that intersect `[−parkMargin, visibleWidth + parkMargin]`. Columns that stay parked are not touched again.
3. **Delete `enforceStripZOrder` from the frame loop.** It doesn't work on foreign windows and costs one IPC per window per frame. Keep at most one raise of the focused window at settle (§4.2).
4. **Call `ensureEnhancedUIDisabled` once per pid** (on registration and on app activation), not per placement.
5. **All AX writes off the main thread, latest-wins, never blocking.** `WindowWriter` already exists — route the settled `setFrame` through it too:
   - per-window coalescing slot (if a write for that window is in flight, replace the pending value instead of queuing);
   - per-pid serial queue (AX is per-app anyway), 50 ms timeout, so a hung app only hurts itself;
   - position-only writes while moving (`kAXPosition`), size writes only when the width actually changed;
   - read-back verification asynchronously on the same queue; report mismatches back to main (§5.4).
6. **Remove `withAtomicScreenUpdates` (`CGSDisableUpdate`) from the settle path.** Holding screen updates while waiting on synchronous AX calls is what makes the whole screen stutter on settle. With flush edges (§5) there is nothing to hide.
7. **Suppress self-originated events by token, not by recording every frame.** Call `recordExpectedFrame` once per gesture with the final target, plus a `gestureActive` flag per window (§9.4).
8. **Overlays**: update the focus border and tab bar only on settle and on focus change; while moving, translate them with the same offset (`NSWindow.setFrameOrigin`, no SwiftUI re-render). Minimap ≤30 Hz.
9. **Registry**: add `[CGWindowID: WindowId]` and keep the focused id only (derive `isFocused` on read) — O(1) lookups.
10. **Display link per screen**: create the `CADisplayLink` from the screen of the strip being scrolled (`NSScreen.displayLink(target:selector:)`, macOS 14), not `NSScreen.main` (`ScrollController.swift:216, 244`), so ProMotion and external 60 Hz displays both pace correctly.
11. **Multitouch callback**: don't `DispatchQueue.main.async` every touch frame (`ScrollController.swift:948-971`). Accumulate the delta in a lock-protected accumulator and let the display link consume it once per frame.
12. Add `os_signpost` intervals around: frame callback, layout, AX write enqueue, AX write completion. Budget: < 2 ms main-thread work per frame with 20 windows.

**Acceptance**: 20 windows from 8 apps (Chrome, VS Code, Slack, Terminal, Finder, Xcode, Notes, Ghostty). Continuous 2-finger scroll for 10 s: main-thread frame time < 4 ms p95, no dropped display-link frames in Instruments, WindowServer CPU < 40%.

---

## 3. Smooth scrolling — one motion model (P0)

### Root causes (`Controller/ScrollController.swift`)
- Motion paths compete: direct 1:1 tracking, exponential follow (`lambda = max(28, 35 + (1-s)*80)`, line ~397), custom friction coast (`0.965`, line 363), spring snap, and the legacy `CriticallyDampedSpring`.
- Phase-4 (finger lift) with `|v| > 25` (line 646) starts custom coasting **and** macOS keeps delivering `momentumPhase` events, so two integrators drive the offset → jitter.
- `endInteractiveSwipe` (lines 597-598) and `settle()` (lines 758-759) call **both** `onSwipeSettled` and `onSettleRequested`, so the snap target is computed twice and the spring is restarted mid-flight.
- Discrete-wheel settle delay `0.10 + s*0.08` (line 692) is separate from everything else.

### 3.1 Target model (TileMyMac / ChainYourMac feel)
| Phase | Behaviour |
|---|---|
| Finger down / scrolling (trackpad `phase` 1–2) | **1:1 tracking**: offset += delta × sensitivity. Optional light smoothing from the dial (§3.3). Rubber-band past the ends (resistance 0.35, max 80 pt). |
| Finger up (`phase` 4) | Read velocity from the last 50 ms of samples (least-squares, not last delta). **Immediately** compute the projected end `offset + v * projectionTime`, pick the snap column (or keep free position if snapping is off), start **one** retargetable spring toward it with the current velocity. |
| macOS momentum events (`momentumPhase` 1–3) | **Consume and ignore** them for the strip (return `nil` from the tap so apps don't scroll either). They don't drive the offset. This removes the double-integrator. |
| New input during the spring | Cancel the spring, keep the current position and velocity, continue 1:1. |
| Mouse wheel (no phase) | Each notch adds to a target; the spring follows the target; snap 120 ms after the last notch. |
| 3/4-finger swipe (MultitouchSupport) | Same as trackpad: 1:1 tracking, lift → velocity projection → spring. |

Implementation rules:
- One `SpringState` (keep the existing implicit-Euler version, which is stable) and delete `CriticallyDampedSpring`, custom friction coasting and the exponential-follow branch.
- Exactly one settle callback: `onSettleRequested(projected, velocity)`. `onSwipeSettled` becomes a notification fired *after* the spring completes. Remove the duplicate calls at lines 597-598 and 758-759.
- Keep `GestureOwner` latching (strip vs app) for the whole gesture including momentum.

### 3.2 Scroll interception (`shouldInterceptScroll`, line 769)
- `.seamlessHorizontal` (default) currently steals every horizontal 2-finger scroll from apps (breaks horizontal scrolling in Figma, spreadsheets, timelines). Change the default rule:
  - intercept when the gesture starts with `|dx| > 2.5 |dy|`, **and** either the pointer is over a window that can't scroll horizontally (cheap check: cache per app, or a list of known horizontal-scroll apps) **or** a modifier is held (default ⌥ or ⌃⌥, configurable);
  - always intercept over the desktop, gaps, the top menu-bar zone and the minimap.
- Keep `.modifierOnly` and `.always` modes for users who want them.

### 3.3 Smoothness wheel — make it actually do something
Keep `SmoothScrollWheelView` and `scrollSmoothness` (0…1, default 0.5 instead of 0.75). Map it through **one** function used by every path:

```swift
public struct MotionProfile: Sendable {
    public let trackingLambda: CGFloat     // 0 = raw 1:1; higher = more smoothing of finger input
    public let springResponse: CGFloat     // seconds
    public let springDamping: CGFloat      // ratio
    public let projectionTime: CGFloat     // seconds of velocity used for fling projection
    public let wheelSettleDelay: TimeInterval

    public static func from(smoothness s: Double, baseDuration: Double) -> MotionProfile {
        let s = CGFloat(min(max(s, 0), 1))
        return MotionProfile(
            trackingLambda: s < 0.05 ? .infinity : 90 - 70 * s,   // ∞ = no smoothing … 20/s = silky
            springResponse: CGFloat(baseDuration) * (0.75 + 0.6 * s), // 0.22 s → 0.165…0.30
            springDamping: 1.0 - 0.12 * s,                          // 1.0 crisp … 0.88 slight overshoot
            projectionTime: 0.10 + 0.12 * s,                        // short vs long flings
            wheelSettleDelay: 0.08 + 0.10 * s
        )
    }
}
```

- Recompute the profile in a `settings.$scrollSmoothness` sink (cached), not by reading `SettingsStore.shared` inside the frame loop.
- Dial labels: 0 = "Instant", 0.5 = "Balanced", 1 = "Silky". Show the resulting response time under the dial.
- The existing "Interactive Trackpad Test Track" in Settings is a SwiftUI `ScrollView`, so it doesn't use Iume's physics. Replace it with a small preview that drives a `MotionProfile` simulation (fake columns animated by the same `SpringState`) so the dial effect is visible.
- Keep "Transition Animation Speed" (`animationDuration`) as the *base* duration and the dial as the *character*. Rename the toggle "Inertial Momentum Coasting" → "Fling to next window" (on = velocity projection, off = snap to nearest).

**Acceptance**: with the dial at 0 the strip follows the finger with zero visible lag; at 1 it glides; flinging lands exactly on a column edge without a second correction "bump".

---

## 4. Desktop/Space switching while scrolling (P0)

### Root causes
1. macOS gesture "Swipe between full-screen applications" (3 fingers or 4 fingers) is on by default. Iume's 3/4-finger swipe reads MultitouchSupport *passively* (it can't consume touches), so both Iume and the Dock act on the same swipe.
2. Focus on settle: `onAnimationCompleted` → `focusWindowProgrammatically` (`WorkspaceManager.swift:620-626`) → `WindowController.focus` (`WindowController.swift:611-640`) ends with `app.activate()`. With "When switching to an application, switch to a Space with open windows for the application" (`com.apple.dock workspaces-auto-swoosh`, default on), activating an app whose *other* window lives on another Space jumps there.
3. `MacSetupChecker.swift:151-152` only reads the built-in trackpad domain. Magic Trackpad uses `com.apple.driver.AppleBluetoothMultitouch.trackpad`, and the effective value may also live in the `-currentHost` global domain (`com.apple.trackpad.threeFingerHorizSwipeGesture`, `com.apple.trackpad.fourFingerHorizSwipeGesture`).

### Fixes
1. **Gesture conflict**:
   - Mac Setup check reads all three locations; warn when the system uses the *same finger count* as Iume's swipe setting.
   - Add a setting "Strip swipe fingers: 3 / 4 / Off" (default **Off** until Mac Setup confirms there is no conflict). Never enable a finger count that macOS also uses.
   - The "Fix" button in Mac Setup can write the keys (it already does in `disableConflictingDesktopSwipe`), but tell the user the change takes effect after logging out/in, and re-read the value to confirm instead of assuming success.
2. **Never trigger a Space switch from focus**:
   - In `WindowController.focus`: use `_SLPSSetFrontProcessWithOptions` with the window ID + `kAXRaise` + `kAXMain`. Call `NSRunningApplication.activate()` **only** when the SLPS path fails *and* the window is on the current Space.
   - Before focusing, verify the window is on the active Space (it's in `CGWindowListCopyWindowInfo(.optionOnScreenOnly, …)`); if not, don't focus it and remove it from the strip (§7.5).
   - Don't change focus at all on settle if the settled column already contains the frontmost window.
   - Add a Mac Setup check for `workspaces-auto-swoosh` with the recommendation to turn it off.
3. **Edge of strip**: at offset 0 / max offset, rubber-band and stop. Never forward the remaining delta to the system.
4. **SpaceManager bug**: `Space/SpaceManager.swift:76-85` returns the *first* display's "Current Space" for every display (the `return spaceId` on line 84 runs regardless of the display match). Match `Display Identifier` against `CGDisplayCreateUUIDFromDisplayID(displayId)` and fall back to "Main" only for the main display. Wrong Space IDs make Iume restore the wrong strip after a Space change, which looks like windows "jumping desktops".

**Acceptance**: 200 consecutive 2-finger swipes plus 50 three-finger swipes with Mission Control gestures at their defaults: zero Space changes. A window whose app has another window on Space 2 never pulls you to Space 2.

---

## 5. No overlapping windows (P0)

### Root causes
1. **Sliver parking** — `LayoutEngine/LayoutEngine.swift:224-232`:
   - columns left of the viewport are parked at `minVisibleX - colWidth + 12`, so **every** off-screen column overlaps the leftmost 12 px of the visible edge column;
   - columns right of the viewport are parked at `maxVisibleX - 12`, so they overlap the rightmost visible column;
   - the right-side threshold is `max(35, sliver)`, so a column jumps 23 px when it crosses it (visible jitter and a temporary gap/overlap).
   - inactive tabs are also parked at the left sliver (line 241).
2. macOS keeps part of a window inside the screen bounds, and on multi-monitor setups a window parked past an edge **spills onto the neighbouring display**.
3. Floating windows (incorrectly classified, §7.1) stay where they are over tiles.
4. Apps with a minimum width larger than the column (e.g. Xcode, Slack) end up wider than their column and overlap the next column.
5. `enforceStripZOrder` assumes it can order foreign windows; it can't, so overlapping areas show arbitrary stacking.

### Fixes
1. **Park fully off-screen on a safe side, 1 pt sliver max**:
   - Per display compute `safeParkSide`: the side (left, right or bottom) that has **no** adjacent display (`DisplayManager` knows all frames).
   - Off-screen columns are moved so that at most 1 pt remains on the display, on the safe side, and the remaining 1 pt sits inside the edge margin or the gap so it never covers a visible column.
   - If both horizontal sides have neighbours, park at the bottom-right corner (`x = maxX - 1`, `y = maxY - 1`), which never touches a horizontal neighbour.
   - All parked windows of a display share the same spot. That's fine: they're invisible, and none of them overlaps a visible column.
2. **No threshold jumps**: a column is positioned at its true strip X if *any* part intersects the visible frame; it's parked only when it's **completely** outside. Remove the 35 pt rule. Partially visible columns at the edges are clipped by the screen edge naturally, which is exactly what ChainYourMac shows.
3. **Respect real minimum widths**:
   - After every size write, read the size back (async, §2.5). If `actual.width > requested.width + 1`, store `column.minWidth = actual.width` and re-layout so the next column starts at the real right edge.
   - Use `AXMinSize` when the app exposes it.
   - `width` in the model must always be `max(width, minWidth)`.
4. **Floating windows**: correct classification (§7.1). Real floats (Calculator, dialogs) stay above tiles because their apps put them there; Iume doesn't need z-order.
5. Remove `enforceStripZOrder` (§2.3) and any code that depends on it.
6. Delete the duplicate `PureStripLayoutEngine` (`LayoutEngine.swift:717+`). It has its own sliver logic and will drift.

**Acceptance**: with 10 columns, scroll from start to end slowly and quickly. At every frame, visible windows' frames don't intersect (assert in a debug build), and no window appears on the neighbouring display.

---

## 6. Edges always together — one source of geometry (P0)

### Root causes
- Gap derivations differ:
  - `handleMouseUp:249` and `onSettleRequested:587` use `appsEdgeTogether ? 0 : windowGap`;
  - `applyLayout:1577` uses `smartWindowMargins && totalWins <= 1 ? 0 : windowGap`;
  - `reconcileExternalFrameChange` calls `columnStripOffsets(columns:)` **without** a gap.
- Width bases differ: `.scrollLeft/.scrollRight` (1188, 1197), `.centerColumn` (1235-1236), `applyScrollDelta` (2037), presets/nudge (1207-1241), insertion (1006) and the minimap use `visibleFrame.width`, while settle and `applyLayout` use `usableWidth` (minus edge margins). The max offset differs between paths → overscroll gap at the ends of the strip.
- `handleMouseUp` / `mouseStateDidEndDragging` (`2155+`) overwrite **every** column width from registry frames when they differ by > 1 pt. Clamped or stale frames become the new widths → gaps.
- `reflowColumnsForGeometryChange` (807) resets every width to the default ratio.
- Preset/nudge widths (`LayoutEngine.swift:563, 580, 595`) use `visibleWidth * ratio`, ignoring gaps, so 50% + 50% overflows by one gap.
- `computeLayout` skips columns without managed windows but `columnStripOffsets`, `totalStripWidth` and `maxScrollOffset` count them → positions disagree by one column width.
- `presetWidthRatios` default includes `1.0` in `init` but not in `resetToDefaults`.

### Fixes
1. **Introduce `StripGeometry`** and use it *everywhere* (layout, scroll, snap, presets, insertion, minimap, resize):
   ```swift
   public struct StripGeometry: Sendable, Equatable {
       public let visibleFrame: CGRect      // Dock- and menu-bar-aware
       public let margins: EdgeMargins
       public let gap: CGFloat
       public var originX: CGFloat { visibleFrame.minX + margins.left }
       public var usableWidth: CGFloat { max(200, visibleFrame.width - margins.left - margins.right) }
       public var usableHeight: CGFloat { max(200, visibleFrame.height - margins.top - margins.bottom) }

       /// niri formula: n columns of ratio 1/n exactly fill the usable width.
       public func width(forRatio p: CGFloat) -> CGFloat { floor((usableWidth + gap) * p - gap) }
       public func ratio(forWidth w: CGFloat) -> CGFloat { (w + gap) / (usableWidth + gap) }
   }

   extension WorkspaceManager {
       func geometry(for ws: DisplayWorkspace) -> StripGeometry {
           let tiled = ws.columns.filter { !$0.managedWindowIds(in: registry).isEmpty }.count
           let builtin = CGDisplayIsBuiltin(ws.displayGeometry.id) != 0
           let noPadding = (settings.smartWindowMargins && tiled <= 1)
               || (settings.disablePaddingOnBuiltinDisplay && builtin)
           return StripGeometry(
               visibleFrame: ws.displayGeometry.visibleFrame,
               margins: noPadding ? .zero : settings.edgeMargins,
               gap: (settings.appsEdgeTogether || noPadding) ? 0 : CGFloat(settings.windowGap))
       }
   }
   ```
   Then `grep -n "visibleFrame.width" WorkspaceManager.swift` must return only this function.
2. **Layout helpers take `StripGeometry`**, not loose `visibleWidth`/`gap` parameters, and all of them iterate the *same* filtered column list (columns whose windows are all floating or minimized are removed from the model, not skipped at render time).
3. **Store widths as ratios** (`column.widthRatio`) plus an optional `minWidth`. The pixel width is derived from `StripGeometry.width(forRatio:)`. Display/Dock changes then keep each user's choice instead of resetting (`reflowColumnsForGeometryChange` just re-derives).
4. **Mouse-up updates only the column the user resized** (§9). Never bulk-sync all widths from AX frames.
5. **Presets**: `[0.25, 1/3, 0.5, 2/3, 0.75]` via `width(forRatio:)`; "full width" is its own action. Make `init` and `resetToDefaults` share one `static let defaultPresets`.
6. **Max offset**: `max(0, totalStripWidth(geometry) - geometry.usableWidth)` in `.never` centre mode; one function, used by scroll, keyboard, settle and minimap.
7. **Edges flush to the display**: the first column's left edge = `originX` at offset 0, and the last column's right edge = `originX + usableWidth` at max offset. Snap targets are column left edges clamped to `[0, maxOffset]`, so a snap can never leave a gap at either end.
8. **Gap = 0 really means 0**: some apps (Terminal, iTerm2, Ghostty) round width to character cells. After read-back (§5.3), set the next column's X from the *actual* right edge, not the requested one, so cell rounding never opens a visible gap.

**Acceptance**: with gap 0, take screenshots after 50 random actions (scroll, presets, open, close, resize). No vertical strip of desktop is ever visible between adjacent windows or at the strip ends.

---

## 7. Nothing left behind — discovery & lifecycle (P0)

### Root causes
1. **Float at birth, forever**: `handleWindowCreated` (`WorkspaceManager.swift:941-976`) classifies once. New windows often report `kAXSize` *not settable* or a tiny size for a few hundred ms → classified float → registered → the duplicate guard (line 957) means they're never re-evaluated.
2. `WindowDiscovery.discoverWindows` calls `WindowClassifier.classify` without `floatSmallWindows` / `smallWindowThreshold`, so the legacy 0.35 ratio is used regardless of settings. `classifyWindow` always passes `cgWindowLayer: 0`.
3. **Unstable IDs**: when `_AXUIElementGetWindow` fails, IDs fall back to `CFHash(element)` (`WorkspaceManager.swift:952`, `WindowDiscovery.swift`), and discovery uses a *different* fallback (CG proximity match). The same window can get two IDs → one stays in the strip as a ghost slot (gap), the other isn't tiled.
4. **Display-blind handlers**: `handleWindowMiniaturized` (1041), `handleWindowDestroyed` (1058), `handleAppTerminated` (1071) only look at `workspaces[activeDisplayId]`. Windows on the other display leave a hole forever.
5. **Hidden apps** (⌘H): no `didHideApplicationNotification` handling → the column stays, an empty gap appears.
6. **Other Spaces**: discovery doesn't filter windows that aren't on the current Space. They take a slot (gap) and focusing them switches Space (§4).
7. **Native fullscreen** is checked only at creation (943). A tiled window that later goes fullscreen keeps its column.
8. Periodic reconcile runs every **60 s** and only when idle (`WorkspaceManager.swift:282-293`).
9. `WindowObserver` adds its run-loop source in `.defaultMode` only, so notifications are delayed during menu tracking, live resize and modal loops (`Observer/WindowObserver.swift`, `CFRunLoopAddSource(…, .defaultMode)`).

### Fixes
1. **Re-classification**:
   - Mark windows with `classificationIsProvisional = true` when they were floated because of non-settable size, small size or missing role/subrole.
   - Re-classify at +0.3 s, +1.0 s and +3.0 s after creation, and on their first resize notification. If they now classify as tile → insert beside the focused column (§8).
   - Pass `floatSmallWindows` and `smallWindowThreshold` from settings into **every** `classify` call. Pass the real CG layer from the catalog.
   - Add a status-bar item "Tile this window" / "Float this window" (the `toggleFloatWindow` action exists; surface it in the menu).
2. **One identity function**:
   ```swift
   func resolveWindowId(_ el: AXUIElement, pid: pid_t) -> WindowId? {
       if let cg = getCGWindowID(for: el) { return WindowId(pid: pid, rawId: UInt64(cg)) }
       return nil   // not ready yet → retry later, never invent a hash ID
   }
   ```
   Retry (0.15 s, 0.5 s, 1.5 s) when it returns nil. Remove the CFHash fallbacks.
3. **Display-aware removal**: `func locate(_ id: WindowId) -> (displayId, columnIndex)?` over *all* workspaces; use it in minimize, destroy, terminate, float toggle and fullscreen.
4. **Hide/unhide**: observe `NSWorkspace.didHideApplicationNotification` / `didUnhideApplicationNotification`. On hide, remove the app's columns and remember `(displayId, neighbour WindowId, widthRatio)`. On unhide, reinsert next to the remembered neighbour (or the focused column if it's gone).
5. **Current-Space filter**: build `onScreenIds = Set(CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID).map(kCGWindowNumber))`. Windows parked off-screen by Iume are still "on screen" in this list. Only windows in this set join the strip. On `activeSpaceDidChange`, swap to that Space's strip (already supported by `spaceWorkspaces`) and run a discovery pass.
6. **Native fullscreen**: on every resize notification read `AXFullScreen`. Entering → remove from the strip and remember the slot. Exiting → reinsert at the remembered slot. Never write frames to a fullscreen window.
7. **Reconcile loop**: every **3 s** while idle (not moving, mouse not down), run a cheap diff: CG on-screen window list vs registry. Only call AX for windows that are new or gone. Also run immediately after app launch, unhide, wake, display change and Space change.
8. **Observer**: add the run-loop source to `.commonModes`. Also register `kAXApplicationHiddenNotification` / `kAXApplicationShownNotification` and `kAXTitleChangedNotification` (for tab titles and persistence).
9. **Electron/Chromium**: keep `AXManualAccessibility`, and additionally set `AXEnhancedUserInterface = false` only for apps that need it (once per pid, §2.4) and **restore it** on quit/stop (`restoreEnhancedUIIfNeeded`, `WindowController.swift:48`, exists but is never called).
10. **Exclusions**: keep the defaults. Don't exclude `com.apple.SystemSettings` by default; float it instead (ChainYourMac floats its own settings and small utilities, but tiles System Settings if the user wants). Make it a per-app rule.

**Acceptance**: launch 15 apps (incl. Chrome with 3 windows, VS Code, Slack, Discord, Spotify, Ghostty, Finder 2 windows, Xcode, Calculator, System Settings). Within 1 s each tileable window is in the strip, Calculator floats, nothing is behind the strip, no empty slots. ⌘H on Slack closes its gap; un-hiding puts it back in the same place.

---

## 8. New windows open right next to the focused window (P1)

### Root causes
- `handleWindowCreated` uses `ws.focusedColumnIndex` first (`WorkspaceManager.swift:992-999`). That index goes stale because `handleFocusedWindowChanged` (1096) and `syncFocusToActivatedApp` (898) return early while `scrollController.isMoving`.
- `registerWindowsForApp` (836) runs on a schedule (0 / 0.15 / 0.5 / 1.5 / 4 s) and calls `controller.focus` for new windows → focus stealing and jumps.
- Per-app `fixedSlot` rules are classified (`WindowClassifier`) but `fixedColumnSlot` is dropped — it's never used by insertion.

### Fixes
1. **Focus is the source of truth**: never ignore focus changes during motion. Record them (`pendingFocusedId`) and apply when the spring settles, without scrolling if the window is already visible.
2. **Insertion index** = column index of `registry.focusedId` *on the target display*. Fall back to `ws.focusedColumnIndex`, then to the end. The target display is the display of the focused window, or the display under the mouse if nothing is focused.
3. **Insert to the right** (`.afterFocused`, default), with width = the default ratio via `StripGeometry`. Then:
   - user-initiated (frontmost app = new window's app, created < 1 s after a key/click in that app): focus it and scroll so it's fully visible with the **minimum** movement (keep the previously focused column visible if both fit);
   - background windows: insert without focus and without scrolling (no focus stealing).
4. **Fixed-slot rules**: pass `fixedColumnSlot` through to `insertWindow`; insert at `min(slot, columns.count)`.
5. `registerWindowsForApp` should only *register*; focusing belongs to the creation path above.
6. Animate the insertion (§10): neighbours slide right to open the slot.

**Acceptance**: focus column 3 of 6, press ⌘N in any app → the new window appears as column 4, focused, columns 4–6 shift right, no other column moves.

---

## 9. Manual resize — seamless, neighbours follow the edge (P1)

### Root causes (`reconcileExternalFrameChange`, `WorkspaceManager.swift:1798+`)
- The dragged edge is guessed from `abs(deltaLeft) < 10`. Fast drags guess wrong and move the wrong neighbour.
- Zero-sum with the adjacent column only (`combined` width). Columns beyond the neighbour don't move, so they overlap or leave gaps.
- The neighbour's frame is written synchronously inside `withAtomicScreenUpdates` from the AX callback.
- The global `observer.isPerformingProgrammaticUpdate` flag drops **all** move/resize events while Iume writes, including the user's ongoing drag.
- `isSelfOriginatedFrameChange` uses tolerances of 25–40 pt, so real user resizes under 40 pt are treated as Iume's own and ignored.
- Height ignores stacks. Results aren't clamped to the neighbour's minimum width.
- A 0.35 s timer then calls `handleMouseUp`, which bulk-overwrites widths (§6).

### Target behaviour
- Two modes in Settings → Layout → "When I resize a window":
  - **Neighbour follows edge (default)**: the seam moves; the window on the other side of the dragged edge shrinks/grows by the same amount; all other columns keep their widths. If the neighbour reaches its minimum width, the rest of the delta pushes the strip (columns beyond shift).
  - **Push strip (niri)**: the resized window changes width; every column on the far side of the dragged edge shifts by the delta and keeps its width.
- Either way: no overlap and no gap at any moment of the drag, at 60 fps.

### Implementation
1. **Detect the edge at mouse-down** (`MouseStateKeeper` already tracks mouse state): on left-mouse-down, if the cursor is within 8 pt of a managed window's left/right/top/bottom edge, store `ResizeSession(windowId, edge, startFrame, startColumns, startOffset)`. Use `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp])`.
2. **During the drag** (resize notifications for that window):
   ```swift
   let actual = readFrame(window)                     // what the app accepted
   switch session.edge {
   case .right:
       col.width = actual.width                        // follow the app, which already clamps to its min
       neighbourMode ? shrinkRightNeighbour(by: delta, clampTo: right.minWidth, overflowPushes: true)
                     : shiftColumns(after: colIdx, by: delta)
   case .left:
       // keep the right edge anchored; the left neighbour gives up width or the strip shifts left
       neighbourMode ? shrinkLeftNeighbour(by: delta, …) : shiftColumns(before: colIdx, by: -delta)
   case .top, .bottom:
       updateStackRatios(column: colIdx, windowId: id, newHeight: actual.height)   // stacked columns only
   }
   enqueueWrites(for: affectedWindowsExcept(session.windowId))  // never write the window being dragged
   ```
   - Writes go through the async latest-wins writer (§2.5), position-only for shifted columns, size + position for the resized neighbour.
   - If the dragged window is the last visible column and its right edge passes the display edge, scroll the viewport with it (so the edge stays under the cursor).
3. **Per-window suppression** instead of the global flag: `observer.suppress(windowId:, until:)` for windows Iume writes. Events from the window under resize are **never** suppressed.
4. **Tighten `isSelfOriginatedFrameChange`**: match only if the observed frame equals a pending expected frame within 2 pt (4 pt for size, to allow terminal cell rounding); expire expectations after 0.3 s.
5. **Mouse-up**: commit `widthRatio` for the resized column and neighbour (only those), clamp to `minWidth`, run one settled layout with animation off, persist. Delete the 0.35 s suppression timers.
6. **Drag-to-reorder** stays on mouse-up (current behaviour is correct), but compute midpoints with `StripGeometry`.
7. If the app refuses the size (read-back differs), adopt the app's size and re-flow the neighbour on the next frame. Never fight the app in a loop (max 1 correction per window per 100 ms).

**Acceptance**: drag the seam between Safari and Terminal left/right quickly for 10 s: the two windows always share one edge, other windows don't move (neighbour mode) or move rigidly (push mode), no flicker, no overlap, and on release the widths stay exactly where they were left.

---

## 10. Transitions (P1)

Use one animator for every layout change so scrolling and window changes feel identical.

1. **`LayoutTransition`**: given `from` and `to` frames per window, drive positions with the same `SpringState`/`MotionProfile` on the display link.
   - Position animates every frame (cheap).
   - Size changes are expensive for apps (they relayout). Apply growth at the start and shrink at the end, or step sizes at ≤ 30 Hz. Never animate size every frame for Electron/Chromium apps.
2. Animate: open (neighbours slide apart), close/minimize/hide (neighbours slide together), preset width / nudge / full width / centre, move column left/right, drag-reorder drop, stack/unstack, send to display (slide out of one strip, insert into the other), Space/strip restore.
3. Foreign windows can't fade or scale without SIP. Don't attempt opacity on other apps' windows (`CGSSetWindowAlpha` in `WindowController.swift:152-171` has no effect without SIP; remove it). Iume's own overlays (focus border, tab bar, minimap, dimming overlay) can fade.
4. Respect `settings.enableTransitions` **and** `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` (not checked anywhere today). With reduce motion: instant layout, overlays crossfade 120 ms.
5. Rename the toggle "Enable Smooth Transitions During Focus Change" → "Animate window changes", and make it cover everything in point 2.

---

## 11. ChainYourMac / TileMyMac feature parity

Legend: ✅ present and working · 🟡 present but needs the fix noted · ❌ missing

| Feature | Status | Evidence / what to do |
|---|---|---|
| Endless horizontal strip | 🟡 | Core exists. Fix lag (§2), smoothness (§3), overlap (§5), gaps (§6). |
| No account, no telemetry | ✅ | No `URLSession`/`URLRequest` anywhere in `Sources/`. Keep it that way; Sparkle (below) is the only network call. |
| Only the Accessibility permission | 🟡 | True, but the permission loop (§1) must be fixed. Don't add Screen Recording or Input Monitoring. |
| Automatic updates | ❌ | No Sparkle, no `SUFeedURL`. See §12.2. |
| New windows open beside the focused one | 🟡 | `.afterFocused` exists; stale index and focus stealing (§8). |
| Strip follows focus with a spring | 🟡 | Exists; unify the spring, don't drop focus changes during motion (§3, §8). |
| Layout persists across restarts per display & Space | 🟡 | `LayoutPersistenceManager` keys by `CGDirectDisplayID` + `ManagedSpaceID`, both unstable across reboots/replugs. See §12.3. |
| Stacks: pull/push into a column, reorder, taller/shorter | ✅ | `stackLeft/Right`, `unstack`, `nudgeStackTaller/Shorter`, `equalizeStackHeights` (`ShortcutManager.swift:122-168`). Add top/bottom edge resize (§9). |
| Tabbed columns with a tab bar | 🟡 | `toggleTabbedMode` + `TabBarOverlayController` (`UI/Overlays.swift:9`). Park inactive tabs with the new parking rule (§5.1); clicking a tab must switch tabs without a Space change (§4.2). |
| Preset widths 25/33/50/66/75, nudge, full width, centre | 🟡 | Present; math ignores the gap (§6.5). |
| Gaps & Dock-aware layout | 🟡 | Uses `visibleFrame`. Unify (§6.1). Re-read `visibleFrame` on Dock autohide/position change (observe `com.apple.dock.prefchanged` distributed notification + screen-parameters change). |
| One strip per display | ✅ | `workspaces[displayId]`. |
| Columns snap flush to the display edge | 🟡 | Parking spills onto neighbouring displays (§5.1); edges flush (§6.7). |
| Send window to next display | ✅ | `sendToNextDisplay` / `…Follow` (⌃⌥N / ⌃⌥⇧N). Keep the width ratio (convert via `StripGeometry`), animate (§10). |
| Disable per display | ✅ | `disabledDisplayIds` honoured in `applyLayout` and `applyPhysicalWindowPositions`. Key by display UUID (§12.3). |
| 3/4-finger 1:1 swipe that settles on the nearest column | 🟡 | MultitouchSupport reader exists; conflict with the macOS gesture (§4.1); unify physics (§3.1). |
| Strip minimap | ✅ | `MinimapHUDController`. Throttle to 30 Hz (§2.8) and use `StripGeometry` widths. |
| Focus border and dimming (off by default) | 🟡 | Both present and off by default. Dimming must use Iume's own overlay windows, not `CGSSetWindowAlpha` on foreign windows (§10.3). |
| Centre modes never / overflow / always | ✅ | `CenterMode`. Must use `StripGeometry` max offset (§6.6). |
| Drag to reorder | ✅ | On mouse-up. Fix midpoint geometry (§9.6). |
| Session restore | 🟡 | Matching by bundle + title; titles change (documents, browser tabs). Match by bundle + CG window number first (valid while the app keeps running across an Iume restart), then title, then order within the app. |
| Launch at login | ❌ (broken) | Settings toggle (`UI/SettingsView.swift:153`) only writes UserDefaults. `MacSetupChecker.setLaunchAtLogin` (`Diagnostics/MacSetupChecker.swift:200`) calls `SMAppService` but nothing calls it. Fix: in `SettingsStore.launchAtLogin.didSet` (or a sink) call `SMAppService.mainApp.register()/unregister()`, and initialise the toggle from `SMAppService.mainApp.status`. Handle `.requiresApproval` by opening Login Items settings. |
| No focus stealing | 🟡 | `InteractionManager.shouldFocusNewlyCreatedWindow` exists; `registerWindowsForApp` still focuses (§8.5). |
| Smart floating (Calculator, its own settings) | 🟡 | Classifier exists; over-floats new windows and never re-checks (§7.1). |
| Per-app rules: float, tile, fixed slot | 🟡 | Float/tile work; **fixed slot is never applied** (§8.4). Add a rules editor row "Width" (preset ratio per app). |
| Focus follows mouse / mouse follows focus (off by default) | ✅ | Present, off by default. FFM must ignore hover while scrolling or dragging and use a 120 ms dwell. |
| Guided start | 🟡 | `LaunchHUDController` + Mac Setup. Make first run: 1) permission card, 2) Mac Setup, 3) 20-second interactive tour (scroll, ⌃⌥←/→, presets). |
| Mac Setup checker (Rectangle, Magnet, …) | 🟡 | `MacSetupChecker.swift:126-148` detects Rectangle, Magnet, Amethyst, AeroSpace, yabai, Loop, Moom. Add: BetterSnapTool, BetterTouchTool window snapping, Divvy, Spectacle, Hammerspoon, PaperWM.spoon/Swish; Bluetooth trackpad + `-currentHost` keys (§4.3); `workspaces-auto-swoosh` (§4.2); "Displays have separate Spaces" off-by-default note; Stage Manager (exists). |
| Rebindable shortcuts, multiple bindings, non-US layouts | ❌ | `ShortcutManager.swift:94-193` hard-codes key codes. See §12.1. |
| Settings apply instantly | 🟡 | Most `@Published` settings are observed. Make sure gap, margins, presets, centre mode, smoothness (cached profile) and shortcut changes all re-apply without restart. |
| Native fullscreen left alone | 🟡 | Only checked at creation (§7.6). |

---

## 12. Upgrades to add

### 12.1 Rebindable shortcuts
- `ShortcutBinding { keyCode: UInt32; modifiers: UInt32 }`, `ShortcutStore: [ShortcutAction: [ShortcutBinding]]` persisted as JSON in the `com.iume.Iume` suite. Today's table becomes the default set.
- Register with `RegisterEventHotKey` (as now). Re-register on every store change (instant apply).
- Settings → Shortcuts: a list of actions; each row shows its bindings as chips (+ to add, × to remove) with a recorder (local `NSEvent` monitor for `.keyDown`, Esc cancels).
- Conflict detection: within Iume (same chord on two actions) and against system shortcuts (`CopySymbolicHotKeys`).
- Non-US layouts: key codes are physical positions, so they keep working. Display labels with `UCKeyTranslate` for the current input source (`KeyTranslator.swift` already exists) and refresh on `kTISNotifySelectedKeyboardInputSourceChanged`.
- Keep ⌃⌥ defaults (they avoid app conflicts); the legacy ⌥ set becomes a "preset" button.

### 12.2 Automatic updates (Sparkle 2)
- Add `https://github.com/sparkle-project/Sparkle` (2.x) to `Package.swift`; embed `Sparkle.framework` in `package.sh` and sign it with the same identity.
- `Info.plist`: `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks = YES`, `SUAutomaticallyUpdate = YES`.
- Requires the Developer ID certificate + notarization (`xcrun notarytool submit --wait`, `xcrun stapler staple`). Notarization also removes Gatekeeper translocation, which is another source of permission resets.
- Settings → General: "Check for updates automatically" + "Check now". The update keeps the same identity, so the Accessibility grant survives.

### 12.3 Stable persistence keys
- Display key = `CGDisplayCreateUUIDFromDisplayID(id)` string, not `CGDirectDisplayID`.
- Space key = the Space `uuid` from `CGSCopyManagedDisplaySpaces` (stable across reboots), not `ManagedSpaceID`.
- Migrate existing saved layouts on first launch (map the current ID → UUID; drop entries that can't be mapped).
- Persist `widthRatio`, stack ratios, tab state and order; save debounced 0.5 s (as now) **and** on quit/sleep.

### 12.4 Diagnostics
- "Copy diagnostics" in the status menu: macOS version, displays, Spaces, Mac Setup results, managed windows (app, ID, classification, column), last 200 log lines. No network upload.
- A hidden debug overlay (⌃⌥⇧D) drawing column bounds, parked windows and frame-time graph.

### 12.5 Cleanup
- Delete `PureStripLayoutEngine`, `CriticallyDampedSpring`, `enforceStripZOrder`, `CGSSetWindowAlpha` usage, `withAtomicScreenUpdates` on hot paths.
- Remove the unused entitlements (§1.6).
- `presetWidthRatios`: single default constant (§6.5).

---

## 13. Implementation order

| Phase | Work | Fixes issues |
|---|---|---|
| **1. Stop the bleeding** (½ day) | §1 signing/install/prompt; delete `enforceStripZOrder` from the frame loop; stop mutating `@Published workspaces` per frame; remove the duplicate settle callback. | 3, 4 (big immediate lag win) |
| **2. Geometry** (1–2 days) | `StripGeometry` everywhere; width ratios; remove bulk width sync on mouse-up; preset math; consistent column filtering; new parking rule. | 5, 6 |
| **3. Motion** (1–2 days) | Single spring + velocity projection; consume macOS momentum; `MotionProfile` + dial; per-screen display link; async latest-wins writer for settled frames. | 1, 3, 10 |
| **4. Spaces & focus** (1 day) | No `activate()` cross-Space; SpaceManager per-display fix; Mac Setup trackpad + swoosh checks; swipe-finger setting. | 7 |
| **5. Lifecycle** (1–2 days) | Provisional floats re-classification; stable IDs; display-aware handlers; hide/unhide; current-Space filter; fullscreen; 3 s reconcile; `.commonModes`. | 2, 5 |
| **6. Insertion & resize** (2 days) | Focus truth; insert beside focused; fixed-slot rules; resize sessions with both modes; per-window suppression. | 8, 9 |
| **7. Transitions & polish** (1–2 days) | `LayoutTransition`; Reduce Motion; overlay translation during scroll. | 11 |
| **8. Parity extras** (2–3 days) | Launch at login wiring; rebindable shortcuts; Sparkle + notarization; persistence UUID keys; Mac Setup additions; diagnostics. | 5, 6 (feature parity) |

---

## 14. Acceptance test checklist

Run on: MacBook built-in display (ProMotion) alone, plus built-in + one external display; Magic Trackpad and a mouse wheel.

**Permissions**
- [ ] 5 rebuild/reinstall cycles: permission stays granted, no prompt, no Settings window.
- [ ] Fresh install: exactly one permission card; granting it starts the strip within 1 s without relaunch.

**Smoothness & lag**
- [ ] Dial at 0: zero visible input lag; dial at 1: noticeably gliding; the difference is obvious.
- [ ] Fling lands on a column edge with no second correction.
- [ ] 20 windows, 10 s continuous scroll: main-thread frame work < 4 ms p95, no dropped frames.
- [ ] A hung app (e.g. `kill -STOP` its pid) doesn't stutter the strip.

**Desktop switching**
- [ ] 200 two-finger swipes + 50 three-finger swipes: no Space change.
- [ ] Focusing a column whose app has a window on another Space doesn't switch Space.

**Overlap & gaps**
- [ ] Debug assertion: visible managed windows never intersect during 5 minutes of mixed use.
- [ ] No window appears on the adjacent display while parked.
- [ ] Gap 0: no desktop visible between windows or at strip ends after 50 random actions.
- [ ] Two 50% columns exactly fill the display, with and without a gap.
- [ ] Xcode/Slack at a preset narrower than their min width: the next column starts at their real edge.

**Nothing left behind**
- [ ] 15-app launch test (§7) passes within 1 s.
- [ ] A window that starts tiny then grows gets tiled within 3 s.
- [ ] ⌘H removes the gap; unhide restores the slot.
- [ ] Minimize/close/quit on the *non-active* display closes the gap there.
- [ ] Native fullscreen in and out: the window leaves the strip and returns to its slot.
- [ ] Switching Spaces shows that Space's strip with only its windows.

**Insertion & resize**
- [ ] ⌘N from column 3 of 6 → new column 4, focused, only columns 4–6 shift.
- [ ] Background windows (notifications, downloads) don't steal focus or scroll.
- [ ] Seam drag, neighbour mode: shared edge at every frame; others don't move.
- [ ] Seam drag, push mode: everything beyond shifts rigidly.
- [ ] Widths persist after release, after display change and after an Iume restart.

**Parity**
- [ ] Launch at login toggle registers/unregisters `SMAppService` (check System Settings → Login Items).
- [ ] Rebind "focus right" to two chords, works immediately, survives restart, labels correct on a German layout.
- [ ] Sparkle finds and installs an update; permission survives it.
- [ ] Layout restores per display and per Space after a reboot.

---

## 15. Do / don't

- **Do** keep everything on public Accessibility APIs plus the read-only SkyLight calls already used (`CGSGetActiveSpace`, `CGSCopyManagedDisplaySpaces`, `_AXUIElementGetWindow`, `_SLPSSetFrontProcessWithOptions`).
- **Don't** rely on window ordering or alpha for other apps' windows (requires SIP off).
- **Don't** call AX synchronously on the main thread in any per-frame or per-event path.
- **Don't** reset TCC automatically or prompt more than once.
- **Don't** let the build script delete the installed app or sync to MEGA by default.
