import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import IumeCore

@Suite("Shortcut Binding & Customization Tests", .serialized)
struct ShortcutCustomizationTests {

    private func chord(_ keyCode: UInt32, _ modifiers: [UInt32]) -> ShortcutChord {
        ShortcutChord(keyCode: keyCode, modifiers: modifiers.reduce(0, |))
    }

    private let ctrl = ShortcutChord.control
    private let opt = ShortcutChord.option
    private let shift = ShortcutChord.shift
    private let cmd = ShortcutChord.command

    // MARK: Catalog

    @Test("Every action has a binding entry")
    func catalogCoversEveryAction() {
        let bindings = ShortcutCatalog.defaults()
        let covered = Set(bindings.map(\.action))
        for action in ShortcutAction.allCases {
            #expect(covered.contains(action), "Missing default entry for \(action.rawValue)")
        }
    }

    @Test("Factory chords are conflict free")
    func defaultsHaveNoConflicts() {
        #expect(ShortcutCatalog.conflicts(in: ShortcutCatalog.defaults()).isEmpty)
    }

    @Test("Legacy option chords do not collide with factory chords")
    func legacyChordsDoNotCollide() {
        var combined = ShortcutCatalog.defaults()
        for legacy in ShortcutCatalog.legacyBindings() {
            if let index = combined.firstIndex(where: { $0.action == legacy.action }) {
                combined[index].chords.append(contentsOf: legacy.chords)
            } else {
                combined.append(legacy)
            }
        }
        #expect(ShortcutCatalog.conflicts(in: combined).isEmpty)
    }

    @Test("Factory chords preserve the historical registration table")
    func defaultsMatchHistoricalChords() {
        let bindings = ShortcutCatalog.defaults()
        func chords(_ action: ShortcutAction) -> [ShortcutChord] {
            bindings.first(where: { $0.action == action })?.chords ?? []
        }

        #expect(chords(.focusLeft) == [chord(0x7B, [ctrl, opt]), chord(0x04, [ctrl, opt])])
        #expect(chords(.focusRight) == [chord(0x7C, [ctrl, opt]), chord(0x25, [ctrl, opt])])
        #expect(chords(.cycleWidth) == [chord(0x0F, [ctrl, opt])])
        #expect(chords(.kickstart) == [chord(0x31, [ctrl, opt])])
        #expect(chords(.openCustomBoxGrid) == [chord(0x0B, [ctrl, opt, shift])])
        #expect(chords(.switchWorkspace3) == [chord(0x14, [ctrl, opt])])
        #expect(chords(.moveWorkspace9) == [chord(0x19, [ctrl, opt, shift])])
        #expect(chords(.stopAndRestore) == [chord(0x0C, [ctrl, opt]), chord(0x01, [ctrl, opt, shift])])
        #expect(chords(.throwSpaceLeft) == [chord(0x7B, [ctrl, opt, shift, cmd]), chord(0x04, [ctrl, opt, shift, cmd])])
        #expect(chords(.throwSpaceRight) == [chord(0x7C, [ctrl, opt, shift, cmd]), chord(0x25, [ctrl, opt, shift, cmd])])
    }

    @Test("Actions that used to be unreachable now have a binding entry")
    func previouslyUnboundActionsAreEditable() {
        let bindings = ShortcutCatalog.defaults()
        let unbound = [
            ShortcutAction.snapLeftHalf, .snapRightHalf, .snapTopHalf, .snapBottomHalf,
            .snapMaximize, .snapCenter, .tileAllToGrid, .tileAllToTall,
            .scrollLeft, .scrollRight, .toggleZoom,
        ]
        for action in unbound {
            let binding = bindings.first(where: { $0.action == action })
            #expect(binding != nil, "\(action.rawValue) should be listed so it can be bound")
            #expect(binding?.isEnabled == false)
        }
    }

    // MARK: Editing

    @Test("Recording a chord moves it from the action that owned it")
    func assignStealsChordFromOtherAction() {
        var bindings = ShortcutCatalog.defaults()
        let newChord = chord(0x11, [ctrl, opt, shift]) // ⌃⌥⇧T
        bindings = ShortcutCatalog.assign(newChord, to: .closeWindow, at: 0, in: bindings)

        #expect(bindings.first { $0.action == .closeWindow }?.chords == [newChord])
        #expect(bindings.first { $0.action == .toggleTabbedMode }?.chords.isEmpty == true)
        #expect(ShortcutCatalog.conflicts(in: bindings).isEmpty)
    }

    @Test("Recording at an index replaces only that chord")
    func assignReplacesOnlyTargetChord() {
        let bindings = ShortcutCatalog.defaults()
        let newChord = chord(0x00, [ctrl, opt]) // ⌃⌥A
        let updated = ShortcutCatalog.assign(newChord, to: .focusLeft, at: 1, in: bindings)

        let focus = updated.first { $0.action == .focusLeft }
        #expect(focus?.chords == [chord(0x7B, [ctrl, opt]), newChord])
        // The chord's previous owner loses it.
        #expect(updated.first { $0.action == .balanceSizes }?.chords.isEmpty == true)
    }

    @Test("Appending beyond the stored chords adds an alternative")
    func assignAppendsAlternative() {
        let bindings = ShortcutCatalog.defaults()
        let extra = chord(0x27, [ctrl, opt]) // ⌃⌥'
        let updated = ShortcutCatalog.assign(extra, to: .focusRight, at: 5, in: bindings)
        #expect(updated.first { $0.action == .focusRight }?.chords.count == 3)
        #expect(updated.first { $0.action == .focusRight }?.chords.last == extra)
    }

