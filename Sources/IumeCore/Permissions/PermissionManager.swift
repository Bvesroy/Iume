import Foundation
import ApplicationServices
import AppKit

/// Manages Accessibility and system permission checks for Iume.
/// Implements single-shot prompts, silent polling, application directory validation,
/// and stale TCC cdhash entry repair to eliminate permission loops across rebuilds.
@MainActor
public final class PermissionManager: ObservableObject {
    public static let shared = PermissionManager()
    
    @Published public private(set) var hasAccessibilityPermission: Bool = false
    @Published public private(set) var isInstalledInApplications: Bool = false
    
    public var onPermissionStateChanged: ((Bool) -> Void)?
    public var onPermissionGranted: (() -> Void)?
    
    private var pollTimer: Timer?
    private var hasPromptedThisSession: Bool = false
    private let promptedKey = "com.iume.hasPromptedAccessibilitySystemDialog"
    
    public init() {
        checkApplicationLocation()
        checkPermission()
        startMonitoring()
    }
    
    public func checkApplicationLocation() {
        let path = Bundle.main.bundlePath
        isInstalledInApplications = path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
    
    @discardableResult
    public func checkPermission() -> Bool {
        // Crucial: Use AXIsProcessTrusted() without options so macOS never spawns modal dialogs during polling
        let trusted = AXIsProcessTrusted()
        if trusted != self.hasAccessibilityPermission {
            self.hasAccessibilityPermission = trusted
            self.onPermissionStateChanged?(trusted)
            if trusted {
                self.onPermissionGranted?()
            }
        }
        return trusted
    }
    
    public func startMonitoring() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkPermission()
            }
        }
    }
    
    public func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
    
    /// Requests the macOS system Accessibility prompt AT MOST ONCE per session.
    /// Never call this inside a timer or automatic loop.
    public func requestPermissionExplicitly() {
        guard !AXIsProcessTrusted() else {
            hasAccessibilityPermission = true
            return
        }
        
        let hasPromptedEver = UserDefaults.standard.bool(forKey: promptedKey)
        if !hasPromptedEver && !hasPromptedThisSession {
            hasPromptedThisSession = true
            UserDefaults.standard.set(true, forKey: promptedKey)
            let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        } else {
            openAccessibilityPreferences()
        }
    }
    
    public func promptForAccessibility() {
        requestPermissionExplicitly()
    }
    
    /// Clears stale cdhash entries in TCC database when switch is ON in System Settings
    /// but AXIsProcessTrusted() still returns false after a binary rebuild.
    public func repairStaleTCCEntry() {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.iume.Iume"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleId]
        try? process.run()
        process.waitUntilExit()
        
        resetPromptHistory()
        hasPromptedThisSession = false
        requestPermissionExplicitly()
    }
    
    public func resetPromptHistory() {
        UserDefaults.standard.removeObject(forKey: promptedKey)
    }
    
    public func openAccessibilityPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Backward compatibility and architecture naming alias
public typealias AccessibilityManager = PermissionManager
