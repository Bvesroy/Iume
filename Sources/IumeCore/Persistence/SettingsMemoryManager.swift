import Foundation
import CoreGraphics

/// Complete, versioned snapshot of all user preferences and setting memory.
public struct SettingsSnapshot: Codable, Sendable, Equatable {
    public var schemaVersion: Int = 1
    public var lastSavedDate: Date = Date()
    public var isMemoryLocked: Bool = false
    public var profileName: String = "Default Preferred"

    // Window Management & Engine
    public var isEnabled: Bool = true
    public var layoutMode: LayoutMode = .scrollStrip
    public var insertionPolicy: InsertionPolicy = .afterFocused
    public var centerMode: CenterMode = .never
    public var floatSmallWindows: Bool = true
    public var smallWindowThreshold: Double = 500.0
    public var followSpaceThrownWindows: Bool = true
    public var modifierDragMoveResize: Bool = true
    public var showLiveFootprintPreview: Bool = true

    // Dimensions, Spacing & Margins
    public var windowGap: Double = 12.0
    public var appsEdgeTogether: Bool = false
    public var savedPreviousGap: Double = 12.0
    public var edgeSnapping: Bool = true
    public var defaultColumnWidthRatio: Double = 0.50
    public var snapToColumn: Bool = true
    public var presetWidthRatios: [Double] = [0.25, 0.333, 0.50, 0.667, 0.75, 1.0]
    public var edgeMargins: EdgeMargins = EdgeMargins(top: 0, bottom: 0, left: 0, right: 0)
    public var smartWindowMargins: Bool = false
    public var disablePaddingOnBuiltinDisplay: Bool = false

    // Motion, Scrolling & Animations
    public var animationDuration: Double = 0.22
    public var trackpadNaturalScroll: Bool = true
    public var scrollTriggerMode: ScrollTriggerMode = .seamlessHorizontal
    public var scrollSensitivity: Double = 1.0
    public var scrollSmoothness: Double = 0.75
    public var enableTransitions: Bool = true
    public var momentumScrolling: Bool = true
    public var magneticSnapTransition: MagneticSnapTransitionStyle = .liquidSpring
    public var windowInsertionAnimation: WindowInsertionAnimationStyle = .partingWave

    // Minimap HUD & Audio
    public var showMinimapHUD: Bool = true
    public var hudStyle: MinimapHUDStyle = .circularDial
    public var hudAlwaysVisible: Bool = false
    public var hudSoundEnabled: Bool = false
    public var hudSoundVolume: Double = 0.14
    public var loopMode: Bool = false
    public var loopSeamSoundEnabled: Bool = true

    // Visual Overlays & Focus Behavior
    public var showFocusBorder: Bool = false
    public var focusFollowsMouse: Bool = false
    public var mouseFollowsFocus: Bool = false
    public var dimUnfocusedWindows: Bool = false
    public var dragToReorder: Bool = true

    // System, Rules & Displays
    public var launchAtLogin: Bool = false
    public var excludedBundleIdentifiers: [String] = [
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.Spotlight",
        "com.apple.SystemSettings"
    ]
    public var disabledDisplayIds: [UInt32] = []
    public var appRules: [AppWindowRule] = []

    // Shortcuts
    public var useLegacyOptionShortcuts: Bool = false
    public var shortcutBindings: [ShortcutBinding] = []
    // Window Tabs & Grouping
    public var autoTabSameAppWindows: Bool = true
    public var tabBarCompactMode: Bool = false
    public var tabDetachThreshold: Double = 24.0
    public var smartGroupingPolicy: SmartGroupingPolicy = .sameApp
    public var allowCrossAppGrouping: Bool = false
    public var wrapAroundFocus: Bool = false
    public var cycleTabsBeforeColumns: Bool = true
    public var fullWidthToggleRestoresRatio: Bool = true
    public var tabAnimationsEnabled: Bool = true
    public var tabSwitchEffect: TabSwitchEffect = .slide
    public var tabOpenCloseEffect: TabOpenCloseEffect = .scaleFade
    public var tabMotionSpeed: Double = 1.0
    public var tabHapticsEnabled: Bool = true
    public var freezeOnRelease: Bool = true
    public var freeformScroll: Bool = true

