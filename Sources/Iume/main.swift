import AppKit
import IumeCore
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var cancellables = Set<AnyCancellable>()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[Iume] Initializing Native macOS Scrolling Window Manager...")

        // Translocation / /Applications guard — §13.5
        let bundlePath = Bundle.main.bundlePath
        let isTranslocated = bundlePath.contains("AppTranslocation")
        let isInApplications = bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
        if isTranslocated || !isInApplications {
            print("[Iume] Warning: Running from \(bundlePath) — move Iume.app to /Applications to preserve Accessibility grants.")
        }
        
        // Initialize menu bar icon and controls
        statusBarController = StatusBarController()

        // Single-owner permission observation via Combine on PermissionManager.$hasAccessibilityPermission.
        // No competing onPermissionStateChanged closure here — WorkspaceManager is the sole owner.
        // This subscription only rebuilds the menu and logs; engine start/stop is owned by WorkspaceManager.
        PermissionManager.shared.$hasAccessibilityPermission
            .receive(on: RunLoop.main)
            .sink { [weak self] granted in
                if granted {
                    print("[Iume] Accessibility permission granted (observed in AppDelegate).")
                } else {
                    print("[Iume] Accessibility permission not granted.")
                }
                self?.statusBarController?.rebuildMenu()
            }
            .store(in: &cancellables)
        
        // Bootstrap engine if already trusted (PermissionManager initial check); otherwise wait for grant.
        // WorkspaceManager.start() guards internally on PermissionManager.
        if PermissionManager.shared.hasAccessibilityPermission {
            WorkspaceManager.shared.start()
            print("[Iume] Accessibility permission active. Strip layout online.")
        } else {
            print("[Iume] Accessibility permission not granted yet. Show onboarding card — not auto-prompting.")
            // Do NOT call promptForAccessibility() or openSettings() unconditionally.
            // User must click the onboarding card button to trigger the single system prompt (§13.5).
        }
        
        // Show Launch & Kickstart Control Panel
        LaunchHUDController.shared.show()
        
        if CommandLine.arguments.contains("--kickstart") || CommandLine.arguments.contains("-k") {
            WorkspaceManager.shared.kickstart()
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Teardown must not turn an enabled installation into a persisted manual stop.
        // User-triggered Stop still records isEnabled=false; process termination only
        // releases runtime resources and preserves the user's management choice.
        WorkspaceManager.shared.stop(preserveEnabledState: true)
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

// Signal handling via GCD signal sources (async-signal-safe).
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    WorkspaceManager.shared.stop()
    exit(0)
}
sigintSource.resume()
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler {
    WorkspaceManager.shared.stop()
    exit(0)
}
sigtermSource.resume()

app.run()
