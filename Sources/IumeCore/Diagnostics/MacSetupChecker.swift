import Foundation
import AppKit
import ApplicationServices
import ServiceManagement

/// Represents the status of a specific system setting or environment configuration.
public struct SetupCheckItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let category: String
    public let isOptimal: Bool
    public let statusMessage: String
    public let recommendation: String
    
    public init(
        id: String,
        title: String,
        category: String,
        isOptimal: Bool,
        statusMessage: String,
        recommendation: String
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.isOptimal = isOptimal
        self.statusMessage = statusMessage
        self.recommendation = recommendation
    }
}

/// Diagnostic and setup inspector validating system settings, conflict detection, and environment.
@MainActor
public final class MacSetupChecker: ObservableObject {
    public static let shared = MacSetupChecker()
    
    @Published public private(set) var checkResults: [SetupCheckItem] = []
    
    public init() {
        refreshChecks()
    }
    
    public func refreshChecks() {
        checkResults = runAllChecks()
    }
    
    public func runAllChecks() -> [SetupCheckItem] {
        var items: [SetupCheckItem] = []
        
        // 1. Accessibility Permission
        let isTrusted = AXIsProcessTrusted()
        items.append(SetupCheckItem(
            id: "ax_permission",
            title: "Accessibility Permission",
            category: "Permissions",
            isOptimal: isTrusted,
            statusMessage: isTrusted ? "Granted" : "Missing / Not Trusted",
            recommendation: isTrusted ? "Optimal" : "Click 'Grant Accessibility' in System Settings > Privacy & Security > Accessibility."
        ))
        
        // 2. Application Location & Translocation
        let bundlePath = Bundle.main.bundlePath
        let isTranslocated = bundlePath.contains("AppTranslocation")
        let isInApplications = bundlePath.hasPrefix("/Applications") || bundlePath.hasPrefix(NSHomeDirectory() + "/Applications")
        let locationOptimal = isInApplications && !isTranslocated
        items.append(SetupCheckItem(
            id: "app_location",
            title: "Installation Location",
            category: "Environment",
            isOptimal: locationOptimal,
            statusMessage: locationOptimal ? "Installed in /Applications" : (isTranslocated ? "Running Translocated" : "Running outside /Applications"),
            recommendation: locationOptimal ? "Optimal" : "Move Iume.app directly to /Applications so macOS preserves your permission grants."
        ))
        
        // 3. Displays have Separate Spaces
        let spansDisplaysRef = CFPreferencesCopyAppValue("spans-displays" as CFString, "com.apple.spaces" as CFString)
        let spansDisplays = (spansDisplaysRef as? NSNumber)?.boolValue ?? false
        let separateSpacesOn = !spansDisplays // false means separate spaces is ON
        items.append(SetupCheckItem(
            id: "separate_spaces",
            title: "Displays Have Separate Spaces",
            category: "macOS Settings",
            isOptimal: separateSpacesOn,
            statusMessage: separateSpacesOn ? "Enabled (Recommended)" : "Disabled",
            recommendation: separateSpacesOn ? "Optimal" : "Enable 'Displays have separate Spaces' in System Settings > Desktop & Dock > Mission Control."
        ))
        
        // 4. Auto-rearrange Spaces by Most Recent Use
        let mruSpacesRef = CFPreferencesCopyAppValue("mru-spaces" as CFString, "com.apple.dock" as CFString)
        let mruSpaces = (mruSpacesRef as? NSNumber)?.boolValue ?? true
        let mruDisabled = !mruSpaces
        items.append(SetupCheckItem(
            id: "mru_spaces",
            title: "Auto-rearrange Spaces by Recent Use",
            category: "macOS Settings",
            isOptimal: mruDisabled,
            statusMessage: mruDisabled ? "Disabled (Optimal)" : "Enabled (May shuffle strip)",
            recommendation: mruDisabled ? "Optimal" : "Turn OFF 'Automatically rearrange Spaces based on most recent use' in System Settings > Desktop & Dock."
        ))
        
        // 5. Stage Manager
        let stageManagerRef = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString)
        let stageManagerOn = (stageManagerRef as? NSNumber)?.boolValue ?? false
        items.append(SetupCheckItem(
            id: "stage_manager",
            title: "Stage Manager",
            category: "macOS Settings",
            isOptimal: !stageManagerOn,
            statusMessage: !stageManagerOn ? "Off (Optimal)" : "On (May conflict with slide strip)",
            recommendation: !stageManagerOn ? "Optimal" : "Turn Stage Manager OFF in Control Center or System Settings > Desktop & Dock."
        ))
        
