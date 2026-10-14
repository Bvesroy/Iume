import AppKit
import IumeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[Iume] Initializing Native macOS Scrolling Window Manager...")
        
        // Initialize menu bar icon and controls
        statusBarController = StatusBarController()
        
        // Listen for runtime permission grants and bootstrap automatically
        PermissionManager.shared.onPermissionStateChanged = { [weak self] granted in
            guard let self = self else { return }
            if granted {
                print("[Iume] Accessibility permission granted! Bootstrapping window management...")
                WorkspaceManager.shared.start()
            } else {
                print("[Iume] Accessibility permission revoked. Pausing window management.")
                WorkspaceManager.shared.stop()
            }
            self.statusBarController?.rebuildMenu()
        }
        
        // Start workspace orchestration
        WorkspaceManager.shared.start()
        
        // Show Launch & Kickstart Control Panel so user can immediately kickstart window arrangement
        LaunchHUDController.shared.show()
        
        if CommandLine.arguments.contains("--kickstart") || CommandLine.arguments.contains("-k") {
            WorkspaceManager.shared.kickstart()
        }
        
        // If accessibility is missing, prompt user
        if !PermissionManager.shared.hasAccessibilityPermission {
            print("[Iume] Accessibility permission not granted yet. Prompting user...")
            PermissionManager.shared.promptForAccessibility()
            statusBarController?.openSettings()
        } else {
            print("[Iume] Accessibility permission active. Strip layout online.")
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        WorkspaceManager.shared.stop()
    }
}

// Entry point with Single-Instance Lock
let lockFilePath = "/tmp/com.iume.app.lock"
let lockFd = open(lockFilePath, O_CREAT | O_RDWR, 0o644)
if lockFd >= 0 {
    let rc = flock(lockFd, LOCK_EX | LOCK_NB)
    if rc != 0 {
        print("[Iume] Another instance is already running. Exiting.")
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Runs as menu bar accessory app
app.run()

