import Foundation
import ApplicationServices
import AppKit

/// Manages Accessibility and system permission checks for Iume.
@MainActor
public final class PermissionManager: ObservableObject {
    public static let shared = PermissionManager()
    
    @Published public private(set) var hasAccessibilityPermission: Bool = false
    public var onPermissionStateChanged: ((Bool) -> Void)?
    private var pollTimer: Timer?
    
    public init() {
        checkPermission()
        startMonitoring()
    }
    
    @discardableResult
    public func checkPermission() -> Bool {
        let trusted = AXIsProcessTrusted()
        if trusted != self.hasAccessibilityPermission {
            self.hasAccessibilityPermission = trusted
            self.onPermissionStateChanged?(trusted)
        }
        return trusted
    }
    
    public func startMonitoring() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkPermission()
            }
        }
    }
    
    public func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
    
    public func promptForAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if trusted != self.hasAccessibilityPermission {
            self.hasAccessibilityPermission = trusted
            self.onPermissionStateChanged?(trusted)
        }
    }
    
    public func openAccessibilityPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
