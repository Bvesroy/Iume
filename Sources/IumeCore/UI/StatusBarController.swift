import AppKit
import SwiftUI

/// Manages the native macOS menu bar status item and popup menu.
@MainActor
public final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    
    public override init() {
        super.init()
        setupStatusItem()
    }
    
    public func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            // Use SF Symbol for window tiling strip or fallback
            if let image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Iume Window Manager") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "◫ Iume"
            }
        }
        
        rebuildMenu()
    }
    
    public func rebuildMenu() {
        let menu = NSMenu()
        let settings = SettingsStore.shared
        let workspaceManager = WorkspaceManager.shared
        let permissions = PermissionManager.shared
        
        // Status header
        let statusTitle = settings.isEnabled ? "Iume: Active" : "Iume: Disabled"
        let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        
        // Window count info
        let winCount = workspaceManager.registry.allWindows().count
        let countItem = NSMenuItem(title: "Managed Windows: \(winCount)", action: nil, keyEquivalent: "")
        countItem.isEnabled = false
        menu.addItem(countItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Toggle Enable/Disable
        let toggleTitle = settings.isEnabled ? "Disable Management" : "Enable Management"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleEnabled), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        
        // Layout Mode submenu
        let layoutMenu = NSMenu()
        for mode in LayoutMode.allCases {
            let item = NSMenuItem(title: mode.rawValue, action: #selector(selectLayoutMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            if mode == settings.layoutMode {
                item.state = .on
            }
            layoutMenu.addItem(item)
        }
        let layoutSubmenuItem = NSMenuItem(title: "Layout Mode (\(settings.layoutMode.rawValue))", action: nil, keyEquivalent: "")
        layoutSubmenuItem.submenu = layoutMenu
        menu.addItem(layoutSubmenuItem)
        
        // Re-tile / align windows
        let retileItem = NSMenuItem(title: "Re-align Strip", action: #selector(realignStrip), keyEquivalent: "r")
        retileItem.keyEquivalentModifierMask = [.option, .command]
        retileItem.target = self
        menu.addItem(retileItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        // Permissions
        if !permissions.hasAccessibilityPermission {
            let permItem = NSMenuItem(title: "⚠️ Grant Accessibility Permission...", action: #selector(openPermissions), keyEquivalent: "")
            permItem.target = self
            menu.addItem(permItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit Iume", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        self.statusItem?.menu = menu
    }
    
    // MARK: - Actions
    
    @objc private func toggleEnabled() {
        SettingsStore.shared.isEnabled.toggle()
        rebuildMenu()
        if SettingsStore.shared.isEnabled {
            WorkspaceManager.shared.applyLayout(animated: true)
        }
    }
    
    @objc private func selectLayoutMode(_ sender: NSMenuItem) {
        if let mode = sender.representedObject as? LayoutMode {
            SettingsStore.shared.layoutMode = mode
            WorkspaceManager.shared.applyLayout(animated: true)
            rebuildMenu()
        }
    }
    
    @objc private func realignStrip() {
        WorkspaceManager.shared.applyLayout(animated: true)
    }
    
    @objc public func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let hostingController = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Iume Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        window.isReleasedWhenClosed = false
        self.settingsWindow = window
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func openPermissions() {
        PermissionManager.shared.openAccessibilityPreferences()
    }
    
    @objc private func quitApp() {
        WorkspaceManager.shared.stop()
        NSApplication.shared.terminate(nil)
    }
}