    public init(
        schemaVersion: Int = 1,
        lastSavedDate: Date = Date(),
        isMemoryLocked: Bool = false,
        profileName: String = "Default Preferred",
        isEnabled: Bool = true,
        layoutMode: LayoutMode = .scrollStrip,
        insertionPolicy: InsertionPolicy = .afterFocused,
        centerMode: CenterMode = .never,
        floatSmallWindows: Bool = true,
        smallWindowThreshold: Double = 500.0,
        followSpaceThrownWindows: Bool = true,
        modifierDragMoveResize: Bool = true,
        showLiveFootprintPreview: Bool = true,
        windowGap: Double = 12.0,
        appsEdgeTogether: Bool = false,
        savedPreviousGap: Double = 12.0,
        edgeSnapping: Bool = true,
        defaultColumnWidthRatio: Double = 0.50,
        snapToColumn: Bool = true,
        presetWidthRatios: [Double] = [0.25, 0.333, 0.50, 0.667, 0.75, 1.0],
        edgeMargins: EdgeMargins = EdgeMargins(top: 0, bottom: 0, left: 0, right: 0),
        smartWindowMargins: Bool = false,
        disablePaddingOnBuiltinDisplay: Bool = false,
        animationDuration: Double = 0.22,
        trackpadNaturalScroll: Bool = true,
        scrollTriggerMode: ScrollTriggerMode = .seamlessHorizontal,
        scrollSensitivity: Double = 1.0,
        scrollSmoothness: Double = 0.75,
        enableTransitions: Bool = true,
        momentumScrolling: Bool = true,
        magneticSnapTransition: MagneticSnapTransitionStyle = .liquidSpring,
        windowInsertionAnimation: WindowInsertionAnimationStyle = .partingWave,
        showMinimapHUD: Bool = true,
        hudStyle: MinimapHUDStyle = .circularDial,
        hudAlwaysVisible: Bool = false,
        hudSoundEnabled: Bool = false,
        hudSoundVolume: Double = 0.14,
        loopMode: Bool = false,
        loopSeamSoundEnabled: Bool = true,
        showFocusBorder: Bool = false,
        focusFollowsMouse: Bool = false,
        mouseFollowsFocus: Bool = false,
        dimUnfocusedWindows: Bool = false,
        dragToReorder: Bool = true,
        launchAtLogin: Bool = false,
        excludedBundleIdentifiers: [String] = [
            "com.apple.notificationcenterui",
            "com.apple.controlcenter",
            "com.apple.Spotlight",
            "com.apple.SystemSettings"
        ],
        disabledDisplayIds: [UInt32] = [],
        appRules: [AppWindowRule] = [],
        useLegacyOptionShortcuts: Bool = false,
        shortcutBindings: [ShortcutBinding] = [],
        autoTabSameAppWindows: Bool = true,
        tabBarCompactMode: Bool = false,
        tabDetachThreshold: Double = 24.0,
        smartGroupingPolicy: SmartGroupingPolicy = .sameApp,
        allowCrossAppGrouping: Bool = false,
        wrapAroundFocus: Bool = false,
        cycleTabsBeforeColumns: Bool = true,
        fullWidthToggleRestoresRatio: Bool = true,
        tabAnimationsEnabled: Bool = true,
        tabSwitchEffect: TabSwitchEffect = .slide,
        tabOpenCloseEffect: TabOpenCloseEffect = .scaleFade,
        tabMotionSpeed: Double = 1.0,
        tabHapticsEnabled: Bool = true,
        freezeOnRelease: Bool = true,
        freeformScroll: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.lastSavedDate = lastSavedDate
        self.isMemoryLocked = isMemoryLocked
        self.profileName = profileName
        self.isEnabled = isEnabled
        self.layoutMode = layoutMode
        self.insertionPolicy = insertionPolicy
        self.centerMode = centerMode
        self.floatSmallWindows = floatSmallWindows
        self.smallWindowThreshold = smallWindowThreshold
        self.followSpaceThrownWindows = followSpaceThrownWindows
        self.modifierDragMoveResize = modifierDragMoveResize
        self.showLiveFootprintPreview = showLiveFootprintPreview
        self.windowGap = windowGap
        self.appsEdgeTogether = appsEdgeTogether
        self.savedPreviousGap = savedPreviousGap
        self.edgeSnapping = edgeSnapping
        self.defaultColumnWidthRatio = defaultColumnWidthRatio
        self.snapToColumn = snapToColumn
        self.presetWidthRatios = presetWidthRatios
        self.edgeMargins = edgeMargins
        self.smartWindowMargins = smartWindowMargins
        self.disablePaddingOnBuiltinDisplay = disablePaddingOnBuiltinDisplay
        self.animationDuration = animationDuration
        self.trackpadNaturalScroll = trackpadNaturalScroll
        self.scrollTriggerMode = scrollTriggerMode
        self.scrollSensitivity = scrollSensitivity
        self.scrollSmoothness = scrollSmoothness
        self.enableTransitions = enableTransitions
        self.momentumScrolling = momentumScrolling
        self.magneticSnapTransition = magneticSnapTransition
        self.windowInsertionAnimation = windowInsertionAnimation
        self.showMinimapHUD = showMinimapHUD
        self.hudStyle = hudStyle
        self.hudAlwaysVisible = hudAlwaysVisible
        self.hudSoundEnabled = hudSoundEnabled
        self.hudSoundVolume = hudSoundVolume
        self.loopMode = loopMode
        self.loopSeamSoundEnabled = loopSeamSoundEnabled
        self.showFocusBorder = showFocusBorder
        self.focusFollowsMouse = focusFollowsMouse
        self.mouseFollowsFocus = mouseFollowsFocus
        self.dimUnfocusedWindows = dimUnfocusedWindows
        self.dragToReorder = dragToReorder
        self.launchAtLogin = launchAtLogin
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.disabledDisplayIds = disabledDisplayIds
        self.appRules = appRules
        self.useLegacyOptionShortcuts = useLegacyOptionShortcuts
        self.shortcutBindings = shortcutBindings
        self.autoTabSameAppWindows = autoTabSameAppWindows
        self.tabBarCompactMode = tabBarCompactMode
        self.tabDetachThreshold = tabDetachThreshold
        self.smartGroupingPolicy = smartGroupingPolicy
        self.allowCrossAppGrouping = allowCrossAppGrouping
        self.wrapAroundFocus = wrapAroundFocus
        self.cycleTabsBeforeColumns = cycleTabsBeforeColumns
        self.fullWidthToggleRestoresRatio = fullWidthToggleRestoresRatio
        self.tabAnimationsEnabled = tabAnimationsEnabled
        self.tabSwitchEffect = tabSwitchEffect
        self.tabOpenCloseEffect = tabOpenCloseEffect
        self.tabMotionSpeed = tabMotionSpeed
        self.tabHapticsEnabled = tabHapticsEnabled
        self.freezeOnRelease = freezeOnRelease
        self.freeformScroll = freeformScroll
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.lastSavedDate = try c.decodeIfPresent(Date.self, forKey: .lastSavedDate) ?? Date()
        self.isMemoryLocked = try c.decodeIfPresent(Bool.self, forKey: .isMemoryLocked) ?? false
        self.profileName = try c.decodeIfPresent(String.self, forKey: .profileName) ?? "Default Preferred"

        // Window Management & Engine
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.layoutMode = try c.decodeIfPresent(LayoutMode.self, forKey: .layoutMode) ?? .scrollStrip
        self.insertionPolicy = try c.decodeIfPresent(InsertionPolicy.self, forKey: .insertionPolicy) ?? .afterFocused
        self.centerMode = try c.decodeIfPresent(CenterMode.self, forKey: .centerMode) ?? .never
        self.floatSmallWindows = try c.decodeIfPresent(Bool.self, forKey: .floatSmallWindows) ?? true
        self.smallWindowThreshold = try c.decodeIfPresent(Double.self, forKey: .smallWindowThreshold) ?? 500.0
        self.followSpaceThrownWindows = try c.decodeIfPresent(Bool.self, forKey: .followSpaceThrownWindows) ?? true
        self.modifierDragMoveResize = try c.decodeIfPresent(Bool.self, forKey: .modifierDragMoveResize) ?? true
        self.showLiveFootprintPreview = try c.decodeIfPresent(Bool.self, forKey: .showLiveFootprintPreview) ?? true

        // Dimensions, Spacing & Margins
        self.windowGap = try c.decodeIfPresent(Double.self, forKey: .windowGap) ?? 12.0
        self.appsEdgeTogether = try c.decodeIfPresent(Bool.self, forKey: .appsEdgeTogether) ?? false
        self.savedPreviousGap = try c.decodeIfPresent(Double.self, forKey: .savedPreviousGap) ?? 12.0
        self.edgeSnapping = try c.decodeIfPresent(Bool.self, forKey: .edgeSnapping) ?? true
        self.defaultColumnWidthRatio = try c.decodeIfPresent(Double.self, forKey: .defaultColumnWidthRatio) ?? 0.50
        self.snapToColumn = try c.decodeIfPresent(Bool.self, forKey: .snapToColumn) ?? true
        self.presetWidthRatios = try c.decodeIfPresent([Double].self, forKey: .presetWidthRatios) ?? [0.25, 0.333, 0.50, 0.667, 0.75, 1.0]
        self.edgeMargins = try c.decodeIfPresent(EdgeMargins.self, forKey: .edgeMargins) ?? EdgeMargins(top: 0, bottom: 0, left: 0, right: 0)
        self.smartWindowMargins = try c.decodeIfPresent(Bool.self, forKey: .smartWindowMargins) ?? false
        self.disablePaddingOnBuiltinDisplay = try c.decodeIfPresent(Bool.self, forKey: .disablePaddingOnBuiltinDisplay) ?? false

        // Motion, Scrolling & Animations
        self.animationDuration = try c.decodeIfPresent(Double.self, forKey: .animationDuration) ?? 0.22
        self.trackpadNaturalScroll = try c.decodeIfPresent(Bool.self, forKey: .trackpadNaturalScroll) ?? true
        self.scrollTriggerMode = try c.decodeIfPresent(ScrollTriggerMode.self, forKey: .scrollTriggerMode) ?? .seamlessHorizontal
        self.scrollSensitivity = try c.decodeIfPresent(Double.self, forKey: .scrollSensitivity) ?? 1.0
        self.scrollSmoothness = try c.decodeIfPresent(Double.self, forKey: .scrollSmoothness) ?? 0.75
        self.enableTransitions = try c.decodeIfPresent(Bool.self, forKey: .enableTransitions) ?? true
        self.momentumScrolling = try c.decodeIfPresent(Bool.self, forKey: .momentumScrolling) ?? true
        self.magneticSnapTransition = try c.decodeIfPresent(MagneticSnapTransitionStyle.self, forKey: .magneticSnapTransition) ?? .liquidSpring
        self.windowInsertionAnimation = try c.decodeIfPresent(WindowInsertionAnimationStyle.self, forKey: .windowInsertionAnimation) ?? .partingWave

        // Minimap HUD & Audio
        self.showMinimapHUD = try c.decodeIfPresent(Bool.self, forKey: .showMinimapHUD) ?? true
        self.hudStyle = try c.decodeIfPresent(MinimapHUDStyle.self, forKey: .hudStyle) ?? .circularDial
        self.hudAlwaysVisible = try c.decodeIfPresent(Bool.self, forKey: .hudAlwaysVisible) ?? false
        self.hudSoundEnabled = try c.decodeIfPresent(Bool.self, forKey: .hudSoundEnabled) ?? false
        self.hudSoundVolume = try c.decodeIfPresent(Double.self, forKey: .hudSoundVolume) ?? 0.14
        self.loopMode = try c.decodeIfPresent(Bool.self, forKey: .loopMode) ?? false
        self.loopSeamSoundEnabled = try c.decodeIfPresent(Bool.self, forKey: .loopSeamSoundEnabled) ?? true

        // Visual Overlays & Focus Behavior
        self.showFocusBorder = try c.decodeIfPresent(Bool.self, forKey: .showFocusBorder) ?? false
        self.focusFollowsMouse = try c.decodeIfPresent(Bool.self, forKey: .focusFollowsMouse) ?? false
        self.mouseFollowsFocus = try c.decodeIfPresent(Bool.self, forKey: .mouseFollowsFocus) ?? false
        self.dimUnfocusedWindows = try c.decodeIfPresent(Bool.self, forKey: .dimUnfocusedWindows) ?? false
        self.dragToReorder = try c.decodeIfPresent(Bool.self, forKey: .dragToReorder) ?? true

        // System, Rules & Displays
        self.launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        self.excludedBundleIdentifiers = try c.decodeIfPresent([String].self, forKey: .excludedBundleIdentifiers) ?? [
            "com.apple.notificationcenterui",
            "com.apple.controlcenter",
            "com.apple.Spotlight",
            "com.apple.SystemSettings"
        ]
        self.disabledDisplayIds = try c.decodeIfPresent([UInt32].self, forKey: .disabledDisplayIds) ?? []
        self.appRules = try c.decodeIfPresent([AppWindowRule].self, forKey: .appRules) ?? []

        // Shortcuts
        self.useLegacyOptionShortcuts = try c.decodeIfPresent(Bool.self, forKey: .useLegacyOptionShortcuts) ?? false
        self.shortcutBindings = try c.decodeIfPresent([ShortcutBinding].self, forKey: .shortcutBindings) ?? []

        // Window Tabs & Grouping
        self.autoTabSameAppWindows = try c.decodeIfPresent(Bool.self, forKey: .autoTabSameAppWindows) ?? true
        self.tabBarCompactMode = try c.decodeIfPresent(Bool.self, forKey: .tabBarCompactMode) ?? false
        self.tabDetachThreshold = try c.decodeIfPresent(Double.self, forKey: .tabDetachThreshold) ?? 24.0
        self.smartGroupingPolicy = try c.decodeIfPresent(SmartGroupingPolicy.self, forKey: .smartGroupingPolicy) ?? .sameApp
        self.allowCrossAppGrouping = try c.decodeIfPresent(Bool.self, forKey: .allowCrossAppGrouping) ?? false
        self.wrapAroundFocus = try c.decodeIfPresent(Bool.self, forKey: .wrapAroundFocus) ?? false
        self.cycleTabsBeforeColumns = try c.decodeIfPresent(Bool.self, forKey: .cycleTabsBeforeColumns) ?? true
        self.fullWidthToggleRestoresRatio = try c.decodeIfPresent(Bool.self, forKey: .fullWidthToggleRestoresRatio) ?? true
        self.tabAnimationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .tabAnimationsEnabled) ?? true
        self.tabSwitchEffect = try c.decodeIfPresent(TabSwitchEffect.self, forKey: .tabSwitchEffect) ?? .slide
        self.tabOpenCloseEffect = try c.decodeIfPresent(TabOpenCloseEffect.self, forKey: .tabOpenCloseEffect) ?? .scaleFade
        self.tabMotionSpeed = try c.decodeIfPresent(Double.self, forKey: .tabMotionSpeed) ?? 1.0
        self.tabHapticsEnabled = try c.decodeIfPresent(Bool.self, forKey: .tabHapticsEnabled) ?? true
        self.freezeOnRelease = try c.decodeIfPresent(Bool.self, forKey: .freezeOnRelease) ?? true
        self.freeformScroll = try c.decodeIfPresent(Bool.self, forKey: .freeformScroll) ?? true
    }
}