        // 6. macOS 15+ Native Window Tiling Gestures — ANY of the three enables tiling (OR)
        let tilingKeys = ["EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag", "EnableTilingOptionAccelerator"]
        var anyTilingOn = false
        for key in tilingKeys {
            if let ref = CFPreferencesCopyAppValue(key as CFString, "com.apple.WindowManager" as CFString) as? NSNumber, ref.boolValue {
                anyTilingOn = true
                break
            }
        }
        // Also check top tiling if not already found
        items.append(SetupCheckItem(
            id: "edge_tiling",
            title: "macOS 15 Edge Drag Tiling",
            category: "macOS Settings",
            isOptimal: !anyTilingOn,
            statusMessage: !anyTilingOn ? "Disabled (Clean Dragging)" : "Enabled",
            recommendation: !anyTilingOn ? "Optimal" : "Disable 'Tile by dragging windows to screen edges' in Desktop & Dock settings to avoid accidental macOS snapping."
        ))
        
        // 6b. workspaces-auto-swoosh (switch to Space with open windows) — §14.3
        let swooshRef = CFPreferencesCopyAppValue("workspaces-auto-swoosh" as CFString, "com.apple.dock" as CFString)
        let swooshOn = (swooshRef as? NSNumber)?.boolValue ?? false
        items.append(SetupCheckItem(
            id: "auto_swoosh",
            title: "Auto-switch to Space with App Windows",
            category: "macOS Settings",
            isOptimal: !swooshOn,
            statusMessage: !swooshOn ? "Off (Optimal)" : "On (May jump Spaces on settle)",
            recommendation: !swooshOn ? "Optimal" : "Turn OFF 'workspaces-auto-swoosh' in System Settings > Desktop & Dock to prevent jumps to other Spaces."
        ))
        
        // 7. Conflicting Window Managers
        let conflictList: [(bundleId: String, name: String)] = [
            ("com.knollsoft.Rectangle", "Rectangle"),
            ("com.crowdcafe.windowmagnet", "Magnet"),
            ("com.amethyst.Amethyst", "Amethyst"),
            ("bobko.aerospace", "AeroSpace"),
            ("com.koekeishiya.yabai", "yabai"),
            ("com.MrKai77.Loop", "Loop"),
            ("com.manytricks.Moom", "Moom"),
            ("com.hegenstar.BetterTouchTool", "BetterTouchTool"),
            ("com.mizage.divvy", "Divvy"),
            ("com.spectacleapp.Spectacle", "Spectacle"),
            ("org.hammerspoon.Hammerspoon", "Hammerspoon"),
            ("com.michaelvillar.paperwm.spoon", "PaperWM.spoon"),
            ("com.swishapp.Swish", "Swish"),
            ("com.betterSnapTool.BetterSnapTool", "BetterSnapTool")
        ]
        
        let runningBundleIds = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        let foundConflicts = conflictList.filter { runningBundleIds.contains($0.bundleId) }
        let hasNoConflicts = foundConflicts.isEmpty
        let conflictNames = foundConflicts.map { $0.name }.joined(separator: ", ")
        
        items.append(SetupCheckItem(
            id: "conflicts",
            title: "Conflicting Window Managers",
            category: "Software Conflicts",
            isOptimal: hasNoConflicts,
            statusMessage: hasNoConflicts ? "None Detected" : "Detected: \(conflictNames)",
            recommendation: hasNoConflicts ? "Optimal" : "Quit or disable \(conflictNames) to prevent conflicting hotkeys and window placement fights."
        ))
        
