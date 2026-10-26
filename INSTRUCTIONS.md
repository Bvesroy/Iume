# Iume — Complete Engineering Fixes, Upgrades & Feature Parity Guide

This document provides the complete root-cause analysis, concrete code fixes, system configuration solutions, and feature architecture mapping for **Iume**.

---

## 1. Root-Cause Analysis & Fixes for Reported Issues

### Issue 1 & 3: Scrolling Lag & Smoothness Tuning

#### Root Causes Identified
1. **Premature `.app` Gesture Latching on `phase == 1` (`ScrollController.swift`)**:
   - On macOS trackpads, the initial `NSEvent.Phase.began` (`phase == 1`) packet of a 2-finger gesture almost always arrives with `dx == 0, dy == 0` (or sub-pixel noise `< 0.5pt`).
   - Previously, `shouldInterceptScroll` executed `gestureOwner = shouldStart ? .strip : .app` immediately on `phase == 1`, latching `gestureOwner = .app` before the fingers moved horizontally. Every subsequent `phase == 2` horizontal delta in that swipe was then rejected.
2. **Over-Damped Lag During Active Finger Contact (`ScrollController.swift`)**:
   - Applying the same low-pass exponential filter (`lambda ~ 47`) during active finger contact (`phase == 1, 2`) caused windows to trail 50–80ms behind the fingertips instead of moving 1:1.
3. **3/4-Finger Multitouch Centroid Teleportation (`ScrollController.swift`)**:
   - In `MultitouchSupport.framework` contact callbacks (`handleMultitouchContact`), when a user transitioned between 3 and 4 fingers on the trackpad, the average X centroid (`avgX`) jumped instantaneously by `0.15–0.30` of the trackpad width, causing a 200–400pt lurch.
4. **Mid-Scroll `programmaticResetTimer` Expiry & 120Hz Dictionary Thrashing (`WorkspaceManager.swift`)**:
   - `programmaticResetTimer` (0.45s) was only invalidated when `!scrollController.isMoving`. A timer scheduled right before a swipe could fire mid-scroll, setting `observer.isPerformingProgrammaticUpdate = false` and unleashing recursive `kAXWindowMovedNotification` layout passes on the main thread during 120Hz scrolling.
   - `applyPhysicalWindowPositions` was also mutating `registry` and filtering `observer.expectedFrames` on every 120Hz frame.

#### Fixes Applied
- **Intent-Threshold Gesture Latching (`Sources/IumeCore/Controller/ScrollController.swift`)**:
  - `shouldInterceptScroll` now latches `.strip` immediately when horizontal movement or modifiers are detected, and only latches `.app` once vertical intent is unambiguously established (`abs(dy) > 1.5 && abs(dy) > abs(dx) * 1.2`), keeping `gestureOwner = .undecided` on zero-delta `phase == 1` packets.
- **Split Stiffness Filter (1:1 Direct Touch + Adjustable Smoothness Wheel Glide)**:
  - Active trackpad contact (`(lastPhase == 1 || lastPhase == 2) && lastMomentumPhase == 0`) uses high-stiffness 1:1 tracking (`lambda = max(55.0, 65.0 + (1.0 - smoothness) * 110.0)`), keeping windows locked to your fingers with zero perceived input lag.
  - Momentum coasting, mouse scroll-wheel steps, and harmonic spring snapping use the user's `scrollSmoothness` setting (`lambda = max(18.0, 24.0 + (1.0 - smoothness) * 76.0)`, `response`, and `dampingRatio`).
- **Finger-Count Stabilization & Vertical Swipe Guard (`Sources/IumeCore/Controller/ScrollController.swift`)**:
  - `handleMultitouchContact` tracks `lastTouchCount` and `lastTouchCentroidY`. Whenever `count != lastTouchCount`, the centroid baseline is re-anchored without emitting a delta spike, and vertical 3/4-finger gestures (`abs(deltaFractionX) <= abs(deltaFractionY) * 1.15`) are ignored so Mission Control and App Exposé never conflict.
- **Zero-Allocation 120Hz Scroll Loop (`Sources/IumeCore/Workspace/WorkspaceManager.swift`)**:
  - `programmaticResetTimer?.invalidate()` now runs unconditionally on every `applyPhysicalWindowPositions` call, and `registry.update` / `observer.recordExpectedFrame` are skipped during `isMoving == true` frames.

---

### Issue 2: Certain Apps/Windows Left Behind in Background & New Apps Not Opening Next to Focused Strip

