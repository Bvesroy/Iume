import Foundation
import Carbon
import AppKit

// MARK: - Chord

/// A single key combination: one Carbon virtual keycode plus Carbon modifier flags.
///
/// Kept as plain `UInt32` fields so the value round-trips through JSON and can be handed
/// straight to `RegisterEventHotKey` without translation.
public struct ShortcutChord: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    /// Carbon modifiers (`controlKey`, `optionKey`, `shiftKey`, `cmdKey`).
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // MARK: Modifier constants

    public static let control = UInt32(controlKey)
    public static let option = UInt32(optionKey)
    public static let shift = UInt32(shiftKey)
    public static let command = UInt32(cmdKey)

    /// Modifier order used by macOS: ⌃⌥⇧⌘.
    public static let displayOrder: [(mask: UInt32, glyph: String)] = [
        (control, "⌃"),
        (option, "⌥"),
        (shift, "⇧"),
        (command, "⌘"),
    ]

    // MARK: Display

    /// Keycaps in macOS order, e.g. `["⌃", "⌥", "T"]`.
    public var glyphs: [String] {
        var result = Self.displayOrder.compactMap { modifiers & $0.mask != 0 ? $0.glyph : nil }
        result.append(keyGlyph)
        return result
    }

    /// A compact single-line description, e.g. `⌃⌥T`.
    public var displayString: String {
        glyphs.joined()
    }

    /// The key itself, resolved through the user's active keyboard layout.
    public var keyGlyph: String {
        if keyCode == 0x31 { return "Space" }
        let translated = KeyTranslator.displayString(for: UInt16(keyCode))
        return translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Key\(keyCode)" : translated
    }

    /// Chords need a real modifier: a bare key or Shift-only would collide with typing.
    public var isValidShortcut: Bool {
        modifiers & (Self.control | Self.option | Self.command) != 0
    }

    /// Builds a chord from a live key event. Returns `nil` for Escape, bare keys and
    /// Shift-only combinations so the recorder can reject them.
    public static func from(event: NSEvent) -> ShortcutChord? {
        guard event.keyCode != 0x35 else { return nil } // Escape cancels recording
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= Self.control }
        if flags.contains(.option) { modifiers |= Self.option }
        if flags.contains(.shift) { modifiers |= Self.shift }
        if flags.contains(.command) { modifiers |= Self.command }
        let chord = ShortcutChord(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        return chord.isValidShortcut ? chord : nil
    }
}

// MARK: - Binding

/// Every chord that triggers one action. An empty `chords` array means the action is unbound.
public struct ShortcutBinding: Codable, Hashable, Identifiable, Sendable {
    public var action: ShortcutAction
    public var chords: [ShortcutChord]
    /// Set once the user edits this action, so the UI can offer a per-action reset.
    public var isCustomized: Bool

    public var id: ShortcutAction { action }

    public init(action: ShortcutAction, chords: [ShortcutChord], isCustomized: Bool = false) {
        self.action = action
        self.chords = chords
        self.isCustomized = isCustomized
    }

    public var isEnabled: Bool { !chords.isEmpty }
}

// MARK: - Groups

/// Sidebar-style grouping for the shortcut list. The order is the order shown in Settings.
public enum ShortcutGroupID: String, CaseIterable, Identifiable, Sendable {
    case focus = "Moving Focus"
    case sizing = "Resizing & Sizing"
    case layout = "Layout & Tiling"
    case arranging = "Arranging Windows"
    case tabs = "Window Tabs & Grouping"
    case workspaces = "Workspaces & Displays"
    case app = "Iume"

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .focus: return "arrow.left.and.right"
        case .sizing: return "arrow.up.left.and.arrow.down.right"
        case .layout: return "rectangle.split.3x1"
        case .arranging: return "square.stack.3d.up"
        case .tabs: return "rectangle.badge.plus"
        case .workspaces: return "square.grid.3x3"
        case .app: return "app.badge"
        }
    }
}

// MARK: - Catalog

