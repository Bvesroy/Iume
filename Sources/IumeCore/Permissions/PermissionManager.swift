@preconcurrency import Foundation
import ApplicationServices
import AppKit
import ObjectiveC

/// Manages Accessibility and system permission checks for Iume.
/// Single owner for `isTrusted` — all consumers observe `@Published hasAccessibilityPermission` via Combine
/// or `DistributedNotificationCenter` watchdog, not competing closures.
/// Implements single-shot prompts, silent polling that stops once trusted, application directory validation,
/// and stale TCC cdhash entry repair (only via Mac Setup button) to eliminate permission loops.
@MainActor
public final class PermissionManager: ObservableObject {
    public static let shared = PermissionManager()
    
    @Published public private(set) var hasAccessibilityPermission: Bool = false
    @Published public private(set) var isInstalledInApplications: Bool = false
    
    /// Prefer observing `$hasAccessibilityPermission` via Combine.
    /// Kept for backward compatibility — single-owner model: only one subscriber should set this.
    public var onPermissionStateChanged: ((Bool) -> Void)?
    public var onPermissionGranted: (() -> Void)?
    
    nonisolated(unsafe) private var pollTimer: Timer?
    private var hasPromptedThisSession: Bool = false
    private let promptedKey = "com.iume.hasPromptedAccessibilitySystemDialog"
    nonisolated(unsafe) private var axWatchdogObserver: NSObjectProtocol?
    
    public init() {
        checkApplicationLocation()
        checkPermission()
        startMonitoring()
        startAXWatchdog()
    }
    
    deinit {
        if let obs = axWatchdogObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
        }
        pollTimer?.invalidate()
    }
    
    /// Whether the bundle is running from AppTranslocation (quarantine path randomisation).
    public var isTranslocated: Bool {
        Bundle.main.bundlePath.contains("AppTranslocation")
    }
    
    public func checkApplicationLocation() {
        let path = Bundle.main.bundlePath
        isInstalledInApplications = path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
    
    @discardableResult
    public func checkPermission() -> Bool {
        // Crucial: Use AXIsProcessTrusted() without options so macOS never spawns modal dialogs during polling
        let trusted = AXIsProcessTrusted()
        Diagnostics.shared.log(
            level: trusted ? "INFO" : "WARN",
            category: "Permissions",
            message: "Accessibility check trusted=\(trusted) bundle=\(Bundle.main.bundlePath) installed=\(isInstalledInApplications)"
        )
        if trusted != self.hasAccessibilityPermission {
            self.hasAccessibilityPermission = trusted
            self.onPermissionStateChanged?(trusted)
            if trusted {
                self.onPermissionGranted?()
                // Stop polling once trusted — per §13.5 single-prompt + stop-on-trusted
                stopMonitoring()
            }
        } else if trusted {
            // Already trusted — ensure poll stops
            stopMonitoring()
        }
        return trusted
    }
    
    public func startMonitoring() {
        // Do not restart if already trusted
        if hasAccessibilityPermission { return }
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
    
    /// Watches `com.apple.accessibility.api` so engine can stop/start without polling or re-prompting.
    private func startAXWatchdog() {
        axWatchdogObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Debounce 0.5s per spec §13.5
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.checkPermission()
            }
        }
    }
    
    /// Requests the macOS system Accessibility prompt AT MOST ONCE per session.
    /// Never call this inside a timer or automatic loop.
    public func requestPermissionExplicitly() {
        guard !AXIsProcessTrusted() else {
            hasAccessibilityPermission = true
            Diagnostics.shared.log(category: "Permissions", message: "Accessibility permission already trusted")
            return
        }
        
        let hasPromptedEver = UserDefaults.standard.bool(forKey: promptedKey)
        if !hasPromptedEver && !hasPromptedThisSession {
            hasPromptedThisSession = true
            UserDefaults.standard.set(true, forKey: promptedKey)
            let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            Diagnostics.shared.log(level: "WARN", category: "Permissions", message: "Requested Accessibility permission; enable Iume in System Settings > Privacy & Security > Accessibility")
        } else {
            Diagnostics.shared.log(level: "WARN", category: "Permissions", message: "Accessibility permission still missing; opening System Settings because the one-shot prompt was already used")
            openAccessibilityPreferences()
        }
    }
    
    public func promptForAccessibility() {
        requestPermissionExplicitly()
    }
    
    /// Clears stale cdhash entries in TCC database when switch is ON in System Settings
    /// but AXIsProcessTrusted() still returns false after a binary rebuild.
    /// ONLY call from Mac Setup "Repair" button — never automatically.
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