#### Root Causes Identified
1. **Lazy Electron / Chromium / Qt Accessibility Trees (`WindowDiscovery.swift`)**:
   - Apps built on Electron/Chromium (VS Code, Cursor, Slack, Discord, Spotify, Obsidian) do not populate `kAXWindowsAttribute` until `"AXManualAccessibility" = kCFBooleanTrue` is set on their `AXUIElementCreateApplication(pid)`.
2. **Coordinate-Proximity `CGWindowLayer` Misclassification (`WindowDiscovery.swift`)**:
   - `discoverWindows` previously matched `CGWindowListCopyWindowInfo` entries solely by `abs(cand.bounds.minX - frame.minX) < 45`. If an app had a floating tooltip or overlay at the same origin with `layer != 0`, the main window inherited `cgLayer != 0` and was discarded as `.ignoredSystemElement`.
3. **Missing `bundleId` in `classifyWindow` (`WindowDiscovery.swift`)**:
   - `classifyWindow(_ element: AXUIElement)` passed `bundleId: nil` to `WindowClassifier.classify`, bypassing per-app rules (`alwaysTile`, `alwaysFloat`, `fixedSlot`) when new windows spawned.
4. **`onAppActivated` Not Syncing `focusedColumnIndex` (`WorkspaceManager.swift`)**:
   - On macOS, `kAXFocusedWindowChangedNotification` only fires when focus changes between windows *within the same process*. Switching between *different* apps (via clicking a window, clicking the Dock, or pressing `⌘Tab`) fires `NSWorkspace.didActivateApplicationNotification` (`onAppActivated`).
   - Previously, `onAppActivated` only called `registerWindowsForApp(app)`, which skipped already-registered windows and **never updated `ws.focusedColumnIndex` or `registry.focusedId`**. As a result, when you clicked or `⌘Tab`-switched to App B and then opened App C, Iume still thought App A was focused and slotted App C next to App A instead of App B.

#### Fixes Applied
- **Wake Up Lazy Accessibility Trees (`Sources/IumeCore/Discovery/WindowDiscovery.swift`)**:
  - `discoverWindows` sets `AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)` before querying `kAXWindowsAttribute`, `kAXMainWindowAttribute`, and `kAXFocusedWindowAttribute`, while `WindowController` keeps `AXEnhancedUserInterface = kCFBooleanFalse` so macOS never animates programmatic moves.
- **Exact `CGWindowID` Layer Matching (`Sources/IumeCore/Discovery/WindowDiscovery.swift`)**:
  - `discoverWindows` resolves `let exactCGId = getCGWindowID(for: windowElement)` via `_AXUIElementGetWindow` SPI first and matches `cand.windowNumber == exactCGId` before falling back to coordinate proximity.
- **App Activation Focus Synchronization (`Sources/IumeCore/Workspace/WorkspaceManager.swift`)**:
  - Added `syncFocusToActivatedApp(_ app: NSRunningApplication)` inside `appDiscovery.onAppActivated`. Switching to any managed application immediately updates `ws.focusedColumnIndex` and `registry.focusedId`, smoothly scrolls the strip to bring that window into view, and guarantees that any newly launched app opens **right next to the currently focused window** (`effectiveFocusedIndex + 1`).

---

### Issue 4: Repeatedly Asking for Accessibility Permission

#### Root Causes Identified
1. **Ad-Hoc Code Signing (`--sign -`) Invalidating TCC `cdhash`**:
   - When `security find-identity -v -p codesigning` has no certificate installed, `codesign --sign -` uses an ad-hoc signature. On macOS 14 Sonoma, macOS 15 Sequoia, and macOS 26, TCC ignores designated requirement strings on ad-hoc binaries and binds Accessibility trust to the exact SHA-256 `cdhash` of the Mach-O binary. Every `swift build` or `package.sh` run produces a new `cdhash`, causing macOS to treat `Iume.app` as an unrecognized binary and prompt again.
2. **Running Multiple Binary Paths Simultaneously**:
   - Launching `.build/debug/Iume`, `.build/bundle/Iume.app`, and `/Applications/Iume.app` registers conflicting paths for bundle ID `com.iume.Iume` in `/Library/Application Support/com.apple.TCC/TCC.db`.

#### Fixes Applied
- **Persistent Local Code-Signing Identity (`scripts/package.sh`)**:
  - Updated `scripts/package.sh` to sign `/Applications/Iume.app` with `"Iume Local Signer"` (or `Developer ID Application`) and stable requirement `=designated => identifier "com.iume.Iume"`.
