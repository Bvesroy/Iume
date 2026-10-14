import AppKit
import IumeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[Iume] Initializing Native macOS Scrolling Window Manager...")
        
        // Initialize menu bar icon and controls
        statusBarController = StatusBarController()
        
        // Start workspace orchestration
        WorkspaceManager.shared.start()
        
        // If accessibility is missing, prompt user
        if !PermissionManager.shared.hasAccessibilityPermission {
            print("[Iume] Accessibility permission not granted yet. Prompting user...")
            PermissionManager.shared.promptForAccessibility()
        } else {
            print("[Iume] Accessibility permission active. Strip layout online.")
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        WorkspaceManager.shared.stop()
    }
}

// Entry point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Runs as menu bar accessory app
app.run()
