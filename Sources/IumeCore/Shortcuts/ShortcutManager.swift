import Foundation
import Carbon
import AppKit

/// Action types triggered by keyboard shortcuts.
public enum ShortcutAction: String, CaseIterable, Codable, Hashable, Sendable {
    case focusLeft = "Focus Left"
    case focusRight = "Focus Right"
    case focusUp = "Focus Up"
    case focusDown = "Focus Down"
    case moveColumnLeft = "Move Column Left"
    case moveColumnRight = "Move Column Right"
    case toggleZoom = "Toggle Zoom"
    case closeWindow = "Close Window"
    case cycleNext = "Cycle Next Window"
    case cyclePrev = "Cycle Previous Window"
    case scrollLeft = "Scroll Viewport Left"
    case scrollRight = "Scroll Viewport Right"
    case cycleWidth = "Cycle Column Width"
    case cycleWidthBackward = "Cycle Column Width (Backward)"
    case nudgeWider = "Nudge Column Wider"
    case nudgeNarrower = "Nudge Column Narrower"
    case centerColumn = "Center Column"
    case fullWidth = "Full Width"
    case stackLeft = "Pull / Stack into Left Column"
    case stackRight = "Pull / Stack into Right Column"
    case unstack = "Pop / Unstack Window"
    case toggleTabbedMode = "Toggle Stacked vs. Tabbed Column"
    case tabSameAppWindows = "Tab Windows of Same App Together"
    case tabAllSameAppWindows = "Tab All Same-App Windows"
    case nextTab = "Next Tab in Column"
    case prevTab = "Previous Tab in Column"
    case newTab = "New Tab in Column"
    case closeTab = "Close Active Tab"
    case detachTab = "Detach Active Tab into Its Own Column"
    case toggleTabBarPin = "Keep Tab Bar Visible"
    case ungroupActiveTab = "Ungroup All Tabs in Active Column"
    case selectTab1 = "Select Tab 1"
    case selectTab2 = "Select Tab 2"
    case selectTab3 = "Select Tab 3"
    case selectTab4 = "Select Tab 4"
    case selectTab5 = "Select Tab 5"
    case selectTab6 = "Select Tab 6"
    case selectTab7 = "Select Tab 7"
    case selectTab8 = "Select Tab 8"
    case selectLastTab = "Select Last Tab (Tab 9)"
    case moveTabLeft = "Reorder Active Tab Left"
    case moveTabRight = "Reorder Active Tab Right"
    case sendToNextDisplay = "Send to Next Display"
    case sendToNextDisplayFollow = "Send to Next Display & Follow"
    case switchWorkspace1 = "Switch to Workspace 1"
    case switchWorkspace2 = "Switch to Workspace 2"
    case switchWorkspace3 = "Switch to Workspace 3"
    case switchWorkspace4 = "Switch to Workspace 4"
    case switchWorkspace5 = "Switch to Workspace 5"
    case switchWorkspace6 = "Switch to Workspace 6"
    case switchWorkspace7 = "Switch to Workspace 7"
    case switchWorkspace8 = "Switch to Workspace 8"
    case switchWorkspace9 = "Switch to Workspace 9"
    case moveWorkspace1 = "Move Window to Workspace 1"
    case moveWorkspace2 = "Move Window to Workspace 2"
    case moveWorkspace3 = "Move Window to Workspace 3"
    case moveWorkspace4 = "Move Window to Workspace 4"
    case moveWorkspace5 = "Move Window to Workspace 5"
    case moveWorkspace6 = "Move Window to Workspace 6"
    case moveWorkspace7 = "Move Window to Workspace 7"
    case moveWorkspace8 = "Move Window to Workspace 8"
    case moveWorkspace9 = "Move Window to Workspace 9"
    case kickstart = "Kickstart & Arrange Windows"
    case stopAndRestore = "Stop & Restore Windows"
    case toggleAppsEdgeTogether = "Toggle Apps Edge Together"
    case toggleMagneticSnapping = "Toggle Magnetic Window Snapping"
    case toggleLoopMode = "Toggle Loop Mode (Circular Strip)"
    case openSettings = "Open Settings"
    case focusFirst = "Focus First Column"
    case focusLast = "Focus Last Column"
    case nudgeStackTaller = "Nudge Stacked Window Taller"
    case nudgeStackShorter = "Nudge Stacked Window Shorter"
    case equalizeStackHeights = "Equalize Stack Heights"
    case toggleFloatWindow = "Float / Unfloat Active Window"
    case throwSpaceLeft = "Throw Window to Left Space"
    case throwSpaceRight = "Throw Window to Right Space"
    case focusDisplay1 = "Focus Display 1"
    case focusDisplay2 = "Focus Display 2"
    case focusDisplay3 = "Focus Display 3"
    case reevaluateWindows = "Re-evaluate Windows"
    case relaunchIume = "Relaunch Iume"
    case toggleOverview = "Toggle Strip Overview"
    case cycleLayoutMode = "Cycle Layout Mode (Strip / Grid / Row / Column / Tall / Wide / BSP)"
    case tileAllToGrid = "Tile Open Windows to Grid"
    case tileAllToTall = "Tile Open Windows to Tall"
    case balanceSizes = "Balance All Window Sizes"
    case swapWindowWithMain = "Swap Active Window with Main"
    case snapLeftHalf = "Snap to Left Half"
    case snapRightHalf = "Snap to Right Half"
    case snapTopHalf = "Snap to Top Half"
    case snapBottomHalf = "Snap to Bottom Half"
    case snapTopLeft = "Snap to Top-Left Quarter"
    case snapTopRight = "Snap to Top-Right Quarter"
    case snapBottomLeft = "Snap to Bottom-Left Quarter"
    case snapBottomRight = "Snap to Bottom-Right Quarter"
    case snapFirstThird = "Snap to First Third"
    case snapCenterThird = "Snap to Center Third"
    case snapLastThird = "Snap to Last Third"
    case snapMaximize = "Maximize Active Window"
    case snapAlmostMaximize = "Almost Maximize Window"
    case snapCenter = "Center Active Window"
    case scaleLarger = "Expand Window (Larger)"
    case scaleSmaller = "Shrink Window (Smaller)"
    case openRadialMenu = "Open Radial Snap Menu (Loop Style)"
    case openCustomBoxGrid = "Open Custom Box & Grid Studio"
    case showCheatsheet = "Show Keyboard Shortcut Cheatsheet"
}