    @Test("Removing the last chord leaves the action deliberately unbound")
    func removeLastChordDisablesAction() {
        let bindings = ShortcutCatalog.defaults()
        let once = ShortcutCatalog.removeChord(at: 0, from: .toggleAppsEdgeTogether, in: bindings)
        #expect(once.first { $0.action == .toggleAppsEdgeTogether }?.chords.isEmpty == true)

        // Normalisation must not resurrect it.
        let normalized = ShortcutCatalog.normalized(once)
        #expect(normalized.first { $0.action == .toggleAppsEdgeTogether }?.chords.isEmpty == true)
    }

    @Test("Reset restores the factory chord for one action only")
    func resetRestoresSingleAction() {
        var bindings = ShortcutCatalog.defaults()
        bindings = ShortcutCatalog.assign(chord(0x00, [ctrl, opt, cmd]), to: .openSettings, at: 0, in: bindings)
        bindings = ShortcutCatalog.reset(.openSettings, in: bindings)

        let factory = ShortcutCatalog.defaults().first { $0.action == .openSettings }
        let restored = bindings.first { $0.action == .openSettings }
        #expect(restored?.chords == factory?.chords)
        #expect(restored?.isCustomized == false)
    }

    // MARK: Normalisation

    @Test("Normalisation adds actions introduced by a newer build")
    func normalizationAddsMissingActions() {
        let partial = ShortcutCatalog.defaults().filter { $0.action != .openRadialMenu && $0.action != .cycleLayoutMode }
        let normalized = ShortcutCatalog.normalized(partial)

        #expect(normalized.count == ShortcutAction.allCases.count)
        #expect(normalized.contains { $0.action == .openRadialMenu && !$0.chords.isEmpty })
        #expect(normalized.contains { $0.action == .cycleLayoutMode && !$0.chords.isEmpty })
    }

    @Test("Normalisation keeps custom chords")
    func normalizationKeepsCustomChords() {
        let custom = chord(0x23, [ctrl, opt]) // ⌃⌥P
        let bindings = ShortcutCatalog.assign(custom, to: .focusLeft, at: 0, in: ShortcutCatalog.defaults())
        let normalized = ShortcutCatalog.normalized(bindings)

        #expect(normalized.first { $0.action == .focusLeft }?.chords.first == custom)
    }

    // MARK: Conflicts

    @Test("Duplicate chords are reported with every owner")
    func conflictsDetectDuplicates() {
        var bindings = ShortcutCatalog.defaults()
        bindings[bindings.firstIndex { $0.action == .closeWindow }!].chords = [chord(0x0F, [ctrl, opt])]
        let conflicts = ShortcutCatalog.conflicts(in: bindings)

        let duplicated = conflicts[chord(0x0F, [ctrl, opt])]
        #expect(duplicated?.contains(.cycleWidth) == true)
        #expect(duplicated?.contains(.closeWindow) == true)
    }

    @Test("Automatic resolution keeps the first claim and warns the rest")
    func resolvingConflictsKeepsFirst() {
        var bindings = ShortcutCatalog.defaults()
        bindings[bindings.firstIndex { $0.action == .closeWindow }!].chords = [chord(0x0F, [ctrl, opt])]

        let resolved = ShortcutCatalog.resolvingConflicts(in: bindings)
        #expect(ShortcutCatalog.conflicts(in: resolved).isEmpty)
        #expect(resolved.first { $0.action == .cycleWidth }?.chords.count == 1)
        #expect(resolved.first { $0.action == .closeWindow }?.chords.isEmpty == true)
    }

    // MARK: Display

    @Test("Glyphs use the macOS modifier order")
    func glyphsUseMacOSOrder() {
        let chord = ShortcutChord(keyCode: 0x11, modifiers: ctrl | opt | shift | cmd)
        #expect(chord.glyphs.prefix(4) == ["⌃", "⌥", "⇧", "⌘"])
        #expect(chord.glyphs.count == 5)
        #expect(chord.displayString.hasPrefix("⌃⌥⇧⌘"))
    }

    @Test("Shift-only and bare chords are not valid shortcuts")
    func invalidChordsRejected() {
        #expect(ShortcutChord(keyCode: 0x11, modifiers: 0).isValidShortcut == false)
        #expect(ShortcutChord(keyCode: 0x11, modifiers: shift).isValidShortcut == false)
        #expect(ShortcutChord(keyCode: 0x11, modifiers: opt).isValidShortcut == true)
    }

    // MARK: Persistence

    @Test("Bindings survive a JSON round trip")
    func bindingsCodable() throws {
        let bindings = ShortcutCatalog.assign(
            chord(0x23, [ctrl, opt]),
            to: .snapLeftHalf,
            at: 0,
            in: ShortcutCatalog.defaults()
        )
        let data = try JSONEncoder().encode(bindings)
        let decoded = try JSONDecoder().decode([ShortcutBinding].self, from: data)
        #expect(decoded == bindings)
    }

    @Test("SettingsStore persists and reloads a remapped chord")
    @MainActor
    func settingsStorePersistsBindings() {
        let fixture = IsolatedSettingsFixture()
        defer { fixture.cleanup() }

        let store = fixture.store
        let custom = chord(0x23, [ctrl, opt])
        store.shortcutBindings = ShortcutCatalog.assign(custom, to: .snapRightHalf, at: 0, in: store.shortcutBindings)

        let reloaded = fixture.relaunched
        let persisted = reloaded.shortcutBindings.first { $0.action == .snapRightHalf }
        #expect(persisted?.chords == [custom])
        #expect(persisted?.isCustomized == true)
    }
}
