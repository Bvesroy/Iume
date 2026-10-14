import Foundation
import AppKit

/// Tracks eligible running GUI applications on macOS.
@MainActor
public final class ApplicationDiscovery: ObservableObject {
    public struct AppInfo: Identifiable, Equatable, Sendable {
        public let id: pid_t
        public let bundleIdentifier: String
        public let localizedName: String
        public let runningApp: NSRunningApplication
        
        public init(runningApp: NSRunningApplication) {
            self.id = runningApp.processIdentifier
            self.bundleIdentifier = runningApp.bundleIdentifier ?? ""
            self.localizedName = runningApp.localizedName ?? "Unknown"
            self.runningApp = runningApp
        }
    }
    
    public var onAppLaunched: (@MainActor (NSRunningApplication) -> Void)?
    public var onAppTerminated: (@MainActor (pid_t) -> Void)?
    
    public init() {
        setupWorkspaceObservers()
    }
    
    public func discoverEligibleApplications(excludedBundleIds: [String] = []) -> [AppInfo] {
        let currentPid = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
        
        return apps.compactMap { app -> AppInfo? in
            guard app.processIdentifier != currentPid else { return nil }
            guard app.activationPolicy == .regular else { return nil }
            guard let bundleId = app.bundleIdentifier else { return nil }
            if excludedBundleIds.contains(bundleId) { return nil }
            return AppInfo(runningApp: app)
        }
    }
    
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
    }
    
    @objc private func handleAppLaunchNotification(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard app.activationPolicy == .regular else { return }
        onAppLaunched?(app)
    }
    
    @objc private func handleAppTerminateNotification(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        onAppTerminated?(app.processIdentifier)
    }
}