/// The single source of truth for Iume's keyboard shortcuts.
///
/// The same table drives hotkey registration, the Settings list and conflict detection, so a
/// chord can never drift out of sync with what is actually registered.
public enum ShortcutCatalog {

    // MARK: Defaults

    /// Factory default chords. Mirrors the historical hard-coded registration table, plus a
    /// second chord where Iume always accepted two (arrows and HJKL, both unstack keys, …).
    public static func defaults() -> [ShortcutBinding] {
        let ctrlOpt = ShortcutChord.control | ShortcutChord.option
        let ctrlOptShift = ctrlOpt | ShortcutChord.shift
        let ctrlOptCmd = ctrlOpt | ShortcutChord.command
        let ctrlOptShiftCmd = ctrlOptShift | ShortcutChord.command

        func binding(_ action: ShortcutAction, _ chords: [(UInt32, UInt32)]) -> ShortcutBinding {
            ShortcutBinding(action: action, chords: chords.map { ShortcutChord(keyCode: $0.0, modifiers: $0.1) })
        }

        var result: [ShortcutBinding] = [
            // Focus navigation: arrows and HJKL.
            binding(.focusLeft, [(0x7B, ctrlOpt), (0x04, ctrlOpt)]),
            binding(.focusRight, [(0x7C, ctrlOpt), (0x25, ctrlOpt)]),
            binding(.focusDown, [(0x7D, ctrlOpt), (0x26, ctrlOpt)]),
            binding(.focusUp, [(0x7E, ctrlOpt), (0x28, ctrlOpt)]),
            binding(.focusFirst, [(0x7B, ctrlOptCmd)]),
            binding(.focusLast, [(0x7C, ctrlOptCmd)]),
            binding(.cycleNext, [(0x30, ctrlOpt)]),
            binding(.cyclePrev, [(0x30, ctrlOptShift)]),
            binding(.scrollLeft, []),
            binding(.scrollRight, []),
            binding(.focusDisplay1, [(0x12, ctrlOptCmd)]),
            binding(.focusDisplay2, [(0x13, ctrlOptCmd)]),
            binding(.focusDisplay3, [(0x14, ctrlOptCmd)]),

            // Column order and width.
            binding(.moveColumnLeft, [(0x7B, ctrlOptShift), (0x04, ctrlOptShift)]),
            binding(.moveColumnRight, [(0x7C, ctrlOptShift), (0x25, ctrlOptShift)]),
            binding(.cycleWidth, [(0x0F, ctrlOpt)]),
            binding(.cycleWidthBackward, [(0x0F, ctrlOptShift)]),
            binding(.nudgeWider, [(0x18, ctrlOpt)]),
            binding(.nudgeNarrower, [(0x1B, ctrlOpt)]),
            binding(.nudgeStackTaller, [(0x18, ctrlOptShift)]),
            binding(.nudgeStackShorter, [(0x1B, ctrlOptShift)]),
            binding(.equalizeStackHeights, [(0x1D, ctrlOpt)]),
            binding(.scaleLarger, [(0x18, ctrlOptCmd)]),
            binding(.scaleSmaller, [(0x1B, ctrlOptCmd)]),
            binding(.fullWidth, [(0x03, ctrlOpt), (0x24, ctrlOpt)]),
            binding(.balanceSizes, [(0x00, ctrlOpt)]),
            binding(.toggleZoom, []),

            // Layout modes and box snapping.
            binding(.cycleLayoutMode, [(0x31, ctrlOptShift)]),
            binding(.toggleLoopMode, [(0x1F, ctrlOptShift)]),
            binding(.tileAllToGrid, []),
            binding(.tileAllToTall, []),
            binding(.swapWindowWithMain, [(0x24, ctrlOptShift)]),
            binding(.snapLeftHalf, []),
            binding(.snapRightHalf, []),
            binding(.snapTopHalf, []),
            binding(.snapBottomHalf, []),
            binding(.snapTopLeft, [(0x20, ctrlOpt)]),
            binding(.snapTopRight, [(0x22, ctrlOpt)]),
            binding(.snapBottomLeft, [(0x26, ctrlOptShift)]),
            binding(.snapBottomRight, [(0x28, ctrlOptShift)]),
            binding(.snapFirstThird, [(0x02, ctrlOpt)]),
            binding(.snapCenterThird, [(0x03, ctrlOptShift)]),
            binding(.snapLastThird, [(0x05, ctrlOptShift)]),
            binding(.snapMaximize, []),
            binding(.snapAlmostMaximize, []),
            binding(.snapCenter, []),

            // Arranging windows.
            binding(.centerColumn, [(0x08, ctrlOpt)]),
            binding(.stackLeft, [(0x21, ctrlOpt)]),
            binding(.stackRight, [(0x1E, ctrlOpt)]),
            binding(.unstack, [(0x21, ctrlOptShift), (0x1E, ctrlOptShift)]),
            binding(.toggleTabbedMode, [(0x11, ctrlOptShift)]),
            binding(.toggleFloatWindow, [(0x11, ctrlOpt)]),
            binding(.sendToNextDisplay, [(0x2D, ctrlOpt)]),
            binding(.sendToNextDisplayFollow, [(0x2D, ctrlOptShift)]),
            binding(.closeWindow, [(0x0D, ctrlOpt)]),
            binding(.openRadialMenu, [(0x0B, ctrlOpt)]),
            binding(.openCustomBoxGrid, [(0x0B, ctrlOptShift)]),

            // Workspaces.
            binding(.throwSpaceLeft, [(0x7B, ctrlOptShiftCmd), (0x04, ctrlOptShiftCmd)]),
            binding(.throwSpaceRight, [(0x7C, ctrlOptShiftCmd), (0x25, ctrlOptShiftCmd)]),

            // Iume itself.
            binding(.kickstart, [(0x31, ctrlOpt)]),
            binding(.stopAndRestore, [(0x0C, ctrlOpt), (0x01, ctrlOptShift)]),
            binding(.toggleAppsEdgeTogether, [(0x05, ctrlOpt)]),
            binding(.toggleMagneticSnapping, [(0x2E, ctrlOpt)]),
            binding(.openSettings, [(0x2B, ctrlOpt)]),
            binding(.showCheatsheet, [(0x2C, ctrlOpt)]),
            binding(.reevaluateWindows, [(0x06, ctrlOpt)]),
            binding(.relaunchIume, [(0x06, ctrlOptShift)]),
            // Window Tabs & Grouping
            binding(.tabSameAppWindows, []),
            binding(.tabAllSameAppWindows, [(0x11, ctrlOptCmd)]),
            binding(.nextTab, []),
            binding(.prevTab, []),
            binding(.newTab, [(0x2D, ctrlOptCmd)]),
            binding(.closeTab, [(0x0D, ctrlOptShift)]),
            binding(.detachTab, [(0x02, ctrlOptCmd)]),
            binding(.toggleTabBarPin, [(0x23, ctrlOptShift)]),
            binding(.ungroupActiveTab, [(0x20, ctrlOptShift)]),
            binding(.selectTab1, []),
            binding(.selectTab2, []),
            binding(.selectTab3, []),
            binding(.selectTab4, []),
            binding(.selectTab5, []),
            binding(.selectTab6, []),
            binding(.selectTab7, []),
            binding(.selectTab8, []),
            binding(.selectLastTab, []),
            binding(.moveTabLeft, []),
            binding(.moveTabRight, []),
            binding(.toggleOverview, [(0x1F, ctrlOpt)]),
        ]

        // Workspace switching and moving: ⌃⌥1…9 and ⌃⌥⇧1…9.
        let numberKeys: [(UInt32, ShortcutAction, ShortcutAction)] = [
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
        var workspaceBindings: [ShortcutBinding] = []
        for (keyCode, switchAction, moveAction) in numberKeys {
            workspaceBindings.append(binding(switchAction, [(keyCode, ctrlOpt)]))
            workspaceBindings.append(binding(moveAction, [(keyCode, ctrlOptShift)]))
        }
        result.append(contentsOf: workspaceBindings)

        return result
    }

    /// Extra ⌥-based chords for people used to older builds. Registered additively on top of
    /// the user's bindings, and skipped when they would collide with one of them.
    public static func legacyBindings() -> [ShortcutBinding] {
        let opt = ShortcutChord.option
        let optShift = opt | ShortcutChord.shift
        func binding(_ action: ShortcutAction, _ keyCode: UInt32, _ modifiers: UInt32) -> ShortcutBinding {
            ShortcutBinding(action: action, chords: [ShortcutChord(keyCode: keyCode, modifiers: modifiers)])
        }
        return [
            binding(.focusLeft, 0x04, opt),
            binding(.focusRight, 0x25, opt),
            binding(.focusDown, 0x26, opt),
            binding(.focusUp, 0x28, opt),
            binding(.moveColumnLeft, 0x04, optShift),
            binding(.moveColumnRight, 0x25, optShift),
            binding(.cycleWidth, 0x0F, opt),
            binding(.centerColumn, 0x08, opt),
            binding(.fullWidth, 0x03, opt),
            binding(.closeWindow, 0x0D, opt),
            binding(.kickstart, 0x31, optShift),
            binding(.stopAndRestore, 0x01, optShift),
        ]
    }

    // MARK: Normalisation

    /// Merges stored bindings with the catalog: unknown actions are dropped, actions added in a
    /// newer build appear with their defaults, and an explicitly disabled action (empty chord
    /// list) is preserved rather than resurrected.
    public static func normalized(_ stored: [ShortcutBinding]) -> [ShortcutBinding] {
        var storedByAction: [ShortcutAction: ShortcutBinding] = [:]
        for binding in stored where storedByAction[binding.action] == nil {
            storedByAction[binding.action] = binding
        }
        return defaults().map { fallback in
            storedByAction[fallback.action] ?? fallback
        }
    }

    // MARK: Grouping

    public static func group(for action: ShortcutAction) -> ShortcutGroupID {
        switch action {
        case .focusLeft, .focusRight, .focusUp, .focusDown,
             .focusFirst, .focusLast, .cycleNext, .cyclePrev,
             .scrollLeft, .scrollRight,
             .focusDisplay1, .focusDisplay2, .focusDisplay3:
            return .focus
        case .cycleWidth, .cycleWidthBackward, .nudgeWider, .nudgeNarrower,
             .nudgeStackTaller, .nudgeStackShorter, .equalizeStackHeights,
             .scaleLarger, .scaleSmaller, .fullWidth, .balanceSizes, .toggleZoom:
            return .sizing
        case .cycleLayoutMode, .toggleLoopMode, .tileAllToGrid, .tileAllToTall,
             .snapLeftHalf, .snapRightHalf, .snapTopHalf, .snapBottomHalf,
             .snapTopLeft, .snapTopRight, .snapBottomLeft, .snapBottomRight,
             .snapFirstThird, .snapCenterThird, .snapLastThird,
             .snapMaximize, .snapAlmostMaximize, .snapCenter, .swapWindowWithMain:
            return .layout
        case .moveColumnLeft, .moveColumnRight, .centerColumn,
             .stackLeft, .stackRight, .unstack,
             .toggleTabbedMode, .toggleFloatWindow,
             .sendToNextDisplay, .sendToNextDisplayFollow,
             .closeWindow, .openRadialMenu, .openCustomBoxGrid:
            return .arranging
        case .throwSpaceLeft, .throwSpaceRight,
             .switchWorkspace1, .switchWorkspace2, .switchWorkspace3,
             .switchWorkspace4, .switchWorkspace5, .switchWorkspace6,
             .switchWorkspace7, .switchWorkspace8, .switchWorkspace9,
             .moveWorkspace1, .moveWorkspace2, .moveWorkspace3,
             .moveWorkspace4, .moveWorkspace5, .moveWorkspace6,
             .moveWorkspace7, .moveWorkspace8, .moveWorkspace9:
            return .workspaces
        case .tabSameAppWindows, .tabAllSameAppWindows,
             .nextTab, .prevTab, .newTab, .closeTab, .detachTab,
             .toggleTabBarPin, .ungroupActiveTab,
             .selectTab1, .selectTab2, .selectTab3, .selectTab4,
             .selectTab5, .selectTab6, .selectTab7, .selectTab8,
             .selectLastTab, .moveTabLeft, .moveTabRight:
            return .tabs
        case .toggleOverview:
            return .app
        case .kickstart, .stopAndRestore, .toggleAppsEdgeTogether, .toggleMagneticSnapping,
             .openSettings, .showCheatsheet, .reevaluateWindows, .relaunchIume:
            return .app
        }
    }

    public static func actions(in group: ShortcutGroupID) -> [ShortcutAction] {
        ShortcutAction.allCases.filter { self.group(for: $0) == group }
    }

    // MARK: Conflicts

    /// Chords assigned to more than one action, mapped to every action that claims them.
    public static func conflicts(in bindings: [ShortcutBinding]) -> [ShortcutChord: [ShortcutAction]] {
        var owners: [ShortcutChord: [ShortcutAction]] = [:]
        for binding in bindings {
            for chord in binding.chords {
                if !owners[chord, default: []].contains(binding.action) {
                    owners[chord, default: []].append(binding.action)
                }
            }
        }
        return owners.filter { $0.value.count > 1 }
    }

    /// Keeps the first action that claims each chord and strips it from the rest.
    public static func resolvingConflicts(in bindings: [ShortcutBinding]) -> [ShortcutBinding] {
        var claimed: Set<ShortcutChord> = []
        return bindings.map { binding in
            var updated = binding
            var kept: [ShortcutChord] = []
            for chord in binding.chords {
                if claimed.insert(chord).inserted {
                    kept.append(chord)
                }
            }
            if kept != binding.chords {
                updated.chords = kept
                updated.isCustomized = true
            }
            return updated
        }
    }

    // MARK: Editing

    /// Records `chord` for `action`. A chord already owned by another action is moved rather
    /// than duplicated, so recording always does what the user sees.
    public static func assign(
        _ chord: ShortcutChord,
        to action: ShortcutAction,
        at index: Int,
        in bindings: [ShortcutBinding]
    ) -> [ShortcutBinding] {
        var updated = bindings

        for i in updated.indices where updated[i].action != action {
            let before = updated[i].chords.count
            updated[i].chords.removeAll { $0 == chord }
            if updated[i].chords.count != before {
                updated[i].isCustomized = true
            }
        }

        guard let target = updated.firstIndex(where: { $0.action == action }) else { return updated }

        var chords = updated[target].chords
        if index < chords.count {
            chords[index] = chord
        } else {
            chords.append(chord)
        }
        var seen: Set<ShortcutChord> = []
        chords = chords.filter { seen.insert($0).inserted }

        updated[target].chords = chords
        updated[target].isCustomized = true
        return updated
    }

    /// Removes one chord. Removing the last chord leaves the action deliberately unbound.
    public static func removeChord(
        at index: Int,
        from action: ShortcutAction,
        in bindings: [ShortcutBinding]
    ) -> [ShortcutBinding] {
        guard let target = bindings.firstIndex(where: { $0.action == action }),
              bindings[target].chords.indices.contains(index) else { return bindings }
        var updated = bindings
        updated[target].chords.remove(at: index)
        updated[target].isCustomized = true
        return updated
    }

    /// Restores the factory chords for a single action.
    public static func reset(_ action: ShortcutAction, in bindings: [ShortcutBinding]) -> [ShortcutBinding] {
        guard let fallback = defaults().first(where: { $0.action == action }),
              let target = bindings.firstIndex(where: { $0.action == action }) else { return bindings }
        var updated = bindings
        updated[target] = fallback
        return updated
    }

    /// Restores every factory chord.
    public static func resetAll() -> [ShortcutBinding] {
        defaults()
    }
}