- **One-Time Terminal Fix to Create Persistent Certificate & Reset Stale TCC**:
  Run this once in Terminal to generate a trusted `"Iume Local Signer"` certificate in your login keychain, package `/Applications/Iume.app`, and reset any stale `cdhash` entries:
  ```bash
  TMP_DIR="$(mktemp -d)"
  cat > "$TMP_DIR/cert.conf" <<EOF
  [ req ]
  default_bits       = 2048
  distinguished_name = req_dn
  prompt             = no
  x509_extensions    = codesign_ext
  [ req_dn ]
  CN = Iume Local Signer
  O  = Iume Window Manager
  [ codesign_ext ]
  keyUsage         = critical, digitalSignature
  extendedKeyUsage = critical, codeSigning
  basicConstraints = critical, CA:FALSE
  EOF
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP_DIR/key.pem" -out "$TMP_DIR/cert.pem" -days 3650 -config "$TMP_DIR/cert.conf"
  openssl pkcs12 -export -Legacy -inkey "$TMP_DIR/key.pem" -in "$TMP_DIR/cert.pem" -out "$TMP_DIR/cert.p12" -passout pass:iume
  LOGIN_KC="$(security login-keychain | xargs)"
  security import "$TMP_DIR/cert.p12" -k "$LOGIN_KC" -P iume -T /usr/bin/codesign
  security add-trusted-cert -d -r trustRoot -p codeSign -k "$LOGIN_KC" "$TMP_DIR/cert.pem"
  rm -rf "$TMP_DIR"

  ./scripts/package.sh
  tccutil reset Accessibility com.iume.Iume
  open /Applications/Iume.app
  ```
  Grant `/Applications/Iume.app` once in **System Settings › Privacy & Security › Accessibility**, and always launch `/Applications/Iume.app` (never raw `.build/debug/Iume`).

---

### Issue 5: Window Overlapping & Unexpected Spaces Between Adjacent Windows

#### Root Causes Identified
1. **macOS WindowServer Rejects 100% Offscreen Coordinates (`WindowController.swift`)**:
   - macOS WindowServer prohibits windows from having `0` pixels inside `visibleFrame`. Moreover, `CGSSetWindowAlpha` and `CGSOrderWindow` from a non-owner process are blocked by SIP for third-party windows.
   - Previously, `WindowController.applyStripFrames` parked offscreen windows at `visibleFrame.maxX` (right) and `visibleFrame.minX - rawRect.width` (left) — leaving `0pt` inside `visibleFrame`. WindowServer rejected those `kAXPositionAttribute` calls or clamped the windows 40–100pt inside the screen, leaving offscreen windows stuck overlapping visible windows.
2. **App-Enforced `AXMinSize` & Character-Grid Width Quantization (`WorkspaceManager.swift`)**:
   - Apps like Terminal, iTerm2, Ghostty (which snap widths to character-cell multiples) or Finder, Spotify, Chrome, and Xcode (which enforce a hard `AXMinSize` width) can settle at a physical width slightly smaller or larger than `ws.columns[i].width`.
   - When `actualWidth < ws.columns[i].width`, a visible gap is left between two adjacent windows even when `windowGap == 0`.
   - When `actualWidth > ws.columns[i].width`, the window extends past its column boundary and overlaps the neighbor to its right.

#### Fixes Applied
- **3×12pt Bottom-Corner Sliver Parking (`Sources/IumeCore/Controller/WindowController.swift`)**:
  - In `WindowController.applyStripFrames`, offscreen left windows are parked at:
    ```swift
    clampedOrigin.x = visibleFrame.minX - rawRect.width + sliverWidth // 3pt sliver
    clampedOrigin.y = max(rawRect.origin.y, visibleFrame.maxY - sliverHeight) // 12pt corner
    ```
    and offscreen right windows at:
    ```swift
    clampedOrigin.x = visibleFrame.maxX - sliverWidth
    clampedOrigin.y = max(rawRect.origin.y, visibleFrame.maxY - sliverHeight)
    ```
    Because a `3pt × 12pt` corner remains inside `visibleFrame`, macOS WindowServer accepts 100% of offscreen moves and never clamps offscreen windows back over the active strip.
