import Foundation
import Combine

/// Manages persistent application settings via UserDefaults.
@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()
    
    private let defaults = UserDefaults.standard
    
    // MARK: - Keys
    private enum Keys {
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
        static let showFocusBorder = "iume.showFocusBorder"
        static let launchAtLogin = "iume.launchAtLogin"
        static let excludedBundleIdentifiers = "iume.excludedBundleIdentifiers"
        static let focusFollowsMouse = "iume.focusFollowsMouse"
    }
    
    // MARK: - Published Properties
    
    @Published public var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.isEnabled) }
    }
    
    @Published public var layoutMode: LayoutMode {
        didSet { defaults.set(layoutMode.rawValue, forKey: Keys.layoutMode) }
    }
    
    @Published public var insertionPolicy: InsertionPolicy {
        didSet { defaults.set(insertionPolicy.rawValue, forKey: Keys.insertionPolicy) }
    }
    
    @Published public var windowGap: Double {
        didSet { defaults.set(windowGap, forKey: Keys.windowGap) }
    }
    
    @Published public var defaultColumnWidthRatio: Double {
        didSet { defaults.set(defaultColumnWidthRatio, forKey: Keys.defaultColumnWidthRatio) }
    }
    
    @Published public var snapToColumn: Bool {
        didSet { defaults.set(snapToColumn, forKey: Keys.snapToColumn) }
    }
    
    @Published public var animationDuration: Double {
        didSet { defaults.set(animationDuration, forKey: Keys.animationDuration) }
    }
    
    @Published public var trackpadNaturalScroll: Bool {
        didSet { defaults.set(trackpadNaturalScroll, forKey: Keys.trackpadNaturalScroll) }
    }
    
    @Published public var scrollTriggerMode: ScrollTriggerMode {
        didSet { defaults.set(scrollTriggerMode.rawValue, forKey: Keys.scrollTriggerMode) }
    }
    
    @Published public var scrollSensitivity: Double {
        didSet { defaults.set(scrollSensitivity, forKey: Keys.scrollSensitivity) }
    }
    
    @Published public var momentumScrolling: Bool {
        didSet { defaults.set(momentumScrolling, forKey: Keys.momentumScrolling) }
    }
    
    @Published public var showMinimapHUD: Bool {
        didSet { defaults.set(showMinimapHUD, forKey: Keys.showMinimapHUD) }
    }
    
    @Published public var showFocusBorder: Bool {
        didSet { defaults.set(showFocusBorder, forKey: Keys.showFocusBorder) }
    }
    
    @Published public var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }
    
    @Published public var focusFollowsMouse: Bool {
        didSet { defaults.set(focusFollowsMouse, forKey: Keys.focusFollowsMouse) }
    }
    
    @Published public var excludedBundleIdentifiers: [String] {
        didSet { defaults.set(excludedBundleIdentifiers, forKey: Keys.excludedBundleIdentifiers) }
    }
    
    // MARK: - Initialization
    
    public init() {
        self.isEnabled = defaults.object(forKey: Keys.isEnabled) as? Bool ?? true
        
        let savedLayout = defaults.string(forKey: Keys.layoutMode) ?? LayoutMode.scrollStrip.rawValue
        self.layoutMode = LayoutMode(rawValue: savedLayout) ?? .scrollStrip
        
        let savedPolicy = defaults.string(forKey: Keys.insertionPolicy) ?? InsertionPolicy.afterFocused.rawValue
        self.insertionPolicy = InsertionPolicy(rawValue: savedPolicy) ?? .afterFocused
        
        self.windowGap = defaults.object(forKey: Keys.windowGap) as? Double ?? 12.0
        self.defaultColumnWidthRatio = defaults.object(forKey: Keys.defaultColumnWidthRatio) as? Double ?? 0.50
        self.snapToColumn = defaults.object(forKey: Keys.snapToColumn) as? Bool ?? true
        self.animationDuration = defaults.object(forKey: Keys.animationDuration) as? Double ?? 0.22
        self.trackpadNaturalScroll = defaults.object(forKey: Keys.trackpadNaturalScroll) as? Bool ?? true
        
        let savedTrigger = defaults.string(forKey: Keys.scrollTriggerMode) ?? ScrollTriggerMode.seamlessHorizontal.rawValue
        self.scrollTriggerMode = ScrollTriggerMode(rawValue: savedTrigger) ?? .seamlessHorizontal
        self.scrollSensitivity = defaults.object(forKey: Keys.scrollSensitivity) as? Double ?? 1.0
        self.momentumScrolling = defaults.object(forKey: Keys.momentumScrolling) as? Bool ?? true
        self.showMinimapHUD = defaults.object(forKey: Keys.showMinimapHUD) as? Bool ?? true
        self.showFocusBorder = defaults.object(forKey: Keys.showFocusBorder) as? Bool ?? false
        
        self.launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        self.focusFollowsMouse = defaults.object(forKey: Keys.focusFollowsMouse) as? Bool ?? false
        
        let defaultExclusions = [
            "com.apple.notificationcenterui",
            "com.apple.controlcenter",
            "com.apple.Spotlight",
            "com.apple.SystemSettings" // Small modal utility
        ]
        var saved = defaults.stringArray(forKey: Keys.excludedBundleIdentifiers) ?? defaultExclusions
        saved.removeAll { $0 == "com.apple.finder" }
        self.excludedBundleIdentifiers = saved
    }
    
    public func resetToDefaults() {
        isEnabled = true
        layoutMode = .scrollStrip
        insertionPolicy = .afterFocused
        windowGap = 12.0
        defaultColumnWidthRatio = 0.50
        snapToColumn = true
        animationDuration = 0.22
        trackpadNaturalScroll = true
        scrollTriggerMode = .seamlessHorizontal
        scrollSensitivity = 1.0
        momentumScrolling = true
        showMinimapHUD = true
        showFocusBorder = false
        focusFollowsMouse = false
        excludedBundleIdentifiers = [
            "com.apple.notificationcenterui",
            "com.apple.controlcenter",
            "com.apple.Spotlight",
            "com.apple.SystemSettings"
        ]
    }
}