        // 8. Trackpad Horizontal Desktop Swipe Conflict
        // Must read -currentHost + global trackpad domain; Magic Trackpad uses different domain (§20 #5)
        func readSwipeGesture(_ key: String) -> Int {
            // Try -currentHost first (per-host), then global, then app domain
            if let hostRef = CFPreferencesCopyValue(key as CFString, "com.apple.AppleMultitouchTrackpad" as CFString, kCFPreferencesCurrentHost as CFString, kCFPreferencesAnyUser as CFString) as? NSNumber {
                return hostRef.intValue
            }
            if let globalRef = CFPreferencesCopyValue(key as CFString, "com.apple.trackpad.threeFingerHorizSwipeGesture" as CFString, kCFPreferencesAnyHost as CFString, kCFPreferencesAnyUser as CFString) as? NSNumber {
                return globalRef.intValue
            }
            // Fallback to standard app domain reads (also check com.apple.trackpad.* keys)
            for domain in ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad", "com.apple.trackpad"] as [CFString] {
                if let ref = CFPreferencesCopyAppValue(key as CFString, domain) as? NSNumber {
                    // Return if non-default; otherwise continue to find host override
                    if ref.intValue != 0 { return ref.intValue }
                }
            }
            return 0
        }
        // Check both 3 and 4 finger keys across domains; also check short-form keys in com.apple.trackpad
        let threeFingerSwipe = readSwipeGesture("TrackpadThreeFingerHorizSwipeGesture")
        let threeFingerShort = readSwipeGesture("threeFingerHorizSwipeGesture")
        let fourFingerSwipe = readSwipeGesture("TrackpadFourFingerHorizSwipeGesture")
        let fourFingerShort = readSwipeGesture("fourFingerHorizSwipeGesture")
        let effectiveThree = threeFingerSwipe != 0 ? threeFingerSwipe : threeFingerShort
        let effectiveFour = fourFingerSwipe != 0 ? fourFingerSwipe : (fourFingerShort != 0 ? fourFingerShort : 2)
        let swipeConflict = (effectiveThree == 2 || effectiveFour == 2)
        items.append(SetupCheckItem(
            id: "trackpad_swipe_conflict",
            title: "Trackpad Desktop Swipe Conflict",
            category: "macOS Settings",
            isOptimal: !swipeConflict,
            statusMessage: !swipeConflict ? "No Conflict (Strip Owns Swipe)" : "macOS Switches Desktops on 3/4-Finger Swipe",
            recommendation: !swipeConflict ? "Optimal" : "In System Settings > Trackpad > More Gestures, set 'Swipe between full-screen applications' to Off so scrolling never switches desktops."
        ))
        
        return items
    }
    
    // MARK: - Health Report & Launch at Login
    
    public static func inspectSystem() -> SetupHealthReport {
        let checker = MacSetupChecker.shared
        let items = checker.runAllChecks()
        
        let conflictItem = items.first(where: { $0.id == "conflicts" })
        let conflicts = conflictItem?.isOptimal == false ? [conflictItem?.statusMessage ?? "Conflicting Apps"] : []
        
        let tilingItem = items.first(where: { $0.id == "edge_tiling" })
        let isSequoiaTiling = tilingItem?.isOptimal == false
        
        let mruItem = items.first(where: { $0.id == "mru_spaces" })
        let isMRU = mruItem?.isOptimal == false
        
        let spacesItem = items.first(where: { $0.id == "separate_spaces" })
        let separateSpaces = spacesItem?.isOptimal ?? true
        
        let launchEnabled: Bool
        if #available(macOS 13.0, *) {
            launchEnabled = SMAppService.mainApp.status == .enabled
        } else {
            launchEnabled = SettingsStore.shared.launchAtLogin
        }
        
        return SetupHealthReport(
            conflictingAppsRunning: conflicts,
            isSequoiaNativeTilingEnabled: isSequoiaTiling,
            isSpacesAutoRearranging: isMRU,
            hasSeparateSpacesPerDisplay: separateSpaces,
            launchAtLoginEnabled: launchEnabled
        )
    }
    
    public static func setLaunchAtLogin(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        }
        SettingsStore.shared.launchAtLogin = enabled
    }
    
    /// Disables conflicting macOS 3/4-finger horizontal desktop swipe gestures so trackpad swipes belong strictly to the strip.
    public func disableConflictingDesktopSwipe() {
        let domains = [
            "com.apple.AppleMultitouchTrackpad" as CFString,
            "com.apple.driver.AppleBluetoothMultitouch.trackpad" as CFString
        ]
        for domain in domains {
            CFPreferencesSetAppValue("TrackpadThreeFingerHorizSwipeGesture" as CFString, 0 as CFNumber, domain)
            CFPreferencesSetAppValue("TrackpadFourFingerHorizSwipeGesture" as CFString, 0 as CFNumber, domain)
            CFPreferencesAppSynchronize(domain)
        }
        // Also clear -currentHost host-specific overrides
        for key in ["TrackpadThreeFingerHorizSwipeGesture", "TrackpadFourFingerHorizSwipeGesture"] as [CFString] {
            CFPreferencesSetValue(key, 0 as CFNumber, "com.apple.AppleMultitouchTrackpad" as CFString, kCFPreferencesCurrentUser as CFString, kCFPreferencesCurrentHost as CFString)
            CFPreferencesSetValue(key, 0 as CFNumber, "com.apple.driver.AppleBluetoothMultitouch.trackpad" as CFString, kCFPreferencesCurrentUser as CFString, kCFPreferencesCurrentHost as CFString)
        }
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication as CFString)
        refreshChecks()
    }
}

public struct SetupHealthReport: Sendable {
    public let conflictingAppsRunning: [String]
    public let isSequoiaNativeTilingEnabled: Bool
    public let isSpacesAutoRearranging: Bool
    public let hasSeparateSpacesPerDisplay: Bool
    public let launchAtLoginEnabled: Bool
    
    public init(
        conflictingAppsRunning: [String],
        isSequoiaNativeTilingEnabled: Bool,
        isSpacesAutoRearranging: Bool,
        hasSeparateSpacesPerDisplay: Bool,
        launchAtLoginEnabled: Bool
    ) {
        self.conflictingAppsRunning = conflictingAppsRunning
        self.isSequoiaNativeTilingEnabled = isSequoiaNativeTilingEnabled
        self.isSpacesAutoRearranging = isSpacesAutoRearranging
        self.hasSeparateSpacesPerDisplay = hasSeparateSpacesPerDisplay
        self.launchAtLoginEnabled = launchAtLoginEnabled
    }
}

public typealias MacSetupInspector = MacSetupChecker