/// Manages atomic, file-backed persistence of all Iume preferences and user configuration.
///
/// Ensures settings memory is durable across macOS system reboots, crashes, and app updates.
/// Dual-persists to an atomic JSON file in `~/Library/Application Support/Iume/settings_memory.json`
/// and mirrors to `UserDefaults.standard` with immediate synchronization.
@MainActor
public final class SettingsMemoryManager {
    public static let shared = SettingsMemoryManager()
    
    private let fileManager = FileManager.default
    private let storageUrl: URL
    private let backupUrl: URL
    private let baselineUrl: URL
    
    private var saveDebounceTimer: Timer?
    
    public init(customStorageUrl: URL? = nil) {
        if let customUrl = customStorageUrl {
            self.storageUrl = customUrl
            self.backupUrl = customUrl.deletingPathExtension().appendingPathExtension("backup.json")
            self.baselineUrl = customUrl.deletingPathExtension().appendingPathExtension("baseline.json")
        } else if Self.isRunningTests {
            let testDir = fileManager.temporaryDirectory
                .appendingPathComponent("IumeSettingsTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            try? fileManager.createDirectory(at: testDir, withIntermediateDirectories: true)
            self.storageUrl = testDir.appendingPathComponent("settings_memory.json")
            self.backupUrl = testDir.appendingPathComponent("settings_memory.backup.json")
            self.baselineUrl = testDir.appendingPathComponent("settings_baseline.json")
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let iumeDir = appSupport.appendingPathComponent("Iume", isDirectory: true)
            try? fileManager.createDirectory(at: iumeDir, withIntermediateDirectories: true)
            self.storageUrl = iumeDir.appendingPathComponent("settings_memory.json")
            self.backupUrl = iumeDir.appendingPathComponent("settings_memory.backup.json")
            self.baselineUrl = iumeDir.appendingPathComponent("settings_baseline.json")
        }
    }
    
    /// Test hosts must never read or write the user's real memory file.
    ///
    /// Swift Testing does not load XCTest, so checking `XCTestCase` alone missed every test run
    /// that went through the shared manager. The environment and process-name checks cover both
    /// runners without affecting the app itself.
    private static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return NSClassFromString("XCTestCase") != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || ProcessInfo.processInfo.processName.contains("PackageTests")
    }

