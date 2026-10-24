import Foundation
import AppKit

/// Tracks eligible running GUI applications on macOS.
@MainActor
public final class ApplicationDiscovery: ObservableObject {
    public struct AppInfo: Identifiable, Equatable, Sendable {
        public let id: pid_t
        public let bundleIdentifier: String
        public let localizedName: String
        public let runningApp: NSRunningApplication?
        
        public init(runningApp: NSRunningApplication) {
            self.id = runningApp.processIdentifier
            self.bundleIdentifier = runningApp.bundleIdentifier ?? ""
            self.localizedName = runningApp.localizedName ?? "Unknown"
            self.runningApp = runningApp
        }
        
        public init(id: pid_t, bundleIdentifier: String, localizedName: String, runningApp: NSRunningApplication? = nil) {
            self.id = id
            self.bundleIdentifier = bundleIdentifier
            self.localizedName = localizedName
            self.runningApp = runningApp
        }
    }
    
    public var onAppLaunched: (@MainActor (NSRunningApplication) -> Void)?
    public var onAppTerminated: (@MainActor (pid_t) -> Void)?
    public var onAppActivated: (@MainActor (NSRunningApplication) -> Void)?
    
    public init() {
        setupWorkspaceObservers()
    }
    
    public func discoverEligibleApplications(excludedBundleIds: [String] = []) -> [AppInfo] {
        let currentPid = ProcessInfo.processInfo.processIdentifier
        var result: [AppInfo] = []
        var seenPids = Set<pid_t>()
        seenPids.insert(currentPid)
        
        // 1. Regular running GUI applications from NSWorkspace
        let apps = NSWorkspace.shared.runningApplications
        for app in apps {
            let pid = app.processIdentifier
            guard !seenPids.contains(pid) else { continue }
            
            let bundleId = app.bundleIdentifier ?? ""
            if !bundleId.isEmpty && excludedBundleIds.contains(bundleId) { continue }
            
            if app.activationPolicy == .regular {
                seenPids.insert(pid)
                result.append(AppInfo(runningApp: app))
            }
        }
        
        // 2. Quartz WindowServer discovery for on-screen layer-0 windows
        // Catches terminals, Electron apps, developer tools, accessory apps with windows, etc.
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        if let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            for winInfo in windowInfoList {
                guard let pid = winInfo[kCGWindowOwnerPID as String] as? Int32,
                      !seenPids.contains(pid),
                      let layer = winInfo[kCGWindowLayer as String] as? Int,
                      layer == 0,
                      let boundsDict = winInfo[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDict),
                      bounds.width >= 150 && bounds.height >= 100 else {
                    continue
                }
                
                let ownerName = winInfo[kCGWindowOwnerName as String] as? String ?? "App \(pid)"
                let runningApp = NSRunningApplication(processIdentifier: pid)
                let bundleId = runningApp?.bundleIdentifier ?? "app.\(pid)"
                
                if excludedBundleIds.contains(bundleId) { continue }
                
                seenPids.insert(pid)
                if let app = runningApp {
                    result.append(AppInfo(runningApp: app))
                } else {
                    result.append(AppInfo(id: pid, bundleIdentifier: bundleId, localizedName: ownerName, runningApp: nil))
                }
            }
        }
        
        return result
    }
    
    public var onSystemReconcileNeeded: (@MainActor () -> Void)?
    
    private func setupWorkspaceObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleAppLaunchNotification(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleAppTerminateNotification(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleAppActivateNotification(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleSystemEventNotification(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleSystemEventNotification(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemEventNotification(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }
    
    @objc private func handleAppLaunchNotification(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        onAppLaunched?(app)
    }
    
    @objc private func handleAppActivateNotification(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        onAppActivated?(app)
    }
    
    @objc private func handleAppTerminateNotification(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        onAppTerminated?(app.processIdentifier)
    }
    
    @objc private func handleSystemEventNotification(_ notification: Notification) {
        onSystemReconcileNeeded?()
    }
}