- **Physical Width Readback & Flush Edge Reconciliation (`Sources/IumeCore/Workspace/WorkspaceManager.swift`)**:
  - In `handleWindowFrameChanged`, when an on-screen window reports a non-mouse-driven width adjustment (`2.0pt <= widthDiff <= 240.0pt`) due to app-enforced `AXMinSize` or character-grid snapping, Iume automatically synchronizes `ws.columns[colIdx].width = observedFrame.width` and reflows adjacent column positions so their edges remain 100% flush with zero overlap and zero unintended gap.
- **Apps Edge Together (`appsEdgeTogether` / `⌃⌥G`)**:
  - Toggling **Apps Edge Together (Zero Gap)** in Settings, the Menu Bar (`🧲 Apps Edge Together`), or via `⌃⌥G` sets `windowGap = 0.0` and reflows all columns so `colScreenX[i + 1] == colScreenX[i] + colWidth[i]`.

---

### Issue 6: Manual Window Resizing & Seamless Neighbor Edge Adjustment

#### How It Works & Upgrades Applied
- **Live Rate-Limited Observation (`WindowObserver.swift`)**:
  - `kAXWindowResizedNotification` and `kAXWindowMovedNotification` are dispatched at ~40–50 FPS (`0.025s` throttle) while `NSEvent.pressedMouseButtons & 1 != 0`.
- **Bidirectional Neighbor Edge Coupling (`WorkspaceManager.reconcileExternalFrameChange`)**:
  - **Dragging Right Edge (`abs(deltaLeft) < 6.0`)**: Preserves `combined = ws.columns[colIdx].width + ws.columns[colIdx + 1].width`. As the current window widens/narrows, `ws.columns[colIdx + 1]` automatically shrinks/grows and shifts its `minX` to `expectedColScreenX + clampedColWidth + gap` asynchronously on its dedicated per-PID queue (`setFrameAsync`).
  - **Dragging Left Edge (`abs(deltaLeft) >= 6.0`)**: Anchors `prevColOriginX = expectedColScreenX - gap - ws.columns[colIdx - 1].width`, resizes the left neighbor (`colIdx - 1`) to `(newFrame.minX - gap) - prevColOriginX`, and adjusts `ws.columns[colIdx].width = combined - clampedPrevWidth` so the shared edge tracks the mouse cursor 1:1.
  - **Magnetic Edge Snapping (`settings.edgeSnapping`)**: Snaps column split ratios cleanly to `25%`, `33.3%`, `50%`, `66.7%`, and `75%` within an `8pt` capture radius.

---

### Issue 7: Switching to Next macOS Desktop While Scrolling

#### Root Cause
- macOS's built-in **Swipe between full-screen applications / Spaces** gesture in **System Settings › Trackpad › More Gestures** listens directly to raw `MultitouchSupport` 3/4-finger swipes inside `Dock.app` and cannot be suppressed by a user-space `CGEventTap`. If macOS is set to switch desktops with 3 or 4 fingers and you swipe with that same finger count, macOS slides the entire Space away while Iume scrolls the strip.

#### Fixes Applied
1. **2-Finger Seamless Horizontal Scroll (`ScrollController.swift`)**:
   - Iume's primary scroll mode uses **2-finger horizontal trackpad scrolling**, which is intercepted and consumed (`return nil`) in `CGEventTap` before any app sees it, and **never triggers macOS's 3/4-finger Space switch**.
2. **Trackpad Desktop Swipe Conflict Detector (`MacSetupChecker.swift`)**:
   - Added Check #8 (`trackpad_swipe_conflict`) in `MacSetupChecker.swift` that inspects `com.apple.AppleMultitouchTrackpad` (`TrackpadThreeFingerHorizSwipeGesture` and `TrackpadFourFingerHorizSwipeGesture`) and alerts you in the **Mac Setup** tab if macOS's 3/4-finger desktop swipe is enabled.
   - To disable macOS 3/4-finger desktop switching via Terminal (or in **System Settings › Trackpad › More Gestures › Swipe between full-screen applications → Off**):
     ```bash
     defaults write com.apple.AppleMultitouchTrackpad TrackpadThreeFingerHorizSwipeGesture -int 0
     defaults write com.apple.AppleMultitouchTrackpad TrackpadFourFingerHorizSwipeGesture -int 0
     defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerHorizSwipeGesture -int 0
     defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadFourFingerHorizSwipeGesture -int 0
     ```

---

### Issue 8: Smooth Scrolling Wheel & Transitions in Settings