    // MARK: - Disk Serialization & Loading
    
    /// Persists snapshot atomically to disk and backup file.
    public func save(snapshot: SettingsSnapshot) {
        do {
            var toSave = snapshot
            toSave.lastSavedDate = Date()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(toSave)
            
            // Atomic write to primary storage
            try data.write(to: storageUrl, options: .atomic)
            
            // Mirror to backup file for fail-safe recovery
            try? data.write(to: backupUrl, options: .atomic)
        } catch {
            print("[Iume] SettingsMemoryManager failed to save settings snapshot: \(error.localizedDescription)")
        }
    }
    
    /// Loads snapshot from primary memory file, falling back to backup file if needed.
    public func load() -> SettingsSnapshot? {
        // 1. Try primary storage file
        if fileManager.fileExists(atPath: storageUrl.path) {
            do {
                let data = try Data(contentsOf: storageUrl)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let snapshot = try decoder.decode(SettingsSnapshot.self, from: data)
                return snapshot
            } catch {
                print("[Iume] Primary settings memory corrupt or unreadable: \(error.localizedDescription). Attempting backup.")
            }
        }
        
        // 2. Try backup storage file
        if fileManager.fileExists(atPath: backupUrl.path) {
            do {
                let data = try Data(contentsOf: backupUrl)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let snapshot = try decoder.decode(SettingsSnapshot.self, from: data)
                // Repair primary file from backup
                save(snapshot: snapshot)
                return snapshot
            } catch {
                print("[Iume] Backup settings memory also corrupt: \(error.localizedDescription)")
            }
        }
        
        return nil
    }
    
