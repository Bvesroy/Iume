import XCTest
@testable import IumeCore

@MainActor
final class SettingsMemoryTests: XCTestCase {
    
    var fixture: IsolatedSettingsFixture!
    
    override func setUp() async throws {
        try await super.setUp()
        fixture = IsolatedSettingsFixture()
    }
    
    override func tearDown() async throws {
        fixture.cleanup()
        fixture = nil
        try await super.tearDown()
    }
    
    func testSnapshotSerializationAndRoundTrip() throws {
        let original = SettingsSnapshot(
            schemaVersion: 1,
            lastSavedDate: Date(),
            isMemoryLocked: false,
            profileName: "Custom Setup",
            isEnabled: true,
            layoutMode: .scrollStrip,
            insertionPolicy: .afterFocused,
            centerMode: .never,
            floatSmallWindows: true,
            smallWindowThreshold: 500.0,
            followSpaceThrownWindows: true,
            modifierDragMoveResize: true,
            showLiveFootprintPreview: true,
            windowGap: 18.0,
            appsEdgeTogether: true,
            savedPreviousGap: 18.0,
            edgeSnapping: true,
            defaultColumnWidthRatio: 0.65,
            snapToColumn: true,
            presetWidthRatios: [0.33, 0.5, 0.65, 1.0],
            edgeMargins: EdgeMargins(top: 10, bottom: 12, left: 14, right: 16),
            smartWindowMargins: false,
            disablePaddingOnBuiltinDisplay: false,
            animationDuration: 0.25,
            trackpadNaturalScroll: true,
            scrollTriggerMode: .seamlessHorizontal,
            scrollSensitivity: 1.2,
            scrollSmoothness: 0.8,
            scrollDeceleration: 0.945,
            inertialScrolling: true,
            momentumMultiplier: 1.5,
            kineticScrollingProfile: .viscous,
            smoothScrollingEnabled: true,
            enableTransitions: true,
            momentumScrolling: true,
            magneticSnapTransition: .liquidSpring,
            windowInsertionAnimation: .partingWave,
            showMinimapHUD: true,
            hudStyle: .circularDial,
            hudAlwaysVisible: false,
            hudSoundEnabled: true,
            hudSoundVolume: 0.35,
            loopMode: true,
            loopSeamSoundEnabled: true,
            showFocusBorder: true,
            focusFollowsMouse: false,
            mouseFollowsFocus: false,
            dimUnfocusedWindows: false,
            dragToReorder: true,
            launchAtLogin: true,
            excludedBundleIdentifiers: ["com.apple.Calculator", "com.apple.Photos"],
            disabledDisplayIds: [],
            appRules: [],
            useLegacyOptionShortcuts: false,
            shortcutBindings: []
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SettingsSnapshot.self, from: data)
        
        XCTAssertEqual(decoded.schemaVersion, original.schemaVersion)
        XCTAssertEqual(decoded.profileName, original.profileName)
        XCTAssertEqual(decoded.layoutMode, original.layoutMode)
        XCTAssertEqual(decoded.defaultColumnWidthRatio, original.defaultColumnWidthRatio, accuracy: 0.001)
        XCTAssertEqual(decoded.windowGap, original.windowGap, accuracy: 0.001)
        XCTAssertEqual(decoded.edgeMargins.top, original.edgeMargins.top)
        XCTAssertEqual(decoded.edgeMargins.bottom, original.edgeMargins.bottom)
        XCTAssertEqual(decoded.loopMode, original.loopMode)
        XCTAssertEqual(decoded.hudStyle, original.hudStyle)
        XCTAssertEqual(decoded.hudSoundVolume, original.hudSoundVolume, accuracy: 0.001)
        XCTAssertEqual(decoded.scrollDeceleration, original.scrollDeceleration, accuracy: 0.001)
        XCTAssertEqual(decoded.inertialScrolling, original.inertialScrolling)
        XCTAssertEqual(decoded.momentumMultiplier, original.momentumMultiplier, accuracy: 0.001)
        XCTAssertEqual(decoded.kineticScrollingProfile, original.kineticScrollingProfile)
        XCTAssertEqual(decoded.smoothScrollingEnabled, original.smoothScrollingEnabled)
        XCTAssertEqual(decoded.appsEdgeTogether, original.appsEdgeTogether)
        XCTAssertEqual(decoded.launchAtLogin, original.launchAtLogin)
        XCTAssertEqual(decoded.excludedBundleIdentifiers, original.excludedBundleIdentifiers)
    }
    