/// Global shortcut manager using native Carbon EventHotKey APIs.
@MainActor
public final class ShortcutManager {
    public static let shared = ShortcutManager()
    
    public var onShortcutTriggered: ((ShortcutAction) -> Void)?
    
    private var registeredHotKeys: [UInt32: (EventHotKeyRef, ShortcutAction)] = [:]
    private var eventHandlerRef: EventHandlerRef?
    
    public init() {
        installEventHandler()
    }
    
    // MARK: - Registration
    
    public func registerDefaultShortcuts() {
        unregisterAll()
        
        let opt = UInt32(optionKey)
        let optShift = UInt32(optionKey | shiftKey)
        let ctrlOpt = UInt32(controlKey | optionKey)
        let ctrlOptShift = UInt32(controlKey | optionKey | shiftKey)
        let ctrlOptCmd = UInt32(controlKey | optionKey | cmdKey)
        
        // 1. Directional Focus Navigation (⌃⌥ + Arrow keys & ⌃⌥ + H/J/K/L)
        register(action: .focusLeft, keyCode: 0x7B, modifiers: ctrlOpt, id: 1) // Ctrl + Opt + Left
        register(action: .focusRight, keyCode: 0x7C, modifiers: ctrlOpt, id: 2) // Ctrl + Opt + Right
        register(action: .focusDown, keyCode: 0x7D, modifiers: ctrlOpt, id: 3) // Ctrl + Opt + Down
        register(action: .focusUp, keyCode: 0x7E, modifiers: ctrlOpt, id: 4) // Ctrl + Opt + Up
        
        register(action: .focusLeft, keyCode: 0x04, modifiers: ctrlOpt, id: 5) // Ctrl + Opt + H
        register(action: .focusRight, keyCode: 0x25, modifiers: ctrlOpt, id: 6) // Ctrl + Opt + L
        register(action: .focusDown, keyCode: 0x26, modifiers: ctrlOpt, id: 7) // Ctrl + Opt + J
        register(action: .focusUp, keyCode: 0x28, modifiers: ctrlOpt, id: 8) // Ctrl + Opt + K
        
        // 2. Column Moving (⌃⌥⇧ + Arrow keys & ⌃⌥⇧ + H/L)
        register(action: .moveColumnLeft, keyCode: 0x7B, modifiers: ctrlOptShift, id: 9) // Ctrl + Opt + Shift + Left
        register(action: .moveColumnRight, keyCode: 0x7C, modifiers: ctrlOptShift, id: 10) // Ctrl + Opt + Shift + Right
        register(action: .moveColumnLeft, keyCode: 0x04, modifiers: ctrlOptShift, id: 11) // Ctrl + Opt + Shift + H
        register(action: .moveColumnRight, keyCode: 0x25, modifiers: ctrlOptShift, id: 12) // Ctrl + Opt + Shift + L
        
        // 3. Preset Width Cycling & Nudging (⌃⌥R, ⌃⌥⇧R, ⌃⌥-, ⌃⌥=)
        register(action: .cycleWidth, keyCode: 0x0F, modifiers: ctrlOpt, id: 13) // Ctrl + Opt + R (Forward)
        register(action: .cycleWidthBackward, keyCode: 0x0F, modifiers: ctrlOptShift, id: 14) // Ctrl + Opt + Shift + R (Backward)
        register(action: .nudgeNarrower, keyCode: 0x1B, modifiers: ctrlOpt, id: 15) // Ctrl + Opt + - (Narrower)
        register(action: .nudgeWider, keyCode: 0x18, modifiers: ctrlOpt, id: 16) // Ctrl + Opt + = (Wider)
        
        // 4. Center & Full Width (⌃⌥C, ⌃⌥F, ⌃⌥ Return)
        register(action: .centerColumn, keyCode: 0x08, modifiers: ctrlOpt, id: 17) // Ctrl + Opt + C
        register(action: .fullWidth, keyCode: 0x03, modifiers: ctrlOpt, id: 18) // Ctrl + Opt + F
        register(action: .fullWidth, keyCode: 0x24, modifiers: ctrlOpt, id: 19) // Ctrl + Opt + Enter
        
        // 5. Stacking, Popping & Tabs (⌃⌥[, ⌃⌥], ⌃⌥⇧[, ⌃⌥⇧], ⌃⌥⇧T, ⌃⌥T)
        register(action: .stackLeft, keyCode: 0x21, modifiers: ctrlOpt, id: 20) // Ctrl + Opt + [
        register(action: .stackRight, keyCode: 0x1E, modifiers: ctrlOpt, id: 21) // Ctrl + Opt + ]
        register(action: .unstack, keyCode: 0x21, modifiers: ctrlOptShift, id: 22) // Ctrl + Opt + Shift + [
        register(action: .unstack, keyCode: 0x1E, modifiers: ctrlOptShift, id: 23) // Ctrl + Opt + Shift + ]
        register(action: .toggleTabbedMode, keyCode: 0x11, modifiers: ctrlOptShift, id: 24) // Ctrl + Opt + Shift + T
        register(action: .tabSameAppWindows, keyCode: 0x11, modifiers: ctrlOpt, id: 80) // Ctrl + Opt + T (Tab Same App)
        register(action: .tabAllSameAppWindows, keyCode: 0x11, modifiers: ctrlOptCmd, id: 81) // Ctrl + Opt + Cmd + T (Tab All Same App)
        register(action: .nextTab, keyCode: 0x1E, modifiers: ctrlOptCmd, id: 82) // Ctrl + Opt + Cmd + ] (Next Tab)
        register(action: .prevTab, keyCode: 0x21, modifiers: ctrlOptCmd, id: 83) // Ctrl + Opt + Cmd + [ (Prev Tab)
        register(action: .newTab, keyCode: 0x2D, modifiers: ctrlOptCmd, id: 84) // Ctrl + Opt + Cmd + N (New Tab)
        register(action: .ungroupActiveTab, keyCode: 0x20, modifiers: ctrlOptShift, id: 85) // Ctrl + Opt + Shift + U (Ungroup Tabs)
        register(action: .closeTab, keyCode: 0x0D, modifiers: ctrlOptShift, id: 86) // Ctrl + Opt + Shift + W (Close Tab)
        register(action: .detachTab, keyCode: 0x02, modifiers: ctrlOptCmd, id: 87) // Ctrl + Opt + Cmd + D (Detach Tab)
        register(action: .toggleTabBarPin, keyCode: 0x23, modifiers: ctrlOptShift, id: 88) // Ctrl + Opt + Shift + P (Pin Tab Bar)
        
        // Tab Reordering (⌃⌥⇧ [ / ] & ⌃⌥⇧ ← / →)
        register(action: .moveTabLeft, keyCode: 0x21, modifiers: ctrlOptShift, id: 90) // Ctrl + Opt + Shift + [
        register(action: .moveTabRight, keyCode: 0x1E, modifiers: ctrlOptShift, id: 91) // Ctrl + Opt + Shift + ]
        
        // Direct Tab Selection by Position (⌃⌥⌘ 1...8 and ⌃⌥⌘ 9 for Last Tab)
        let tabPositionKeys: [(UInt32, ShortcutAction)] = [
            (0x12, .selectTab1), // 1
            (0x13, .selectTab2), // 2
            (0x14, .selectTab3), // 3
            (0x15, .selectTab4), // 4
            (0x17, .selectTab5), // 5
            (0x16, .selectTab6), // 6
            (0x1A, .selectTab7), // 7
            (0x1C, .selectTab8), // 8
            (0x19, .selectLastTab) // 9
        ]
        var tabKeyId: UInt32 = 190
        for (kc, tabAct) in tabPositionKeys {
            register(action: tabAct, keyCode: kc, modifiers: ctrlOptCmd, id: tabKeyId)
            tabKeyId += 1
        }
        
        // 6. Displays (⌃⌥N, ⌃⌥⇧N)
        register(action: .sendToNextDisplay, keyCode: 0x2D, modifiers: ctrlOpt, id: 25) // Ctrl + Opt + N
        register(action: .sendToNextDisplayFollow, keyCode: 0x2D, modifiers: ctrlOptShift, id: 26) // Ctrl + Opt + Shift + N
        
        // 7. Virtual Workspaces (⌃⌥ 1...9 & ⌃⌥⇧ 1...9)
        let numKeyCodes: [(UInt32, ShortcutAction, ShortcutAction)] = [
            (0x12, .switchWorkspace1, .moveWorkspace1),
            (0x13, .switchWorkspace2, .moveWorkspace2),
            (0x14, .switchWorkspace3, .moveWorkspace3),
            (0x15, .switchWorkspace4, .moveWorkspace4),
            (0x17, .switchWorkspace5, .moveWorkspace5),
            (0x16, .switchWorkspace6, .moveWorkspace6),
            (0x1A, .switchWorkspace7, .moveWorkspace7),
            (0x1C, .switchWorkspace8, .moveWorkspace8),
            (0x19, .switchWorkspace9, .moveWorkspace9),
        ]
        var nextId: UInt32 = 100
        for (kc, switchAct, moveAct) in numKeyCodes {
            register(action: switchAct, keyCode: kc, modifiers: ctrlOpt, id: nextId)
            nextId += 1
            register(action: moveAct, keyCode: kc, modifiers: ctrlOptShift, id: nextId)
            nextId += 1
        }
        
        // 8. Window Control & Cycling
        register(action: .closeWindow, keyCode: 0x0D, modifiers: ctrlOpt, id: 27) // Ctrl + Opt + W
        register(action: .cycleNext, keyCode: 0x30, modifiers: ctrlOpt, id: 28) // Ctrl + Opt + Tab
        register(action: .cyclePrev, keyCode: 0x30, modifiers: ctrlOptShift, id: 29) // Ctrl + Opt + Shift + Tab
        
        // 9. Kickstart, Stop & Extended Chords
        register(action: .kickstart, keyCode: 0x31, modifiers: ctrlOpt, id: 30) // Ctrl + Opt + Space
        register(action: .stopAndRestore, keyCode: 0x0C, modifiers: ctrlOpt, id: 31) // Ctrl + Opt + Q
        register(action: .stopAndRestore, keyCode: 0x01, modifiers: ctrlOptShift, id: 32) // Ctrl + Opt + Shift + S
        register(action: .toggleAppsEdgeTogether, keyCode: 0x05, modifiers: ctrlOpt, id: 33) // Ctrl + Opt + G
        register(action: .openSettings, keyCode: 0x2B, modifiers: ctrlOpt, id: 34) // Ctrl + Opt + ,
        register(action: .focusFirst, keyCode: 0x7B, modifiers: ctrlOptCmd, id: 35) // Ctrl + Opt + Cmd + Left
        register(action: .focusLast, keyCode: 0x7C, modifiers: ctrlOptCmd, id: 36) // Ctrl + Opt + Cmd + Right
        register(action: .nudgeStackTaller, keyCode: 0x18, modifiers: ctrlOptShift, id: 37) // Ctrl + Opt + Shift + =
        register(action: .nudgeStackShorter, keyCode: 0x1B, modifiers: ctrlOptShift, id: 38) // Ctrl + Opt + Shift + -
        register(action: .equalizeStackHeights, keyCode: 0x1D, modifiers: ctrlOpt, id: 39) // Ctrl + Opt + 0
        register(action: .toggleFloatWindow, keyCode: 0x03, modifiers: ctrlOptShift, id: 40) // Ctrl + Opt + Shift + F
        register(action: .toggleMagneticSnapping, keyCode: 0x2E, modifiers: ctrlOpt, id: 41) // Ctrl + Opt + M
        
        // 10. Advanced Power-User Operations (Focus Displays, Reevaluate, Relaunch)
        register(action: .focusDisplay1, keyCode: 0x12, modifiers: ctrlOptCmd, id: 70) // Ctrl + Opt + Cmd + 1
        register(action: .focusDisplay2, keyCode: 0x13, modifiers: ctrlOptCmd, id: 71) // Ctrl + Opt + Cmd + 2
        register(action: .focusDisplay3, keyCode: 0x14, modifiers: ctrlOptCmd, id: 72) // Ctrl + Opt + Cmd + 3
        register(action: .reevaluateWindows, keyCode: 0x06, modifiers: ctrlOpt, id: 73) // Ctrl + Opt + Z (Re-evaluate Windows)
        register(action: .relaunchIume, keyCode: 0x06, modifiers: ctrlOptShift, id: 74) // Ctrl + Opt + Shift + Z (Relaunch Iume)
        register(action: .toggleOverview, keyCode: 0x1F, modifiers: ctrlOpt, id: 75) // Ctrl + Opt + O (Strip Overview)
        
        // Legacy Option Key Secondary Fallbacks (if enabled)
        if SettingsStore.shared.useLegacyOptionShortcuts {
            register(action: .focusLeft, keyCode: 0x04, modifiers: opt, id: 50) // Opt + H
            register(action: .focusRight, keyCode: 0x25, modifiers: opt, id: 51) // Opt + L
            register(action: .focusDown, keyCode: 0x26, modifiers: opt, id: 52) // Opt + J
            register(action: .focusUp, keyCode: 0x28, modifiers: opt, id: 53) // Opt + K
            register(action: .moveColumnLeft, keyCode: 0x04, modifiers: optShift, id: 54) // Opt + Shift + H
            register(action: .moveColumnRight, keyCode: 0x25, modifiers: optShift, id: 55) // Opt + Shift + L
            register(action: .cycleWidth, keyCode: 0x0F, modifiers: opt, id: 56) // Opt + R
            register(action: .centerColumn, keyCode: 0x08, modifiers: opt, id: 57) // Opt + C
            register(action: .fullWidth, keyCode: 0x03, modifiers: opt, id: 58) // Opt + F
            register(action: .closeWindow, keyCode: 0x0D, modifiers: opt, id: 59) // Opt + W
            register(action: .kickstart, keyCode: 0x31, modifiers: optShift, id: 60) // Opt + Shift + Space
            register(action: .stopAndRestore, keyCode: 0x01, modifiers: optShift, id: 61) // Opt + Shift + S
            register(action: .toggleOverview, keyCode: 0x1F, modifiers: opt, id: 76) // Opt + O (Strip Overview)
        }
    }
    
    public func register(action: ShortcutAction, keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        let hotKeyID = EventHotKeyID(signature: OSType(0x49554D45), id: id) // 'IUME'
        var hotKeyRef: EventHotKeyRef?
        
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        
        if status == noErr, let ref = hotKeyRef {
            registeredHotKeys[id] = (ref, action)
        }
    }
    
    public func unregisterAll() {
        for (_, (ref, _)) in registeredHotKeys {
            UnregisterEventHotKey(ref)
        }
        registeredHotKeys.removeAll()
    }
    
    // MARK: - Private Event Handling
    
    private func installEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        
        let handler: EventHandlerUPP = { _, event, userData in
            guard let event = event, let userData = userData else { return noErr }
            let selfRef = Unmanaged<ShortcutManager>.fromOpaque(userData).takeUnretainedValue()
            
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            
            if status == noErr {
                DispatchQueue.main.async {
                    selfRef.handleHotKey(id: hotKeyID.id)
                }
            }
            return noErr
        }
        
        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
    }
    
    private func handleHotKey(id: UInt32) {
        if let (_, action) = registeredHotKeys[id] {
            onShortcutTriggered?(action)
        }
    }
}