    /// Checks if a valid persistent memory file exists on disk.
    public var hasSavedMemory: Bool {
        fileManager.fileExists(atPath: storageUrl.path)
    }
    
    /// Date of last modification of the memory file on disk.
    public var lastSavedDate: Date? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: storageUrl.path),
              let mod = attrs[.modificationDate] as? Date else {
            return nil
        }
        return mod
    }
    
    // MARK: - User Baseline Profile ("Remember My Settings")
    
    /// Saves the current snapshot as the user's explicit preferred baseline profile.
    public func saveBaselineProfile(snapshot: SettingsSnapshot) {
        do {
            var baseline = snapshot
            baseline.profileName = "User Preferred Baseline"
            baseline.lastSavedDate = Date()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(baseline)
            try data.write(to: baselineUrl, options: .atomic)
        } catch {
            print("[Iume] Failed to save preferred baseline: \(error.localizedDescription)")
        }
    }
    
    /// Loads the user's explicit preferred baseline profile if saved.
    public func loadBaselineProfile() -> SettingsSnapshot? {
        guard fileManager.fileExists(atPath: baselineUrl.path) else { return nil }
        do {
            let data = try Data(contentsOf: baselineUrl)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(SettingsSnapshot.self, from: data)
        } catch {
            print("[Iume] Failed to load baseline profile: \(error.localizedDescription)")
            return nil
        }
    }
    
    public var hasBaselineProfile: Bool {
        fileManager.fileExists(atPath: baselineUrl.path)
    }
    
    // MARK: - Debounced & Immediate Scheduling
    
    /// Debounces rapid setting updates (e.g. dragging sliders) while guaranteeing
    /// an atomic write within 150ms.
    public func scheduleSave(from store: SettingsStore) {
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self, weak store] _ in
            Task { @MainActor in
                guard let self = self, let store = store else { return }
                let snapshot = store.captureSnapshot()
                self.save(snapshot: snapshot)
            }
        }
    }
    
    /// Flushes any pending setting changes to disk immediately.
    /// Call before app termination or system sleep.
    public func flush(from store: SettingsStore) {
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = nil
        let snapshot = store.captureSnapshot()
        save(snapshot: snapshot)
    }
    
    // MARK: - Export & Import
    
    public func exportSettings(snapshot: SettingsSnapshot, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }
    
    public func importSettings(from url: URL) throws -> SettingsSnapshot {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(SettingsSnapshot.self, from: data)
        save(snapshot: snapshot)
        return snapshot
    }
}
