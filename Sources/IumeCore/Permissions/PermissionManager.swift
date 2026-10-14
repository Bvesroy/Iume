import Foundation
import ApplicationServices
import AppKit

/// Manages Accessibility and system permission checks for Iume.
@MainActor
public final class PermissionManager: ObservableObject {
    public static let shared = PermissionManager()
    
    @Published public private(set) var hasAccessibilityPermission: Bool = false
    
    public init() {
        checkPermission()
    }
    
    @discardableResult
    public func checkPermission() -> Bool {
        let trusted = AXIsProcessTrusted()
        self.hasAccessibilityPermission = trusted
        return trusted
    }
    
    public func promptForAccessibility() {
        // "AXTrustedCheckOptionPrompt" is the string representation of kAXTrustedCheckOptionPrompt
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        self.hasAccessibilityPermission = trusted
    }
    
    public func openAccessibilityPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
