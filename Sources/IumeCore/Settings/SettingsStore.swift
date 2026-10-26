import AppKit
import Foundation
import Combine
import ServiceManagement

/// Manages persistent application settings via SettingsMemoryManager and UserDefaults.
///
/// Ensures user preferences and settings memory are preserved across computer reboots,
/// app updates, and system terminations. Dual-persists to an atomic JSON file in Application Support
/// and mirrors to standard macOS UserDefaults with immediate synchronization.
@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()
    public nonisolated static let defaultsDomain = "com.iume.Iume"
    public nonisolated static let defaultPresetWidthRatios: [Double] = [0.25, 0.333, 0.50, 0.667, 0.75, 1.0]

    /// The domain every preference lives in, for the few flags that are read outside this store
    /// (welcome dismissal, last settings pane). Using `.standard` here looks harmless in a
    /// bundled app and silently splits the domain in a test host or an unbundled run.
    public nonisolated static var applicationDefaults: UserDefaults {
        UserDefaults(suiteName: defaultsDomain) ?? .standard
    }
    
    private var defaults: UserDefaults
    private let memoryManager: SettingsMemoryManager
    
    // MARK: - Keys
    private enum Keys {
        static let autoTabSameAppWindows = "iume.autoTabSameAppWindows"
        static let tabBarCompactMode = "iume.tabBarCompactMode"
        static let tabDetachThreshold = "iume.tabDetachThreshold"
        static let smartGroupingPolicy = "iume.smartGroupingPolicy"
        static let allowCrossAppGrouping = "iume.allowCrossAppGrouping"
        static let wrapAroundFocus = "iume.wrapAroundFocus"
        static let cycleTabsBeforeColumns = "iume.cycleTabsBeforeColumns"
        static let fullWidthToggleRestoresRatio = "iume.fullWidthToggleRestoresRatio"
        static let tabAnimationsEnabled = "iume.tabAnimationsEnabled"
        static let tabSwitchEffect = "iume.tabSwitchEffect"
        static let tabOpenCloseEffect = "iume.tabOpenCloseEffect"
        static let tabMotionSpeed = "iume.tabMotionSpeed"
        static let tabHapticsEnabled = "iume.tabHapticsEnabled"
        static let freezeOnRelease = "iume.freezeOnRelease"
        static let freeformScroll = "iume.freeformScroll"
        static let isEnabled = "iume.isEnabled"
        static let layoutMode = "iume.layoutMode"
        static let insertionPolicy = "iume.insertionPolicy"
        static let windowGap = "iume.windowGap"
        static let defaultColumnWidthRatio = "iume.defaultColumnWidthRatio"
        static let snapToColumn = "iume.snapToColumn"
        static let animationDuration = "iume.animationDuration"
        static let trackpadNaturalScroll = "iume.trackpadNaturalScroll"
        static let scrollTriggerMode = "iume.scrollTriggerMode"
        static let scrollSensitivity = "iume.scrollSensitivity"
        static let momentumScrolling = "iume.momentumScrolling"
        static let showMinimapHUD = "iume.showMinimapHUD"
        static let hudStyle = "iume.hudStyle"
        static let hudAlwaysVisible = "iume.hudAlwaysVisible"
        static let hudSoundEnabled = "iume.hudSoundEnabled"
        static let hudSoundVolume = "iume.hudSoundVolume"
        static let showFocusBorder = "iume.showFocusBorder"
        static let launchAtLogin = "iume.launchAtLogin"
        static let excludedBundleIdentifiers = "iume.excludedBundleIdentifiers"
        static let focusFollowsMouse = "iume.focusFollowsMouse"
        static let mouseFollowsFocus = "iume.mouseFollowsFocus"
        static let centerMode = "iume.centerMode"
        static let dimUnfocusedWindows = "iume.dimUnfocusedWindows"
        static let dragToReorder = "iume.dragToReorder"
        static let appRules = "iume.appRules"
        static let presetWidthRatios = "iume.presetWidthRatios"
        static let useLegacyOptionShortcuts = "iume.useLegacyOptionShortcuts"
        static let shortcutBindings = "iume.shortcutBindings"
        static let edgeMarginTop = "iume.edgeMarginTop"
        static let edgeMarginBottom = "iume.edgeMarginBottom"
        static let edgeMarginLeft = "iume.edgeMarginLeft"
        static let edgeMarginRight = "iume.edgeMarginRight"
        static let scrollSmoothness = "iume.scrollSmoothness"
        static let scrollDeceleration = "iume.scrollDeceleration"
        static let inertialScrolling = "iume.inertialScrolling"
        static let momentumMultiplier = "iume.momentumMultiplier"
        static let kineticScrollingProfile = "iume.kineticScrollingProfile"
        static let smoothScrollingEnabled = "iume.smoothScrollingEnabled"
        static let enableTransitions = "iume.enableTransitions"
        static let appsEdgeTogether = "iume.appsEdgeTogether"
        static let edgeSnapping = "iume.edgeSnapping"
        static let disabledDisplayIds = "iume.disabledDisplayIds"
        static let smartWindowMargins = "iume.smartWindowMargins"
        static let disablePaddingOnBuiltinDisplay = "iume.disablePaddingOnBuiltinDisplay"
        static let floatSmallWindows = "iume.floatSmallWindows"
        static let smallWindowThreshold = "iume.smallWindowThreshold"
        static let followSpaceThrownWindows = "iume.followSpaceThrownWindows"
        static let modifierDragMoveResize = "iume.modifierDragMoveResize"
        static let showLiveFootprintPreview = "iume.showLiveFootprintPreview"
        static let magneticSnapTransition = "iume.magneticSnapTransition"
        static let windowInsertionAnimation = "iume.windowInsertionAnimation"
        static let loopMode = "iume.loopMode"
        static let loopSeamSoundEnabled = "iume.loopSeamSoundEnabled"
    }
    
    // MARK: - Published Properties
    
    @Published public var loopMode: Bool {
        didSet {
            defaults.set(loopMode, forKey: Keys.loopMode)
            notifyChange()
        }
    }
    
    /// Quiet tick each time the endless strip completes a lap while Loop Mode is on.
    /// Independent of the Minimap HUD; still obeys the shared sound master switch and volume.
    @Published public var loopSeamSoundEnabled: Bool {
        didSet {
            defaults.set(loopSeamSoundEnabled, forKey: Keys.loopSeamSoundEnabled)
            notifyChange()
        }
    }
    
    @Published public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.isEnabled)
            notifyChange()
        }
    }
    
    @Published public var layoutMode: LayoutMode {
        didSet {
            defaults.set(layoutMode.rawValue, forKey: Keys.layoutMode)
            notifyChange()
        }
    }
    
    @Published public var insertionPolicy: InsertionPolicy {
        didSet {
            defaults.set(insertionPolicy.rawValue, forKey: Keys.insertionPolicy)
            notifyChange()
        }
    }
    
    public var savedPreviousGap: Double = 12.0
    
    @Published public var appsEdgeTogether: Bool = true {
        didSet {
            defaults.set(appsEdgeTogether, forKey: Keys.appsEdgeTogether)
            if appsEdgeTogether {
                if windowGap > 0 { savedPreviousGap = windowGap }
                if windowGap != 0.0 { windowGap = 0.0 }
            } else if windowGap == 0.0 {
                windowGap = savedPreviousGap > 0 ? savedPreviousGap : 12.0
            }
            notifyChange()
        }
    }
    
    @Published public var edgeSnapping: Bool = true {
        didSet {
            defaults.set(edgeSnapping, forKey: Keys.edgeSnapping)
            notifyChange()
        }
    }
    
    @Published public var windowGap: Double {
        didSet {
            defaults.set(windowGap, forKey: Keys.windowGap)
            let isTogether = (windowGap == 0.0)
            if appsEdgeTogether != isTogether {
                appsEdgeTogether = isTogether
            }
            if windowGap > 0 {
                savedPreviousGap = windowGap
            }
            notifyChange()
        }
    }
    
    @Published public var defaultColumnWidthRatio: Double {
        didSet {
            defaults.set(defaultColumnWidthRatio, forKey: Keys.defaultColumnWidthRatio)
            notifyChange()
        }
    }
    
    @Published public var snapToColumn: Bool {
        didSet {
            defaults.set(snapToColumn, forKey: Keys.snapToColumn)
            notifyChange()
        }
    }
    
    @Published public var animationDuration: Double {
        didSet {
            defaults.set(animationDuration, forKey: Keys.animationDuration)
            notifyChange()
        }
    }
    
    @Published public var trackpadNaturalScroll: Bool {
        didSet {
            defaults.set(trackpadNaturalScroll, forKey: Keys.trackpadNaturalScroll)
            notifyChange()
        }
    }
    
    @Published public var scrollTriggerMode: ScrollTriggerMode {
        didSet {
            defaults.set(scrollTriggerMode.rawValue, forKey: Keys.scrollTriggerMode)
            notifyChange()
        }
    }
    
    @Published public var scrollSensitivity: Double {
        didSet {
            defaults.set(scrollSensitivity, forKey: Keys.scrollSensitivity)
            notifyChange()
        }
    }
    
    @Published public var scrollSmoothness: Double {
        didSet {
            defaults.set(scrollSmoothness, forKey: Keys.scrollSmoothness)
            notifyChange()
        }
    }
    
    // [LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:PhysicsSettingsProperties]
    // Description: SettingsStore physics properties governing deceleration, inertia, momentum multiplier, profiles, and smoothness.
    /// Exponential decay factor for inertial/momentum coasting (0.88 to 0.995; default 0.965).
    /// Lower = higher friction (fast stop); Higher = lower friction (long glide).
    @Published public var scrollDeceleration: Double {
        didSet {
            defaults.set(scrollDeceleration, forKey: Keys.scrollDeceleration)
            notifyChange()
        }
    }
    
    /// Whether scrolling continues on inertia after fingers leave the trackpad.
    @Published public var inertialScrolling: Bool {
        didSet {
            defaults.set(inertialScrolling, forKey: Keys.inertialScrolling)
            if inertialScrolling && freezeOnRelease {
                freezeOnRelease = false
            }
            notifyChange()
        }
    }
    
    /// Multiplier scaling gesture velocity into inertial coasting momentum (0.5x to 2.5x; default 1.0x).
    @Published public var momentumMultiplier: Double {
        didSet {
            defaults.set(momentumMultiplier, forKey: Keys.momentumMultiplier)
            notifyChange()
        }
    }
    
    /// Physics simulation profile governing kinetic deceleration and drag.
    @Published public var kineticScrollingProfile: KineticScrollingProfile {
        didSet {
            defaults.set(kineticScrollingProfile.rawValue, forKey: Keys.kineticScrollingProfile)
            notifyChange()
        }
    }
    
    /// When true, transitions and discrete position steps (wheel, keyboard, targets) interpolate smoothly.
    @Published public var smoothScrollingEnabled: Bool {
        didSet {
            defaults.set(smoothScrollingEnabled, forKey: Keys.smoothScrollingEnabled)
            notifyChange()
        }
    }
    // [END LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:PhysicsSettingsProperties]
    
    @Published public var enableTransitions: Bool {
        didSet {
            defaults.set(enableTransitions, forKey: Keys.enableTransitions)
            notifyChange()
        }
    }
    
    @Published public var momentumScrolling: Bool {
        didSet {
            defaults.set(momentumScrolling, forKey: Keys.momentumScrolling)
            notifyChange()
        }
    }
    
    @Published public var showMinimapHUD: Bool {
        didSet {
            defaults.set(showMinimapHUD, forKey: Keys.showMinimapHUD)
            notifyChange()
        }
    }
    
    /// Visual presentation style of the floating minimap HUD.
    @Published public var hudStyle: MinimapHUDStyle {
        didSet {
            defaults.set(hudStyle.rawValue, forKey: Keys.hudStyle)
            notifyChange()
        }
    }
    
    /// When true the circular dial stays on screen (dimmed while idle) so it can be used as a
    /// persistent control surface. When false it only appears while the strip is scrolling.
    @Published public var hudAlwaysVisible: Bool {
        didSet {
            defaults.set(hudAlwaysVisible, forKey: Keys.hudAlwaysVisible)
            notifyChange()
        }
    }
    
    @Published public var hudSoundEnabled: Bool {
        didSet {
            defaults.set(hudSoundEnabled, forKey: Keys.hudSoundEnabled)
            notifyChange()
        }
    }
    
    /// Master volume for synthesised HUD feedback. Kept low by design.
    @Published public var hudSoundVolume: Double {
        didSet {
            defaults.set(hudSoundVolume, forKey: Keys.hudSoundVolume)
            notifyChange()
        }
    }
    
    @Published public var showFocusBorder: Bool {
        didSet {
            defaults.set(showFocusBorder, forKey: Keys.showFocusBorder)
            notifyChange()
        }
    }
    
    @Published public var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            notifyChange()
            syncLaunchAtLoginWithSystem()
        }
    }
    
    @Published public var focusFollowsMouse: Bool {
        didSet {
            defaults.set(focusFollowsMouse, forKey: Keys.focusFollowsMouse)
            notifyChange()
        }
    }
    
    @Published public var mouseFollowsFocus: Bool {
        didSet {
            defaults.set(mouseFollowsFocus, forKey: Keys.mouseFollowsFocus)
            notifyChange()
        }
    }
    
    @Published public var centerMode: CenterMode {
        didSet {
            defaults.set(centerMode.rawValue, forKey: Keys.centerMode)
            notifyChange()
        }
    }
    
    @Published public var dimUnfocusedWindows: Bool {
        didSet {
            defaults.set(dimUnfocusedWindows, forKey: Keys.dimUnfocusedWindows)
            notifyChange()
        }
    }
    
    @Published public var dragToReorder: Bool {
        didSet {
            defaults.set(dragToReorder, forKey: Keys.dragToReorder)
            notifyChange()
        }
    }
    
    @Published public var presetWidthRatios: [Double] {
        didSet {
            defaults.set(presetWidthRatios, forKey: Keys.presetWidthRatios)
            notifyChange()
        }
    }
    
    @Published public var useLegacyOptionShortcuts: Bool {
        didSet {
            defaults.set(useLegacyOptionShortcuts, forKey: Keys.useLegacyOptionShortcuts)
            notifyChange()
        }
    }

    /// Every action's chords, including deliberately unbound actions. Persisted as JSON so a
    /// user's remapping survives updates.
    @Published public var shortcutBindings: [ShortcutBinding] {
        didSet {
            if let data = try? JSONEncoder().encode(shortcutBindings) {
                defaults.set(data, forKey: Keys.shortcutBindings)
            }
            notifyChange()
        }
    }
    
    @Published public var edgeMargins: EdgeMargins {
        didSet {
            defaults.set(Double(edgeMargins.top), forKey: Keys.edgeMarginTop)
            defaults.set(Double(edgeMargins.bottom), forKey: Keys.edgeMarginBottom)
            defaults.set(Double(edgeMargins.left), forKey: Keys.edgeMarginLeft)
            defaults.set(Double(edgeMargins.right), forKey: Keys.edgeMarginRight)
            notifyChange()
        }
    }
    
    @Published public var appRules: [AppWindowRule] {
        didSet {
            if let data = try? JSONEncoder().encode(appRules) {
                defaults.set(data, forKey: Keys.appRules)
            }
            notifyChange()
        }
    }
    
    @Published public var excludedBundleIdentifiers: [String] {
        didSet {
            defaults.set(excludedBundleIdentifiers, forKey: Keys.excludedBundleIdentifiers)
            notifyChange()
        }
    }
    
    @Published public var disabledDisplayIds: [UInt32] {
        didSet {
            defaults.set(disabledDisplayIds, forKey: Keys.disabledDisplayIds)
            notifyChange()
        }
    }
    
    @Published public var smartWindowMargins: Bool {
        didSet {
            defaults.set(smartWindowMargins, forKey: Keys.smartWindowMargins)
            notifyChange()
        }
    }
    
    @Published public var disablePaddingOnBuiltinDisplay: Bool {
        didSet {
            defaults.set(disablePaddingOnBuiltinDisplay, forKey: Keys.disablePaddingOnBuiltinDisplay)
            notifyChange()
        }
    }
    
    @Published public var floatSmallWindows: Bool {
        didSet {
            defaults.set(floatSmallWindows, forKey: Keys.floatSmallWindows)
            notifyChange()
        }
    }
    
    @Published public var smallWindowThreshold: Double {
        didSet {
            defaults.set(smallWindowThreshold, forKey: Keys.smallWindowThreshold)
            notifyChange()
        }
    }
    
    @Published public var followSpaceThrownWindows: Bool {
        didSet {
            defaults.set(followSpaceThrownWindows, forKey: Keys.followSpaceThrownWindows)
            notifyChange()
        }
    }
    
    @Published public var modifierDragMoveResize: Bool {
        didSet {
            defaults.set(modifierDragMoveResize, forKey: Keys.modifierDragMoveResize)
            notifyChange()
        }
    }
    
    @Published public var showLiveFootprintPreview: Bool {
        didSet {
            defaults.set(showLiveFootprintPreview, forKey: Keys.showLiveFootprintPreview)
            notifyChange()
        }
    }
    
    @Published public var magneticSnapTransition: MagneticSnapTransitionStyle {
        didSet {
            defaults.set(magneticSnapTransition.rawValue, forKey: Keys.magneticSnapTransition)
            notifyChange()
        }
    }
    
    @Published public var windowInsertionAnimation: WindowInsertionAnimationStyle {
        didSet {
            defaults.set(windowInsertionAnimation.rawValue, forKey: Keys.windowInsertionAnimation)
            notifyChange()
        }
    }
    
    @Published public var autoTabSameAppWindows: Bool {
        didSet { defaults.set(autoTabSameAppWindows, forKey: Keys.autoTabSameAppWindows); notifyChange() }
    }
    @Published public var tabBarCompactMode: Bool {
        didSet { defaults.set(tabBarCompactMode, forKey: Keys.tabBarCompactMode); notifyChange() }
    }
    @Published public var tabDetachThreshold: Double {
        didSet { defaults.set(tabDetachThreshold, forKey: Keys.tabDetachThreshold); notifyChange() }
    }
    @Published public var smartGroupingPolicy: SmartGroupingPolicy {
        didSet { defaults.set(smartGroupingPolicy.rawValue, forKey: Keys.smartGroupingPolicy); notifyChange() }
    }
    @Published public var allowCrossAppGrouping: Bool {
        didSet { defaults.set(allowCrossAppGrouping, forKey: Keys.allowCrossAppGrouping); notifyChange() }
    }
    public var reduceMotionIsActive: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    @Published public var tabAnimationsEnabled: Bool {
        didSet { defaults.set(tabAnimationsEnabled, forKey: Keys.tabAnimationsEnabled); notifyChange() }
    }
    @Published public var tabSwitchEffect: TabSwitchEffect {
        didSet { defaults.set(tabSwitchEffect.rawValue, forKey: Keys.tabSwitchEffect); notifyChange() }
    }
    @Published public var tabOpenCloseEffect: TabOpenCloseEffect {
        didSet { defaults.set(tabOpenCloseEffect.rawValue, forKey: Keys.tabOpenCloseEffect); notifyChange() }
    }
    @Published public var tabMotionSpeed: Double {
        didSet { defaults.set(tabMotionSpeed, forKey: Keys.tabMotionSpeed); notifyChange() }
    }
    @Published public var tabHapticsEnabled: Bool {
        didSet { defaults.set(tabHapticsEnabled, forKey: Keys.tabHapticsEnabled); notifyChange() }
    }
    @Published public var wrapAroundFocus: Bool {
        didSet { defaults.set(wrapAroundFocus, forKey: Keys.wrapAroundFocus); notifyChange() }
    }
    @Published public var cycleTabsBeforeColumns: Bool {
        didSet { defaults.set(cycleTabsBeforeColumns, forKey: Keys.cycleTabsBeforeColumns); notifyChange() }
    }
    @Published public var fullWidthToggleRestoresRatio: Bool {
        didSet { defaults.set(fullWidthToggleRestoresRatio, forKey: Keys.fullWidthToggleRestoresRatio); notifyChange() }
    }
    @Published public var freezeOnRelease: Bool {
        didSet {
            defaults.set(freezeOnRelease, forKey: Keys.freezeOnRelease)
            if freezeOnRelease && inertialScrolling {
                inertialScrolling = false
            }
            notifyChange()
        }
    }
    @Published public var freeformScroll: Bool {
        didSet { defaults.set(freeformScroll, forKey: Keys.freeformScroll); notifyChange() }
    }

    // MARK: - Internal Change Notification
    
    private var isApplyingSnapshot: Bool = false
    
    private func notifyChange() {
        guard !isApplyingSnapshot else { return }
        defaults.synchronize()
        memoryManager.scheduleSave(from: self)
    }
    
    // MARK: - Initialization
    
    public init(
        defaults: UserDefaults = UserDefaults(suiteName: SettingsStore.defaultsDomain) ?? .standard,
        memoryManager: SettingsMemoryManager = .shared
    ) {
        self.defaults = defaults
        self.memoryManager = memoryManager
        
        // 1. Check for durable file-backed Settings Memory
        if let memorySnapshot = memoryManager.load() {
            // Apply loaded snapshot
            self.isEnabled = memorySnapshot.isEnabled
            self.loopMode = memorySnapshot.loopMode
            self.loopSeamSoundEnabled = memorySnapshot.loopSeamSoundEnabled
            self.layoutMode = memorySnapshot.layoutMode
            self.insertionPolicy = memorySnapshot.insertionPolicy
            self.appsEdgeTogether = memorySnapshot.appsEdgeTogether
            self.edgeSnapping = memorySnapshot.edgeSnapping
            self.savedPreviousGap = memorySnapshot.savedPreviousGap > 0 ? memorySnapshot.savedPreviousGap : 12.0
            self.windowGap = memorySnapshot.windowGap
            self.defaultColumnWidthRatio = memorySnapshot.defaultColumnWidthRatio
            self.snapToColumn = memorySnapshot.snapToColumn
            self.animationDuration = memorySnapshot.animationDuration
            self.trackpadNaturalScroll = memorySnapshot.trackpadNaturalScroll
            self.scrollTriggerMode = memorySnapshot.scrollTriggerMode
            self.scrollSensitivity = memorySnapshot.scrollSensitivity
            self.scrollSmoothness = memorySnapshot.scrollSmoothness
            self.scrollDeceleration = memorySnapshot.scrollDeceleration
            self.inertialScrolling = memorySnapshot.inertialScrolling
            self.momentumMultiplier = memorySnapshot.momentumMultiplier
            self.kineticScrollingProfile = memorySnapshot.kineticScrollingProfile
            self.smoothScrollingEnabled = memorySnapshot.smoothScrollingEnabled
            self.enableTransitions = memorySnapshot.enableTransitions
            self.momentumScrolling = memorySnapshot.momentumScrolling
            self.showMinimapHUD = memorySnapshot.showMinimapHUD
            self.hudStyle = memorySnapshot.hudStyle
            self.hudAlwaysVisible = memorySnapshot.hudAlwaysVisible
            self.hudSoundEnabled = memorySnapshot.hudSoundEnabled
            self.hudSoundVolume = memorySnapshot.hudSoundVolume
            self.showFocusBorder = memorySnapshot.showFocusBorder
            self.launchAtLogin = memorySnapshot.launchAtLogin
            self.focusFollowsMouse = memorySnapshot.focusFollowsMouse
            self.mouseFollowsFocus = memorySnapshot.mouseFollowsFocus
            self.centerMode = memorySnapshot.centerMode
            self.dimUnfocusedWindows = memorySnapshot.dimUnfocusedWindows
            self.dragToReorder = memorySnapshot.dragToReorder
            self.presetWidthRatios = memorySnapshot.presetWidthRatios
            self.useLegacyOptionShortcuts = memorySnapshot.useLegacyOptionShortcuts
            self.shortcutBindings = memorySnapshot.shortcutBindings.isEmpty ? ShortcutCatalog.defaults() : memorySnapshot.shortcutBindings
            self.edgeMargins = memorySnapshot.edgeMargins
            self.appRules = memorySnapshot.appRules
            self.excludedBundleIdentifiers = memorySnapshot.excludedBundleIdentifiers
            self.disabledDisplayIds = memorySnapshot.disabledDisplayIds
            self.smartWindowMargins = memorySnapshot.smartWindowMargins
            self.disablePaddingOnBuiltinDisplay = memorySnapshot.disablePaddingOnBuiltinDisplay
            self.floatSmallWindows = memorySnapshot.floatSmallWindows
            self.smallWindowThreshold = memorySnapshot.smallWindowThreshold
            self.followSpaceThrownWindows = memorySnapshot.followSpaceThrownWindows
            self.modifierDragMoveResize = memorySnapshot.modifierDragMoveResize
            self.showLiveFootprintPreview = memorySnapshot.showLiveFootprintPreview
            self.magneticSnapTransition = memorySnapshot.magneticSnapTransition
            self.windowInsertionAnimation = memorySnapshot.windowInsertionAnimation
            self.autoTabSameAppWindows = memorySnapshot.autoTabSameAppWindows
            self.tabBarCompactMode = memorySnapshot.tabBarCompactMode
            self.tabDetachThreshold = memorySnapshot.tabDetachThreshold
            self.smartGroupingPolicy = memorySnapshot.smartGroupingPolicy
            self.allowCrossAppGrouping = memorySnapshot.allowCrossAppGrouping
            self.tabAnimationsEnabled = memorySnapshot.tabAnimationsEnabled
            self.tabSwitchEffect = memorySnapshot.tabSwitchEffect
            self.tabOpenCloseEffect = memorySnapshot.tabOpenCloseEffect
            self.tabMotionSpeed = memorySnapshot.tabMotionSpeed
            self.tabHapticsEnabled = memorySnapshot.tabHapticsEnabled
            self.wrapAroundFocus = memorySnapshot.wrapAroundFocus
            self.cycleTabsBeforeColumns = memorySnapshot.cycleTabsBeforeColumns
            self.fullWidthToggleRestoresRatio = memorySnapshot.fullWidthToggleRestoresRatio
            self.freezeOnRelease = memorySnapshot.freezeOnRelease
            self.freeformScroll = memorySnapshot.freeformScroll
            
            // Mirror to UserDefaults for Cocoa bindings / AppKit compatibility
            syncAllToUserDefaults()
        } else {
            // 2. Fallback to existing UserDefaults if upgrading or first launch
            let suiteDefaults = UserDefaults(suiteName: SettingsStore.defaultsDomain) ?? defaults
            self.isEnabled = (defaults.object(forKey: Keys.isEnabled) ?? suiteDefaults.object(forKey: Keys.isEnabled)) as? Bool ?? true
            self.loopMode = (defaults.object(forKey: Keys.loopMode) ?? suiteDefaults.object(forKey: Keys.loopMode)) as? Bool ?? false
            self.loopSeamSoundEnabled = (defaults.object(forKey: Keys.loopSeamSoundEnabled) ?? suiteDefaults.object(forKey: Keys.loopSeamSoundEnabled)) as? Bool ?? true
            
            let savedLayout = (defaults.string(forKey: Keys.layoutMode) ?? suiteDefaults.string(forKey: Keys.layoutMode)) ?? LayoutMode.scrollStrip.rawValue
            self.layoutMode = LayoutMode(rawValue: savedLayout) ?? .scrollStrip
            
            let savedPolicy = (defaults.string(forKey: Keys.insertionPolicy) ?? suiteDefaults.string(forKey: Keys.insertionPolicy)) ?? InsertionPolicy.afterFocused.rawValue
            self.insertionPolicy = InsertionPolicy(rawValue: savedPolicy) ?? .afterFocused
            
            let loadedTogether = (defaults.object(forKey: Keys.appsEdgeTogether) ?? suiteDefaults.object(forKey: Keys.appsEdgeTogether)) as? Bool ?? true
            let loadedSnapping = (defaults.object(forKey: Keys.edgeSnapping) ?? suiteDefaults.object(forKey: Keys.edgeSnapping)) as? Bool ?? true
            let loadedGap = (defaults.object(forKey: Keys.windowGap) ?? suiteDefaults.object(forKey: Keys.windowGap)) as? Double ?? (loadedTogether ? 0.0 : 12.0)
            self.appsEdgeTogether = loadedTogether
            self.edgeSnapping = loadedSnapping
            self.windowGap = loadedTogether ? 0.0 : loadedGap
            self.savedPreviousGap = loadedGap > 0 ? loadedGap : 12.0
            self.defaultColumnWidthRatio = (defaults.object(forKey: Keys.defaultColumnWidthRatio) ?? suiteDefaults.object(forKey: Keys.defaultColumnWidthRatio)) as? Double ?? 0.50
            self.snapToColumn = (defaults.object(forKey: Keys.snapToColumn) ?? suiteDefaults.object(forKey: Keys.snapToColumn)) as? Bool ?? false
            self.animationDuration = (defaults.object(forKey: Keys.animationDuration) ?? suiteDefaults.object(forKey: Keys.animationDuration)) as? Double ?? 0.22
            self.trackpadNaturalScroll = (defaults.object(forKey: Keys.trackpadNaturalScroll) ?? suiteDefaults.object(forKey: Keys.trackpadNaturalScroll)) as? Bool ?? true
            
            let savedTrigger = (defaults.string(forKey: Keys.scrollTriggerMode) ?? suiteDefaults.string(forKey: Keys.scrollTriggerMode)) ?? ScrollTriggerMode.seamlessHorizontal.rawValue
            self.scrollTriggerMode = ScrollTriggerMode(rawValue: savedTrigger) ?? .seamlessHorizontal
            self.scrollSensitivity = (defaults.object(forKey: Keys.scrollSensitivity) ?? suiteDefaults.object(forKey: Keys.scrollSensitivity)) as? Double ?? 1.0
            self.scrollSmoothness = (defaults.object(forKey: Keys.scrollSmoothness) ?? suiteDefaults.object(forKey: Keys.scrollSmoothness)) as? Double ?? 0.75
            self.scrollDeceleration = (defaults.object(forKey: Keys.scrollDeceleration) ?? suiteDefaults.object(forKey: Keys.scrollDeceleration)) as? Double ?? 0.965
            self.inertialScrolling = (defaults.object(forKey: Keys.inertialScrolling) ?? suiteDefaults.object(forKey: Keys.inertialScrolling)) as? Bool ?? true
            self.momentumMultiplier = (defaults.object(forKey: Keys.momentumMultiplier) ?? suiteDefaults.object(forKey: Keys.momentumMultiplier)) as? Double ?? 1.0
            let savedKineticProfile = (defaults.string(forKey: Keys.kineticScrollingProfile) ?? suiteDefaults.string(forKey: Keys.kineticScrollingProfile)) ?? KineticScrollingProfile.natural.rawValue
            self.kineticScrollingProfile = KineticScrollingProfile(rawValue: savedKineticProfile) ?? .natural
            self.smoothScrollingEnabled = (defaults.object(forKey: Keys.smoothScrollingEnabled) ?? suiteDefaults.object(forKey: Keys.smoothScrollingEnabled)) as? Bool ?? true
            self.enableTransitions = (defaults.object(forKey: Keys.enableTransitions) ?? suiteDefaults.object(forKey: Keys.enableTransitions)) as? Bool ?? true
            self.momentumScrolling = (defaults.object(forKey: Keys.momentumScrolling) ?? suiteDefaults.object(forKey: Keys.momentumScrolling)) as? Bool ?? true
            self.showMinimapHUD = (defaults.object(forKey: Keys.showMinimapHUD) ?? suiteDefaults.object(forKey: Keys.showMinimapHUD)) as? Bool ?? true
            let savedHudStyle = (defaults.string(forKey: Keys.hudStyle) ?? suiteDefaults.string(forKey: Keys.hudStyle)) ?? MinimapHUDStyle.circularDial.rawValue
            self.hudStyle = MinimapHUDStyle(rawValue: savedHudStyle) ?? .circularDial
            self.hudAlwaysVisible = (defaults.object(forKey: Keys.hudAlwaysVisible) ?? suiteDefaults.object(forKey: Keys.hudAlwaysVisible)) as? Bool ?? false
            self.hudSoundEnabled = (defaults.object(forKey: Keys.hudSoundEnabled) ?? suiteDefaults.object(forKey: Keys.hudSoundEnabled)) as? Bool ?? false
            self.hudSoundVolume = (defaults.object(forKey: Keys.hudSoundVolume) ?? suiteDefaults.object(forKey: Keys.hudSoundVolume)) as? Double ?? 0.14
            self.showFocusBorder = (defaults.object(forKey: Keys.showFocusBorder) ?? suiteDefaults.object(forKey: Keys.showFocusBorder)) as? Bool ?? false
            
            self.launchAtLogin = (defaults.object(forKey: Keys.launchAtLogin) ?? suiteDefaults.object(forKey: Keys.launchAtLogin)) as? Bool ?? false
            self.focusFollowsMouse = (defaults.object(forKey: Keys.focusFollowsMouse) ?? suiteDefaults.object(forKey: Keys.focusFollowsMouse)) as? Bool ?? false
            self.mouseFollowsFocus = (defaults.object(forKey: Keys.mouseFollowsFocus) ?? suiteDefaults.object(forKey: Keys.mouseFollowsFocus)) as? Bool ?? false
            
            let savedCenter = (defaults.string(forKey: Keys.centerMode) ?? suiteDefaults.string(forKey: Keys.centerMode)) ?? CenterMode.never.rawValue
            self.centerMode = CenterMode(rawValue: savedCenter) ?? .never
            
            self.dimUnfocusedWindows = (defaults.object(forKey: Keys.dimUnfocusedWindows) ?? suiteDefaults.object(forKey: Keys.dimUnfocusedWindows)) as? Bool ?? false
            self.dragToReorder = (defaults.object(forKey: Keys.dragToReorder) ?? suiteDefaults.object(forKey: Keys.dragToReorder)) as? Bool ?? true
            
            self.presetWidthRatios = (defaults.object(forKey: Keys.presetWidthRatios) ?? suiteDefaults.object(forKey: Keys.presetWidthRatios)) as? [Double] ?? SettingsStore.defaultPresetWidthRatios
            self.useLegacyOptionShortcuts = (defaults.object(forKey: Keys.useLegacyOptionShortcuts) ?? suiteDefaults.object(forKey: Keys.useLegacyOptionShortcuts)) as? Bool ?? false
            
            let shortcutData = defaults.data(forKey: Keys.shortcutBindings) ?? suiteDefaults.data(forKey: Keys.shortcutBindings)
            if let data = shortcutData,
               let decoded = try? JSONDecoder().decode([ShortcutBinding].self, from: data) {
                self.shortcutBindings = ShortcutCatalog.normalized(decoded)
            } else {
                self.shortcutBindings = ShortcutCatalog.defaults()
            }
            
            let top = (defaults.object(forKey: Keys.edgeMarginTop) ?? suiteDefaults.object(forKey: Keys.edgeMarginTop)) as? Double ?? 0.0
            let bottom = (defaults.object(forKey: Keys.edgeMarginBottom) ?? suiteDefaults.object(forKey: Keys.edgeMarginBottom)) as? Double ?? 0.0
            let left = (defaults.object(forKey: Keys.edgeMarginLeft) ?? suiteDefaults.object(forKey: Keys.edgeMarginLeft)) as? Double ?? 0.0
            let right = (defaults.object(forKey: Keys.edgeMarginRight) ?? suiteDefaults.object(forKey: Keys.edgeMarginRight)) as? Double ?? 0.0
            self.edgeMargins = EdgeMargins(top: CGFloat(top), bottom: CGFloat(bottom), left: CGFloat(left), right: CGFloat(right))
            
            let appRulesData = defaults.data(forKey: Keys.appRules) ?? suiteDefaults.data(forKey: Keys.appRules)
            if let data = appRulesData,
               let decoded = try? JSONDecoder().decode([AppWindowRule].self, from: data) {
                self.appRules = decoded
            } else {
                self.appRules = []
            }
            
            let defaultExclusions = [
                "com.apple.notificationcenterui",
                "com.apple.controlcenter",
                "com.apple.Spotlight",
                "com.apple.SystemSettings"
            ]
            var saved = (defaults.stringArray(forKey: Keys.excludedBundleIdentifiers) ?? suiteDefaults.stringArray(forKey: Keys.excludedBundleIdentifiers)) ?? defaultExclusions
            saved.removeAll { $0 == "com.apple.finder" }
            self.excludedBundleIdentifiers = saved
            self.disabledDisplayIds = ((defaults.array(forKey: Keys.disabledDisplayIds) ?? suiteDefaults.array(forKey: Keys.disabledDisplayIds)) as? [UInt32]) ?? []
            self.smartWindowMargins = (defaults.object(forKey: Keys.smartWindowMargins) ?? suiteDefaults.object(forKey: Keys.smartWindowMargins)) as? Bool ?? false
            self.disablePaddingOnBuiltinDisplay = (defaults.object(forKey: Keys.disablePaddingOnBuiltinDisplay) ?? suiteDefaults.object(forKey: Keys.disablePaddingOnBuiltinDisplay)) as? Bool ?? false
            self.floatSmallWindows = (defaults.object(forKey: Keys.floatSmallWindows) ?? suiteDefaults.object(forKey: Keys.floatSmallWindows)) as? Bool ?? true
            self.smallWindowThreshold = (defaults.object(forKey: Keys.smallWindowThreshold) ?? suiteDefaults.object(forKey: Keys.smallWindowThreshold)) as? Double ?? 500.0
            self.followSpaceThrownWindows = (defaults.object(forKey: Keys.followSpaceThrownWindows) ?? suiteDefaults.object(forKey: Keys.followSpaceThrownWindows)) as? Bool ?? true
            self.modifierDragMoveResize = (defaults.object(forKey: Keys.modifierDragMoveResize) ?? suiteDefaults.object(forKey: Keys.modifierDragMoveResize)) as? Bool ?? true
            self.showLiveFootprintPreview = (defaults.object(forKey: Keys.showLiveFootprintPreview) ?? suiteDefaults.object(forKey: Keys.showLiveFootprintPreview)) as? Bool ?? true
            let savedMagTrans = (defaults.string(forKey: Keys.magneticSnapTransition) ?? suiteDefaults.string(forKey: Keys.magneticSnapTransition)) ?? MagneticSnapTransitionStyle.liquidSpring.rawValue
            self.magneticSnapTransition = MagneticSnapTransitionStyle(rawValue: savedMagTrans) ?? .liquidSpring
            let savedInsAnim = (defaults.string(forKey: Keys.windowInsertionAnimation) ?? suiteDefaults.string(forKey: Keys.windowInsertionAnimation)) ?? WindowInsertionAnimationStyle.partingWave.rawValue
            self.windowInsertionAnimation = WindowInsertionAnimationStyle(rawValue: savedInsAnim) ?? .partingWave
            self.autoTabSameAppWindows = (defaults.object(forKey: Keys.autoTabSameAppWindows) ?? suiteDefaults.object(forKey: Keys.autoTabSameAppWindows)) as? Bool ?? false
            self.tabBarCompactMode = (defaults.object(forKey: Keys.tabBarCompactMode) ?? suiteDefaults.object(forKey: Keys.tabBarCompactMode)) as? Bool ?? false
            self.tabDetachThreshold = (defaults.object(forKey: Keys.tabDetachThreshold) ?? suiteDefaults.object(forKey: Keys.tabDetachThreshold)) as? Double ?? 120.0
            let savedSmartGrouping = (defaults.string(forKey: Keys.smartGroupingPolicy) ?? suiteDefaults.string(forKey: Keys.smartGroupingPolicy)) ?? SmartGroupingPolicy.manualOnly.rawValue
            self.smartGroupingPolicy = SmartGroupingPolicy(rawValue: savedSmartGrouping) ?? .manualOnly
            self.allowCrossAppGrouping = (defaults.object(forKey: Keys.allowCrossAppGrouping) ?? suiteDefaults.object(forKey: Keys.allowCrossAppGrouping)) as? Bool ?? true
            self.tabAnimationsEnabled = (defaults.object(forKey: Keys.tabAnimationsEnabled) ?? suiteDefaults.object(forKey: Keys.tabAnimationsEnabled)) as? Bool ?? true
            let savedSwitchEffect = (defaults.string(forKey: Keys.tabSwitchEffect) ?? suiteDefaults.string(forKey: Keys.tabSwitchEffect)) ?? TabSwitchEffect.slide.rawValue
            self.tabSwitchEffect = TabSwitchEffect(rawValue: savedSwitchEffect) ?? .slide
            let savedOpenCloseEffect = (defaults.string(forKey: Keys.tabOpenCloseEffect) ?? suiteDefaults.string(forKey: Keys.tabOpenCloseEffect)) ?? TabOpenCloseEffect.scaleFade.rawValue
            self.tabOpenCloseEffect = TabOpenCloseEffect(rawValue: savedOpenCloseEffect) ?? .scaleFade
            self.tabMotionSpeed = (defaults.object(forKey: Keys.tabMotionSpeed) ?? suiteDefaults.object(forKey: Keys.tabMotionSpeed)) as? Double ?? 1.0
            self.tabHapticsEnabled = (defaults.object(forKey: Keys.tabHapticsEnabled) ?? suiteDefaults.object(forKey: Keys.tabHapticsEnabled)) as? Bool ?? true
            self.wrapAroundFocus = (defaults.object(forKey: Keys.wrapAroundFocus) ?? suiteDefaults.object(forKey: Keys.wrapAroundFocus)) as? Bool ?? false
            self.cycleTabsBeforeColumns = (defaults.object(forKey: Keys.cycleTabsBeforeColumns) ?? suiteDefaults.object(forKey: Keys.cycleTabsBeforeColumns)) as? Bool ?? true
            self.fullWidthToggleRestoresRatio = (defaults.object(forKey: Keys.fullWidthToggleRestoresRatio) ?? suiteDefaults.object(forKey: Keys.fullWidthToggleRestoresRatio)) as? Bool ?? true
            self.freezeOnRelease = (defaults.object(forKey: Keys.freezeOnRelease) ?? suiteDefaults.object(forKey: Keys.freezeOnRelease)) as? Bool ?? false
            self.freeformScroll = (defaults.object(forKey: Keys.freeformScroll) ?? suiteDefaults.object(forKey: Keys.freeformScroll)) as? Bool ?? true
            
            // Establish the durable file snapshot immediately
            let initialSnapshot = captureSnapshot()
            memoryManager.save(snapshot: initialSnapshot)
            syncAllToUserDefaults()
        }
        
        // Ensure launch-at-login aligns with SMAppService
        syncLaunchAtLoginWithSystem()
    }
    
    // MARK: - Snapshot Capture & Restoration
    
    public func captureSnapshot(profileName: String = "User Preferred") -> SettingsSnapshot {
        SettingsSnapshot(
            schemaVersion: 1,
            lastSavedDate: Date(),
            isMemoryLocked: false,
            profileName: profileName,
            isEnabled: isEnabled,
            layoutMode: layoutMode,
            insertionPolicy: insertionPolicy,
            centerMode: centerMode,
            floatSmallWindows: floatSmallWindows,
            smallWindowThreshold: smallWindowThreshold,
            followSpaceThrownWindows: followSpaceThrownWindows,
            modifierDragMoveResize: modifierDragMoveResize,
            showLiveFootprintPreview: showLiveFootprintPreview,
            windowGap: windowGap,
            appsEdgeTogether: appsEdgeTogether,
            savedPreviousGap: savedPreviousGap,
            edgeSnapping: edgeSnapping,
            defaultColumnWidthRatio: defaultColumnWidthRatio,
            snapToColumn: snapToColumn,
            presetWidthRatios: presetWidthRatios,
            edgeMargins: edgeMargins,
            smartWindowMargins: smartWindowMargins,
            disablePaddingOnBuiltinDisplay: disablePaddingOnBuiltinDisplay,
            animationDuration: animationDuration,
            trackpadNaturalScroll: trackpadNaturalScroll,
            scrollTriggerMode: scrollTriggerMode,
            scrollSensitivity: scrollSensitivity,
            scrollSmoothness: scrollSmoothness,
            scrollDeceleration: scrollDeceleration,
            inertialScrolling: inertialScrolling,
            momentumMultiplier: momentumMultiplier,
            kineticScrollingProfile: kineticScrollingProfile,
            smoothScrollingEnabled: smoothScrollingEnabled,
            enableTransitions: enableTransitions,
            momentumScrolling: momentumScrolling,
            magneticSnapTransition: magneticSnapTransition,
            windowInsertionAnimation: windowInsertionAnimation,
            showMinimapHUD: showMinimapHUD,
            hudStyle: hudStyle,
            hudAlwaysVisible: hudAlwaysVisible,
            hudSoundEnabled: hudSoundEnabled,
            hudSoundVolume: hudSoundVolume,
            loopMode: loopMode,
            loopSeamSoundEnabled: loopSeamSoundEnabled,
            showFocusBorder: showFocusBorder,
            focusFollowsMouse: focusFollowsMouse,
            mouseFollowsFocus: mouseFollowsFocus,
            dimUnfocusedWindows: dimUnfocusedWindows,
            dragToReorder: dragToReorder,
            launchAtLogin: launchAtLogin,
            excludedBundleIdentifiers: excludedBundleIdentifiers,
            disabledDisplayIds: disabledDisplayIds,
            appRules: appRules,
            useLegacyOptionShortcuts: useLegacyOptionShortcuts,
            shortcutBindings: shortcutBindings,
            autoTabSameAppWindows: autoTabSameAppWindows,
            tabBarCompactMode: tabBarCompactMode,
            tabDetachThreshold: tabDetachThreshold,
            smartGroupingPolicy: smartGroupingPolicy,
            allowCrossAppGrouping: allowCrossAppGrouping,
            wrapAroundFocus: wrapAroundFocus,
            cycleTabsBeforeColumns: cycleTabsBeforeColumns,
            fullWidthToggleRestoresRatio: fullWidthToggleRestoresRatio,
            tabAnimationsEnabled: tabAnimationsEnabled,
            tabSwitchEffect: tabSwitchEffect,
            tabOpenCloseEffect: tabOpenCloseEffect,
            tabMotionSpeed: tabMotionSpeed,
            tabHapticsEnabled: tabHapticsEnabled,
            freezeOnRelease: freezeOnRelease,
            freeformScroll: freeformScroll
        )
    }
    
    public func applySnapshot(_ snapshot: SettingsSnapshot, persistToDisk: Bool = true) {
        isApplyingSnapshot = true
        defer {
            isApplyingSnapshot = false
            if persistToDisk {
                defaults.synchronize()
                memoryManager.save(snapshot: snapshot)
            }
        }
        
        self.isEnabled = snapshot.isEnabled
        self.loopMode = snapshot.loopMode
        self.loopSeamSoundEnabled = snapshot.loopSeamSoundEnabled
        self.layoutMode = snapshot.layoutMode
        self.insertionPolicy = snapshot.insertionPolicy
        self.appsEdgeTogether = snapshot.appsEdgeTogether
        self.edgeSnapping = snapshot.edgeSnapping
        self.savedPreviousGap = snapshot.savedPreviousGap > 0 ? snapshot.savedPreviousGap : 12.0
        self.windowGap = snapshot.windowGap
        self.defaultColumnWidthRatio = snapshot.defaultColumnWidthRatio
        self.snapToColumn = snapshot.snapToColumn
        self.animationDuration = snapshot.animationDuration
        self.trackpadNaturalScroll = snapshot.trackpadNaturalScroll
        self.scrollTriggerMode = snapshot.scrollTriggerMode
        self.scrollSensitivity = snapshot.scrollSensitivity
        self.scrollSmoothness = snapshot.scrollSmoothness
        self.scrollDeceleration = snapshot.scrollDeceleration
        self.inertialScrolling = snapshot.inertialScrolling
        self.momentumMultiplier = snapshot.momentumMultiplier
        self.kineticScrollingProfile = snapshot.kineticScrollingProfile
        self.smoothScrollingEnabled = snapshot.smoothScrollingEnabled
        self.enableTransitions = snapshot.enableTransitions
        self.momentumScrolling = snapshot.momentumScrolling
        self.showMinimapHUD = snapshot.showMinimapHUD
        self.hudStyle = snapshot.hudStyle
        self.hudAlwaysVisible = snapshot.hudAlwaysVisible
        self.hudSoundEnabled = snapshot.hudSoundEnabled
        self.hudSoundVolume = snapshot.hudSoundVolume
        self.showFocusBorder = snapshot.showFocusBorder
        self.launchAtLogin = snapshot.launchAtLogin
        self.focusFollowsMouse = snapshot.focusFollowsMouse
        self.mouseFollowsFocus = snapshot.mouseFollowsFocus
        self.centerMode = snapshot.centerMode
        self.dimUnfocusedWindows = snapshot.dimUnfocusedWindows
        self.dragToReorder = snapshot.dragToReorder
        self.presetWidthRatios = snapshot.presetWidthRatios
        self.useLegacyOptionShortcuts = snapshot.useLegacyOptionShortcuts
        self.shortcutBindings = snapshot.shortcutBindings
        self.edgeMargins = snapshot.edgeMargins
        self.appRules = snapshot.appRules
        self.excludedBundleIdentifiers = snapshot.excludedBundleIdentifiers
        self.disabledDisplayIds = snapshot.disabledDisplayIds
        self.smartWindowMargins = snapshot.smartWindowMargins
        self.disablePaddingOnBuiltinDisplay = snapshot.disablePaddingOnBuiltinDisplay
        self.floatSmallWindows = snapshot.floatSmallWindows
        self.smallWindowThreshold = snapshot.smallWindowThreshold
        self.followSpaceThrownWindows = snapshot.followSpaceThrownWindows
        self.modifierDragMoveResize = snapshot.modifierDragMoveResize
        self.showLiveFootprintPreview = snapshot.showLiveFootprintPreview
        self.magneticSnapTransition = snapshot.magneticSnapTransition
        self.windowInsertionAnimation = snapshot.windowInsertionAnimation
        self.autoTabSameAppWindows = snapshot.autoTabSameAppWindows
        self.tabBarCompactMode = snapshot.tabBarCompactMode
        self.tabDetachThreshold = snapshot.tabDetachThreshold
        self.smartGroupingPolicy = snapshot.smartGroupingPolicy
        self.allowCrossAppGrouping = snapshot.allowCrossAppGrouping
        self.wrapAroundFocus = snapshot.wrapAroundFocus
        self.cycleTabsBeforeColumns = snapshot.cycleTabsBeforeColumns
        self.fullWidthToggleRestoresRatio = snapshot.fullWidthToggleRestoresRatio
        self.tabAnimationsEnabled = snapshot.tabAnimationsEnabled
        self.tabSwitchEffect = snapshot.tabSwitchEffect
        self.tabOpenCloseEffect = snapshot.tabOpenCloseEffect
        self.tabMotionSpeed = snapshot.tabMotionSpeed
        self.tabHapticsEnabled = snapshot.tabHapticsEnabled
        self.freezeOnRelease = snapshot.freezeOnRelease
        self.freeformScroll = snapshot.freeformScroll
        
        syncAllToUserDefaults()
        syncLaunchAtLoginWithSystem()
    }
    
    // MARK: - Setting Memory Public API
    
    /// Checks whether settings memory is successfully saved and durable on disk.
    public var isMemoryPersisted: Bool {
        memoryManager.hasSavedMemory
    }
    
    /// Timestamp when preferences were last written to disk.
    public var memoryLastSaved: Date? {
        memoryManager.lastSavedDate
    }
    
    /// Whether the user has previously saved an explicit baseline profile.
    public var hasPreferredBaseline: Bool {
        memoryManager.hasBaselineProfile
    }
    
    /// Explicitly flushes all in-memory settings directly to disk.
    /// Call before quit or system shutdown.
    public func flushMemoryToDisk() {
        defaults.synchronize()
        memoryManager.flush(from: self)
    }
    
    /// Saves current settings configuration as the user's explicit preferred baseline profile.
    public func saveAsPreferredBaseline() {
        let snapshot = captureSnapshot(profileName: "My Preferred Baseline")
        memoryManager.saveBaselineProfile(snapshot: snapshot)
        memoryManager.save(snapshot: snapshot)
        defaults.synchronize()
    }
    
    /// Restores the user's explicit preferred baseline profile.
    public func restorePreferredBaseline() {
        if let baseline = memoryManager.loadBaselineProfile() {
            applySnapshot(baseline)
        } else if let memory = memoryManager.load() {
            applySnapshot(memory)
        }
    }
    
    /// Exports current setting memory to an external file.
    public func exportMemory(to url: URL) throws {
        let snapshot = captureSnapshot()
        try memoryManager.exportSettings(snapshot: snapshot, to: url)
    }
    
    /// Imports setting memory from an external file and activates it immediately.
    public func importMemory(from url: URL) throws {
        let snapshot = try memoryManager.importSettings(from: url)
        applySnapshot(snapshot)
    }
    
    public func resetToDefaults() {
        resetToFactoryDefaults()
    }
    
    public func resetToFactoryDefaults() {
        let factory = SettingsSnapshot()
        applySnapshot(factory)
    }
    
    // MARK: - System Service Sync
    
    public func syncLaunchAtLoginWithSystem() {
        if #available(macOS 13.0, *) {
            do {
                if launchAtLogin {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                print("[Iume] SMAppService sync status note: \(error.localizedDescription)")
            }
        }
    }
    
    private func syncAllToUserDefaults() {
        defaults.set(isEnabled, forKey: Keys.isEnabled)
        defaults.set(loopMode, forKey: Keys.loopMode)
        defaults.set(loopSeamSoundEnabled, forKey: Keys.loopSeamSoundEnabled)
        defaults.set(layoutMode.rawValue, forKey: Keys.layoutMode)
        defaults.set(insertionPolicy.rawValue, forKey: Keys.insertionPolicy)
        defaults.set(appsEdgeTogether, forKey: Keys.appsEdgeTogether)
        defaults.set(edgeSnapping, forKey: Keys.edgeSnapping)
        defaults.set(windowGap, forKey: Keys.windowGap)
        defaults.set(defaultColumnWidthRatio, forKey: Keys.defaultColumnWidthRatio)
        defaults.set(snapToColumn, forKey: Keys.snapToColumn)
        defaults.set(animationDuration, forKey: Keys.animationDuration)
        defaults.set(trackpadNaturalScroll, forKey: Keys.trackpadNaturalScroll)
        defaults.set(scrollTriggerMode.rawValue, forKey: Keys.scrollTriggerMode)
        defaults.set(scrollSensitivity, forKey: Keys.scrollSensitivity)
        defaults.set(scrollSmoothness, forKey: Keys.scrollSmoothness)
        defaults.set(scrollDeceleration, forKey: Keys.scrollDeceleration)
        defaults.set(inertialScrolling, forKey: Keys.inertialScrolling)
        defaults.set(momentumMultiplier, forKey: Keys.momentumMultiplier)
        defaults.set(kineticScrollingProfile.rawValue, forKey: Keys.kineticScrollingProfile)
        defaults.set(smoothScrollingEnabled, forKey: Keys.smoothScrollingEnabled)
        defaults.set(enableTransitions, forKey: Keys.enableTransitions)
        defaults.set(momentumScrolling, forKey: Keys.momentumScrolling)
        defaults.set(showMinimapHUD, forKey: Keys.showMinimapHUD)
        defaults.set(hudStyle.rawValue, forKey: Keys.hudStyle)
        defaults.set(hudAlwaysVisible, forKey: Keys.hudAlwaysVisible)
        defaults.set(hudSoundEnabled, forKey: Keys.hudSoundEnabled)
        defaults.set(hudSoundVolume, forKey: Keys.hudSoundVolume)
        defaults.set(showFocusBorder, forKey: Keys.showFocusBorder)
        defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
        defaults.set(focusFollowsMouse, forKey: Keys.focusFollowsMouse)
        defaults.set(mouseFollowsFocus, forKey: Keys.mouseFollowsFocus)
        defaults.set(centerMode.rawValue, forKey: Keys.centerMode)
        defaults.set(dimUnfocusedWindows, forKey: Keys.dimUnfocusedWindows)
        defaults.set(dragToReorder, forKey: Keys.dragToReorder)
        defaults.set(presetWidthRatios, forKey: Keys.presetWidthRatios)
        defaults.set(useLegacyOptionShortcuts, forKey: Keys.useLegacyOptionShortcuts)
        defaults.set(Double(edgeMargins.top), forKey: Keys.edgeMarginTop)
        defaults.set(Double(edgeMargins.bottom), forKey: Keys.edgeMarginBottom)
        defaults.set(Double(edgeMargins.left), forKey: Keys.edgeMarginLeft)
        defaults.set(Double(edgeMargins.right), forKey: Keys.edgeMarginRight)
        defaults.set(excludedBundleIdentifiers, forKey: Keys.excludedBundleIdentifiers)
        defaults.set(disabledDisplayIds, forKey: Keys.disabledDisplayIds)
        defaults.set(smartWindowMargins, forKey: Keys.smartWindowMargins)
        defaults.set(disablePaddingOnBuiltinDisplay, forKey: Keys.disablePaddingOnBuiltinDisplay)
        defaults.set(floatSmallWindows, forKey: Keys.floatSmallWindows)
        defaults.set(smallWindowThreshold, forKey: Keys.smallWindowThreshold)
        defaults.set(followSpaceThrownWindows, forKey: Keys.followSpaceThrownWindows)
        defaults.set(modifierDragMoveResize, forKey: Keys.modifierDragMoveResize)
        defaults.set(showLiveFootprintPreview, forKey: Keys.showLiveFootprintPreview)
        defaults.set(magneticSnapTransition.rawValue, forKey: Keys.magneticSnapTransition)
        defaults.set(windowInsertionAnimation.rawValue, forKey: Keys.windowInsertionAnimation)
        defaults.set(autoTabSameAppWindows, forKey: Keys.autoTabSameAppWindows)
        defaults.set(tabBarCompactMode, forKey: Keys.tabBarCompactMode)
        defaults.set(tabDetachThreshold, forKey: Keys.tabDetachThreshold)
        defaults.set(smartGroupingPolicy.rawValue, forKey: Keys.smartGroupingPolicy)
        defaults.set(allowCrossAppGrouping, forKey: Keys.allowCrossAppGrouping)
        defaults.set(tabAnimationsEnabled, forKey: Keys.tabAnimationsEnabled)
        defaults.set(tabSwitchEffect.rawValue, forKey: Keys.tabSwitchEffect)
        defaults.set(tabOpenCloseEffect.rawValue, forKey: Keys.tabOpenCloseEffect)
        defaults.set(tabMotionSpeed, forKey: Keys.tabMotionSpeed)
        defaults.set(tabHapticsEnabled, forKey: Keys.tabHapticsEnabled)
        defaults.set(wrapAroundFocus, forKey: Keys.wrapAroundFocus)
        defaults.set(cycleTabsBeforeColumns, forKey: Keys.cycleTabsBeforeColumns)
        defaults.set(fullWidthToggleRestoresRatio, forKey: Keys.fullWidthToggleRestoresRatio)
        defaults.set(freezeOnRelease, forKey: Keys.freezeOnRelease)
        defaults.set(freeformScroll, forKey: Keys.freeformScroll)
        if let data = try? JSONEncoder().encode(shortcutBindings) {
            defaults.set(data, forKey: Keys.shortcutBindings)
        }
        if let data = try? JSONEncoder().encode(appRules) {
            defaults.set(data, forKey: Keys.appRules)
        }
        defaults.synchronize()
    }
}
