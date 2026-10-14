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
        
        // Quick Strip Actions
        let quickMenu = NSMenu()
        
        let cycleItem = NSMenuItem(title: "Cycle Width (⌃⌥R)", action: #selector(cycleWidthAction), keyEquivalent: "")
        cycleItem.target = self
        quickMenu.addItem(cycleItem)
        
        let centerItem = NSMenuItem(title: "Center Column (⌃⌥C)", action: #selector(centerColumnAction), keyEquivalent: "")
        centerItem.target = self
        quickMenu.addItem(centerItem)
        
        quickMenu.addItem(NSMenuItem.separator())
        
        let minimapItem = NSMenuItem(title: "Strip Minimap HUD", action: #selector(toggleMinimap), keyEquivalent: "")
        minimapItem.state = settings.showMinimapHUD ? .on : .off
        minimapItem.target = self
        quickMenu.addItem(minimapItem)
        
        let focusBorderItem = NSMenuItem(title: "Focus Border Outline", action: #selector(toggleFocusBorder), keyEquivalent: "")
        focusBorderItem.state = settings.showFocusBorder ? .on : .off
        focusBorderItem.target = self
        quickMenu.addItem(focusBorderItem)
        
        let quickSubmenuItem = NSMenuItem(title: "Strip Controls", action: nil, keyEquivalent: "")
        quickSubmenuItem.submenu = quickMenu
        menu.addItem(quickSubmenuItem)
        
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
        WorkspaceManager.shared.discoverAndRegisterWindows()
        WorkspaceManager.shared.applyLayout(animated: true)
        rebuildMenu()
    }
    
    @objc private func cycleWidthAction() {
        let wsManager = WorkspaceManager.shared
        guard var ws = wsManager.workspaces[wsManager.activeDisplayId], let current = ws.focusedColumnIndex else { return }
        _ = wsManager.layoutEngine.cycleColumnWidth(at: current, columns: &ws.columns, visibleWidth: ws.displayGeometry.visibleFrame.width)
        wsManager.setWorkspace(ws, for: wsManager.activeDisplayId)
        wsManager.applyLayout(animated: true)
    }
    
    @objc private func centerColumnAction() {
        let wsManager = WorkspaceManager.shared
        guard let ws = wsManager.workspaces[wsManager.activeDisplayId], let current = ws.focusedColumnIndex else { return }
        let centerOffset = wsManager.layoutEngine.centerColumnOffset(at: current, columns: ws.columns, visibleWidth: ws.displayGeometry.visibleFrame.width)
        let maxOffset = max(0, wsManager.layoutEngine.totalStripWidth(columns: ws.columns) - ws.displayGeometry.visibleFrame.width)
        wsManager.scrollController.scrollTo(target: centerOffset, maxOffset: maxOffset, duration: SettingsStore.shared.animationDuration)
    }
    
    @objc private func toggleMinimap() {
        SettingsStore.shared.showMinimapHUD.toggle()
        rebuildMenu()
    }
    
    @objc private func toggleFocusBorder() {
        SettingsStore.shared.showFocusBorder.toggle()
        rebuildMenu()
        WorkspaceManager.shared.applyLayout(animated: false)
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