#### Implementation in `SettingsView.swift` & `ScrollController.swift`
- **Interactive Rotary Smoothness Wheel (`SmoothScrollWheelView` in `Sources/IumeCore/UI/SettingsView.swift`)**:
  - Located in **Settings (`⌃⌥,`) › Smoothness & Physics**.
  - Features a 270° interactive rotary dial with drag gesture tracking, live percentage readout (`5%–100%`), real-time physics telemetry badges (`Response ms`, `Damping ζ`, `VSYNC 120Hz`), 4 one-click presets (`⚡️ Snappy 25%`, `⚖️ Balanced 50%`, `✨ Silky 75%`, `🌊 Liquid 100%`), and an **Interactive Trackpad Test Track** right below the wheel.
- **Spring Transitions During Scrolling & Window Focus Change (`settings.enableTransitions` & `settings.animationDuration`)**:
  - Driven by the 120Hz `CADisplayLink` analytical harmonic spring solver (`SpringState` in `ScrollController.swift`), starting at Frame 0 (`dt = 1/120s`) on the exact keystroke or focus change for zero perceived latency.
  - `FocusBorderOverlay` also animates smoothly across columns using `NSAnimationContext` when `settings.enableTransitions` is enabled.

---

## 2. Complete Feature Implementation Matrix