    func testPersistenceSurvivesRelaunch() throws {
        // 1. Mutate settings in the active fixture store
        fixture.store.layoutMode = .tall
        fixture.store.defaultColumnWidthRatio = 0.72
        fixture.store.appsEdgeTogether = false
        fixture.store.windowGap = 22.0
        fixture.store.loopMode = true
        fixture.store.hudStyle = .semicircle
        fixture.store.hudSoundVolume = 0.45
        fixture.store.excludedBundleIdentifiers = ["com.apple.Preview"]
        
        // 2. Flush to durable memory disk file
        fixture.store.flushMemoryToDisk()
        
        // 3. Simulate app termination and reboot relaunch
        let relaunchedStore = fixture.relaunched
        
        // 4. Verify all settings are retained identically
        XCTAssertEqual(relaunchedStore.layoutMode, .tall)
        XCTAssertEqual(relaunchedStore.defaultColumnWidthRatio, 0.72, accuracy: 0.001)
        XCTAssertEqual(relaunchedStore.appsEdgeTogether, false)
        XCTAssertEqual(relaunchedStore.windowGap, 22.0, accuracy: 0.001)
        XCTAssertEqual(relaunchedStore.loopMode, true)
        XCTAssertEqual(relaunchedStore.hudStyle, .semicircle)
        XCTAssertEqual(relaunchedStore.hudSoundVolume, 0.45, accuracy: 0.001)
        XCTAssertEqual(relaunchedStore.excludedBundleIdentifiers, ["com.apple.Preview"])
    }
    
    func testMemoryRecoversWhenUserDefaultsIsWiped() throws {
        // 1. Configure preferences
        fixture.store.layoutMode = .grid
        fixture.store.defaultColumnWidthRatio = 0.8
        fixture.store.windowGap = 30.0
        fixture.store.flushMemoryToDisk()
        
        // 2. Wipe UserDefaults domain completely (simulating cfprefsd flush loss on reboot)
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        
        // 3. Relaunch with the wiped defaults, but durable memory file intact
        let restoredStore = fixture.relaunched
        
        // 4. Verify the store recovered its preferences directly from the durable memory file
        XCTAssertEqual(restoredStore.layoutMode, .grid)
        XCTAssertEqual(restoredStore.defaultColumnWidthRatio, 0.8, accuracy: 0.001)
        XCTAssertEqual(restoredStore.windowGap, 30.0, accuracy: 0.001)
    }
    
    func testBaselineProfileSaveAndRestore() throws {
        // 1. Set favorite preferred baseline
        fixture.store.layoutMode = .scrollStrip
        fixture.store.defaultColumnWidthRatio = 0.618 // Golden ratio
        fixture.store.windowGap = 16.0
        fixture.store.saveAsPreferredBaseline()
        
        XCTAssertTrue(fixture.store.hasPreferredBaseline)
        
        // 2. User experiments and changes settings
        fixture.store.layoutMode = .tall
        fixture.store.defaultColumnWidthRatio = 0.33
        fixture.store.windowGap = 0.0
        
        XCTAssertEqual(fixture.store.layoutMode, .tall)
        XCTAssertEqual(fixture.store.defaultColumnWidthRatio, 0.33, accuracy: 0.001)
        
        // 3. Restore preferred baseline
        fixture.store.restorePreferredBaseline()
        
        // 4. Verify original baseline preferences are restored
        XCTAssertEqual(fixture.store.layoutMode, .scrollStrip)
        XCTAssertEqual(fixture.store.defaultColumnWidthRatio, 0.618, accuracy: 0.001)
        XCTAssertEqual(fixture.store.windowGap, 16.0, accuracy: 0.001)
    }
    
    func testSpaceLayoutFallbackAcrossReboot() throws {
        // Simulates macOS reboot where spaceId changes dynamically
        let displayId: CGDirectDisplayID = 1
        let preRebootSpaceId: UInt64 = 10042
        let postRebootSpaceId: UInt64 = 89912 // WindowServer reassigned space ID after reboot
        
        let oldKey = WorkspaceKey(displayId: displayId, spaceId: preRebootSpaceId, workspaceIndex: 0)
        let newKey = WorkspaceKey(displayId: displayId, spaceId: postRebootSpaceId, workspaceIndex: 0)
        
        let signature = WindowSignature(
            bundleIdentifier: "com.apple.finder",
            appName: "Finder",
            title: "Documents"
        )
        let column = SavedColumn(
            width: 750.0,
            windowSignatures: [signature]
        )
        let spaceLayout = SavedSpaceLayout(
            columns: [column],
            focusedColumnIndex: 0,
            viewportOffset: 120.0
        )
        
        let state = PersistedLayoutState(
            spaces: [oldKey.storageKey: spaceLayout]
        )
        
        // Direct exact lookup with newKey fails because spaceId changed
        XCTAssertNil(state.spaces[newKey.storageKey])
        
        // Resilient findSpaceLayout must fall back by displayId and workspaceIndex
        let fallbackResult = LayoutPersistenceManager.shared.findSpaceLayout(for: newKey, in: state)
        XCTAssertNotNil(fallbackResult)
        XCTAssertEqual(fallbackResult?.viewportOffset, 120.0)
        XCTAssertEqual(fallbackResult?.columns.first?.width, 750.0)
        XCTAssertEqual(fallbackResult?.columns.first?.windowSignatures.first?.bundleIdentifier, "com.apple.finder")
    }
}