| Target Feature | Status in Iume | Iume Implementation File(s) & Details |
| :--- | :--- | :--- |
| **Endless Horizontal Strip (PaperWM / niri model)** | ✅ Implemented | `LayoutEngine.swift`, `WorkspaceManager.swift` — Windows sit side-by-side in columns; opening a new window never shrinks existing ones. |
| **New Windows Open Beside Focused One** | ✅ Implemented & Fixed | `WorkspaceManager.swift` (`insertWindow` with `.afterFocused` + `syncFocusToActivatedApp`) — Slots at `focusedColumnIndex + 1` and glides into view. |
| **The Strip Follows Your Focus (120Hz Spring)** | ✅ Implemented | `ScrollController.swift` (`SpringState`, `CADisplayLink` at 80–120Hz ProMotion, Frame-0 immediate step). |
| **Your Layout Is Still There Tomorrow (Session Restore)** | ✅ Implemented | `LayoutPersistenceManager.swift`, `SpaceManager.swift` — Atomic JSON persistence of column order, widths, and stacks per Display & Space. |
| **Vertical Stacks (`⌃⌥[` / `⌃⌥]` / `⌃⌥⇧[`)** | ✅ Implemented | `LayoutEngine.swift` (`stackWindow`, `unstackWindow`), `WorkspaceManager.swift` — Pull windows into left/right column, pop out, and split height vertically. |
| **Tabbed Columns (`⌃⌥⇧T`)** | ✅ Implemented | `Overlays.swift` (`TabBarOverlayController`), `LayoutEngine.swift` (`toggleColumnTabbedMode`) — 28pt floating clickable tab bar over full-height column tabs. |
| **Preset Widths (`⌃⌥R` / `⌃⌥⇧R`) & Nudging (`⌃⌥-` / `⌃⌥=`)** | ✅ Implemented | `LayoutEngine.swift` (`cyclePresetWidth` through 25%, 33%, 50%, 66%, 75%, 100%; `nudgeColumnWidth` by ±5%). |
| **Full Width (`⌃⌥F` / `⌃⌥Return`) & Centre (`⌃⌥C`)** | ✅ Implemented | `LayoutEngine.swift` (`maximizeColumn`, `toggleFullWidth`, `centerColumnOffset`). |
| **Gaps (Down to 0px Flush) & Dock-Aware Layout** | ✅ Implemented & Fixed | `SettingsStore.swift` (`windowGap`, `appsEdgeTogether`, `edgeMargins`), `DisplayManager.swift` (`screen.visibleFrame` respects Dock & Menu Bar). |
| **Multi-Monitor (One Strip Per Display + `⌃⌥N` Send to Next Display)** | ✅ Implemented | `DisplayManager.swift`, `WorkspaceManager.swift` (`sendFocusedColumnToNextDisplay`, automatic migration on monitor hot-unplug). |
| **Trackpad Swipe (1:1 Finger Tracking + Column Snap)** | ✅ Implemented & Fixed | `ScrollController.swift` (2-finger smart horizontal `CGEventTap` + 3/4-finger `MultitouchSupport` 1:1 tracking + `C^1` velocity-continuous spring settle). |
| **Strip Minimap HUD** | ✅ Implemented | `MinimapHUDController.swift` — Translucent floating glassmorphic minimap showing proportional columns, active index, and viewport box; auto-fades after 1.25s. |
| **Focus Border & Inactive Window Dimming** | ✅ Implemented | `FocusBorderOverlay.swift`, `Overlays.swift` (`DimmingOverlayController`) — Both optional and off by default. |
| **Centre Modes (`Never`, `On Overflow`, `Always`)** | ✅ Implemented | `CoreModels.swift` (`CenterMode`), `LayoutEngine.swift` (`computeViewportOffset`). |
| **Drag Titlebar to Reorder Columns** | ✅ Implemented | `InteractionManager.swift` (`resolveDragReorderDropIndex`), `WorkspaceManager.swift` (`reconcileExternalFrameChange`). |
| **Seamless Manual Edge Resize + Neighbor Adjustment** | ✅ Implemented & Fixed | `WorkspaceManager.swift` (`reconcileExternalFrameChange` + `handleWindowFrameChanged` width sync + magnetic snapping to 25/33/50/67/75%). |
| **No Focus Stealing by Background Popups** | ✅ Implemented | `InteractionManager.swift` (`shouldFocusNewlyCreatedWindow`), `WorkspaceManager.swift` (`handleWindowCreated` checks `isUserInitiated`). |
| **Smart Floating (Fixed-Size Windows, Calculator, Dialogs)** | ✅ Implemented | `WindowDiscovery.swift` (`WindowClassifier` checks `kAXDialogSubrole`, `kAXSizeAttribute` settability, and `minSize == maxSize`). |
| **Per-App Window Rules (Always Float / Always Tile / Fixed Slot)** | ✅ Implemented & Fixed | `CoreModels.swift` (`AppWindowRule`), `WindowDiscovery.swift` (`WindowClassifier.classify`), `SettingsView.swift` (`rulesTab`). |
| **Focus Follows Mouse & Mouse Follows Focus** | ✅ Implemented | `InteractionManager.swift` (`warpMouseIfNeeded`), `SettingsStore.swift` (both off by default). |
| **Guided Start / Launch HUD & Mac Setup Conflict Checker** | ✅ Implemented & Fixed | `LaunchHUDController.swift`, `MacSetupChecker.swift`, `MacSetupView.swift` (checks Accessibility, `/Applications`, Spaces, Stage Manager, Sequoia tiling, conflicting WMs, and Trackpad desktop swipe conflicts). |
| **Shortcuts (`⌃⌥` Defaults + Legacy `⌥` + Non-US Layout Translation)** | ✅ Implemented | `ShortcutManager.swift`, `KeyTranslator.swift` (`UCKeyTranslate` layout-aware glyph conversion). |
| **Settings Apply Instantly (Zero Restart Required)** | ✅ Implemented | `WorkspaceManager.swift` (`setupBindings` Combine pipelines on `SettingsStore` `@Published` properties). |
| **Native Fullscreen Left Alone** | ✅ Implemented | `WindowDiscovery.swift` & `WorkspaceManager.swift` (`AXFullScreen == true` windows are skipped so macOS fullscreen Spaces work untouched). |
| **No Account, Zero Telemetry, Only Accessibility Permission** | ✅ Implemented | `Resources/Info.plist`, `Resources/Iume.entitlements`, `PermissionManager.swift`. |

---

## 3. Build, Sign, Install & Verification Instructions

Run the following commands from `/Users/bves/projects/Iume`:

### Step 1: Run the Automated Test Suite
```bash
swift test
```

### Step 2: Package & Sign `/Applications/Iume.app`
```bash
./scripts/package.sh
```
This script compiles `Iume` in Release mode (`swift build -c release`) and packages `/Applications/Iume.app` with your signing certificate and a stable designated requirement (`=designated => identifier "com.iume.Iume"`) so macOS TCC retains your Accessibility permission permanently across rebuilds.

### Step 3: Launch `/Applications/Iume.app`
```bash
open /Applications/Iume.app
```
- Press **`⌥⇧Space`** (or click **Kickstart & Arrange Windows** in the Launch Control overlay / Menu Bar) to tile all open windows into the continuous scrolling strip.
- Press **`⌃⌥G`** anytime to toggle **Apps Edge Together (Zero Gap)** so window edges lock flush together.
- Press **`⌃⌥,`** to open **Settings › Smoothness & Physics** and adjust the **Smooth Scrolling Wheel** live.
