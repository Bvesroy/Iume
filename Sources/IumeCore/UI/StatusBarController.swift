import AppKit
import SwiftUI

/// Manages the native macOS menu bar status item and popup menu.
@MainActor
public final class StatusBarController: NSObject {
    public static private(set) var current: StatusBarController?
    
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    
    public override init() {
        super.init()
        StatusBarController.current = self
        setupStatusItem()
    }
    
    public static func openSettingsWindow() {
        current?.openSettings()
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
        
        // 🚀 Primary Kickstart Action
        let kickstartItem = NSMenuItem(
            title: "🚀 Kickstart & Arrange Windows",
            action: #selector(kickstartAction),
            keyEquivalent: " "
        )
        kickstartItem.keyEquivalentModifierMask = [.option, .shift]
        kickstartItem.target = self
        menu.addItem(kickstartItem)
        
        // ⏹️ Stop & Restore Action
        let stopItem = NSMenuItem(
            title: "⏹️ Stop & Restore Windows",
            action: #selector(stopAction),
            keyEquivalent: "s"
        )
        stopItem.keyEquivalentModifierMask = [.option, .shift]
        stopItem.target = self
        menu.addItem(stopItem)
        
        let launchPanelItem = NSMenuItem(
            title: "🎛️ Open Slide Launch Control...",
            action: #selector(openLaunchPanel),
            keyEquivalent: ""
        )
        launchPanelItem.target = self
        menu.addItem(launchPanelItem)
        
        let overviewItem = NSMenuItem(
            title: "🖼️ Panoramic Strip Overview & Preview",
            action: #selector(openOverviewAction),
            keyEquivalent: "o"
        )
        overviewItem.keyEquivalentModifierMask = [.control, .option]
        overviewItem.target = self
        menu.addItem(overviewItem)
        
        menu.addItem(NSMenuItem.separator())
        
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
        
        let sendNextItem = NSMenuItem(title: "Send to Next Display (⌃⌥N)", action: #selector(StatusBarController.sendToNextDisplayAction), keyEquivalent: "")
        sendNextItem.target = self
        quickMenu.addItem(sendNextItem)
        
        quickMenu.addItem(NSMenuItem.separator())
        
        let minimapItem = NSMenuItem(title: "Strip Minimap HUD", action: #selector(toggleMinimap), keyEquivalent: "")
        minimapItem.state = settings.showMinimapHUD ? .on : .off
        minimapItem.target = self
        quickMenu.addItem(minimapItem)
        
        let focusBorderItem = NSMenuItem(title: "Focus Border Outline", action: #selector(toggleFocusBorder), keyEquivalent: "")
        focusBorderItem.state = settings.showFocusBorder ? .on : .off
        focusBorderItem.target = self
        quickMenu.addItem(focusBorderItem)
        
        let freeformItem = NSMenuItem(title: "Remain Where Left (Freeform)", action: #selector(toggleFreeformScroll), keyEquivalent: "")
        freeformItem.state = settings.freeformScroll ? .on : .off
        freeformItem.target = self
        quickMenu.addItem(freeformItem)
        
        let wrapAroundItem = NSMenuItem(title: "Wrap-Around Focus Navigation", action: #selector(toggleWrapAroundFocus), keyEquivalent: "")
        wrapAroundItem.state = settings.wrapAroundFocus ? .on : .off
        wrapAroundItem.target = self
        quickMenu.addItem(wrapAroundItem)
        
        let fullWidthRestoreItem = NSMenuItem(title: "Full Width Toggles Back to Ratio", action: #selector(toggleFullWidthRestoresRatio), keyEquivalent: "")
        fullWidthRestoreItem.state = settings.fullWidthToggleRestoresRatio ? .on : .off
        fullWidthRestoreItem.target = self
        quickMenu.addItem(fullWidthRestoreItem)
        
        let quickSubmenuItem = NSMenuItem(title: "Strip Controls", action: nil, keyEquivalent: "")
        quickSubmenuItem.submenu = quickMenu
        menu.addItem(quickSubmenuItem)
        
        // Browser-style Tabs submenu
        let tabsMenu = NSMenu()
        
        let newTabItem = NSMenuItem(title: "New Tab in Active Group (⌃⌥⌘N)", action: #selector(newTabAction), keyEquivalent: "")
        newTabItem.target = self
        tabsMenu.addItem(newTabItem)
        
        let closeTabItem = NSMenuItem(title: "Close Active Tab (⌃⌥⇧W)", action: #selector(closeTabAction), keyEquivalent: "")
        closeTabItem.target = self
        tabsMenu.addItem(closeTabItem)
        
        tabsMenu.addItem(NSMenuItem.separator())
        
        let nextTabItem = NSMenuItem(title: "Next Tab (⌃⌥⌘])", action: #selector(nextTabAction), keyEquivalent: "")
        nextTabItem.target = self
        tabsMenu.addItem(nextTabItem)
        
        let prevTabItem = NSMenuItem(title: "Previous Tab (⌃⌥⌘[)", action: #selector(previousTabAction), keyEquivalent: "")
        prevTabItem.target = self
        tabsMenu.addItem(prevTabItem)
        
        tabsMenu.addItem(NSMenuItem.separator())
        
        let detachTabItem = NSMenuItem(title: "Detach Active Tab (⌃⌥⌘D)", action: #selector(detachTabAction), keyEquivalent: "")
        detachTabItem.target = self
        tabsMenu.addItem(detachTabItem)
        
        let ungroupTabsItem = NSMenuItem(title: "Ungroup All Tabs (⌃⌥⇧U)", action: #selector(ungroupTabsAction), keyEquivalent: "")
        ungroupTabsItem.target = self
        tabsMenu.addItem(ungroupTabsItem)
        
        let pinTabBarItem = NSMenuItem(title: "Keep Tab Bar Visible (⌃⌥⇧P)", action: #selector(toggleTabBarPinAction), keyEquivalent: "")
        pinTabBarItem.target = self
        tabsMenu.addItem(pinTabBarItem)
        
        tabsMenu.addItem(NSMenuItem.separator())
        
        let tabSameAppItem = NSMenuItem(title: "Group Same-App Windows (⌃⌥T)", action: #selector(tabSameAppAction), keyEquivalent: "")
        tabSameAppItem.target = self
        tabsMenu.addItem(tabSameAppItem)
        
        let tabAllAppsItem = NSMenuItem(title: "Group All Same-App Windows (⌃⌥⌘T)", action: #selector(tabAllAppsAction), keyEquivalent: "")
        tabAllAppsItem.target = self
        tabsMenu.addItem(tabAllAppsItem)
        
        tabsMenu.addItem(NSMenuItem.separator())
        
        let autoTabItem = NSMenuItem(title: "Auto-Tab New Same-App Windows", action: #selector(toggleAutoTabSameApp), keyEquivalent: "")
        autoTabItem.state = settings.autoTabSameAppWindows ? .on : .off
        autoTabItem.target = self
        tabsMenu.addItem(autoTabItem)
        
        let cycleTabsItem = NSMenuItem(title: "Cycle Tabs Before Columns (⌃⌥Tab)", action: #selector(toggleCycleTabsBeforeColumns), keyEquivalent: "")
        cycleTabsItem.state = settings.cycleTabsBeforeColumns ? .on : .off
        cycleTabsItem.target = self
        tabsMenu.addItem(cycleTabsItem)
        
        let tabsSubmenuItem = NSMenuItem(title: "Tabs", action: nil, keyEquivalent: "")
        tabsSubmenuItem.submenu = tabsMenu
        menu.addItem(tabsSubmenuItem)
        
        let edgeTogetherItem = NSMenuItem(title: "🧲 Apps Edge Together (Zero Gap)", action: #selector(toggleAppsEdgeTogether), keyEquivalent: "g")
        edgeTogetherItem.keyEquivalentModifierMask = [.control, .option]
        edgeTogetherItem.state = settings.appsEdgeTogether ? .on : .off
        edgeTogetherItem.target = self
        menu.addItem(edgeTogetherItem)
        
        let magneticItem = NSMenuItem(title: "🧲 Magnetic Window Snapping", action: #selector(toggleMagneticSnapping), keyEquivalent: "")
        magneticItem.state = settings.edgeSnapping ? .on : .off
        magneticItem.target = self
        menu.addItem(magneticItem)
        
        // Re-tile / align windows
        let retileItem = NSMenuItem(title: "Re-align Strip", action: #selector(realignStrip), keyEquivalent: "r")
        retileItem.keyEquivalentModifierMask = [.option, .command]
        retileItem.target = self
        menu.addItem(retileItem)
        
        // Loop Mode (Endless Wrap)
        let loopItem = NSMenuItem(title: "🎡 Loop Mode (Endless Wrap)", action: #selector(toggleLoopMode), keyEquivalent: "")
        loopItem.state = settings.loopMode ? .on : .off
        loopItem.target = self
        menu.addItem(loopItem)
        
        // [LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:StatusBarKineticSubmenu]
        // Description: Menu bar items for Kinetic, Inertial, Momentum, Smooth Scrolling, and Profiles.
        // Kinetic & Inertial Scrolling submenu
        let kineticMenu = NSMenu()
        
        let inertialItem = NSMenuItem(title: "Inertial Scrolling (Coasting)", action: #selector(toggleInertialScrolling), keyEquivalent: "")
        inertialItem.state = (settings.inertialScrolling && !settings.freezeOnRelease) ? .on : .off
        inertialItem.target = self
        kineticMenu.addItem(inertialItem)
        
        let momentumItem = NSMenuItem(title: "Momentum Scrolling (Velocity-driven)", action: #selector(toggleMomentumScrolling), keyEquivalent: "")
        momentumItem.state = settings.momentumScrolling ? .on : .off
        momentumItem.target = self
        kineticMenu.addItem(momentumItem)
        
        let smoothItem = NSMenuItem(title: "Smooth Scrolling (Gradual)", action: #selector(toggleSmoothScrolling), keyEquivalent: "")
        smoothItem.state = settings.smoothScrollingEnabled ? .on : .off
        smoothItem.target = self
        kineticMenu.addItem(smoothItem)
        
        kineticMenu.addItem(NSMenuItem.separator())
        
        // Profiles submenu
        let profileSubmenu = NSMenu()
        for profile in KineticScrollingProfile.allCases {
            let item = NSMenuItem(title: profile.displayName, action: #selector(selectKineticProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile
            if profile == settings.kineticScrollingProfile {
                item.state = .on
            }
            profileSubmenu.addItem(item)
        }
        let profileMenuItem = NSMenuItem(title: "Profile: \(settings.kineticScrollingProfile.displayName)", action: nil, keyEquivalent: "")
        profileMenuItem.submenu = profileSubmenu
        kineticMenu.addItem(profileMenuItem)
        
        let kineticSubmenuItem = NSMenuItem(title: "🌊 Kinetic & Inertial Scrolling", action: nil, keyEquivalent: "")
        kineticSubmenuItem.submenu = kineticMenu
        menu.addItem(kineticSubmenuItem)
        // [END LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:StatusBarKineticSubmenu]
        
        // HUD Instrument Style
        let hudMenu = NSMenu()
        for style in MinimapHUDStyle.allCases {
            let item = NSMenuItem(title: style.displayName, action: #selector(selectHUDStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style
            if style == settings.hudStyle {
                item.state = .on
            }
            hudMenu.addItem(item)
        }
        let hudSubmenuItem = NSMenuItem(title: "🎛️ HUD Instrument (\(settings.hudStyle.displayName))", action: nil, keyEquivalent: "")
        hudSubmenuItem.submenu = hudMenu
        menu.addItem(hudSubmenuItem)
        
        // Shortcut Cheatsheet
        let cheatsheetItem = NSMenuItem(title: "⌨️ Keyboard Shortcuts Cheatsheet...", action: #selector(openCheatsheet), keyEquivalent: "/")
        cheatsheetItem.keyEquivalentModifierMask = [.control, .option]
        cheatsheetItem.target = self
        menu.addItem(cheatsheetItem)
        
        // Mac Setup & Conflict Checker
        let setupItem = NSMenuItem(title: "🛠️ Mac Setup & Conflict Checker...", action: #selector(StatusBarController.openMacSetup), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)
        
        // Dump Diagnostics
        let dumpItem = NSMenuItem(title: "📊 Dump Window Diagnostics...", action: #selector(StatusBarController.dumpDiagnosticsAction), keyEquivalent: "")
        dumpItem.target = self
        menu.addItem(dumpItem)
        
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
    
    @objc public func stopAction() {
        LaunchHUDController.shared.performStop()
        rebuildMenu()
    }
    
    @objc private func toggleEnabled() {
        if SettingsStore.shared.isEnabled {
            stopAction()
        } else {
            kickstartAction()
        }
    }
    
    @objc private func selectLayoutMode(_ sender: NSMenuItem) {
        if let mode = sender.representedObject as? LayoutMode {
            SettingsStore.shared.layoutMode = mode
            WorkspaceManager.shared.applyLayout(animated: true)
            rebuildMenu()
        }
    }
    
    @objc public func kickstartAction() {
        LaunchHUDController.shared.performKickstart()
        rebuildMenu()
    }
    
    @objc public func openLaunchPanel() {
        LaunchHUDController.shared.show()
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
        WorkspaceManager.shared.centerFocusedColumn()
    }
    
    @objc private func openOverviewAction() {
        StripOverviewController.shared.toggle()
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
    
    @objc private func toggleAppsEdgeTogether() {
        SettingsStore.shared.appsEdgeTogether.toggle()
        rebuildMenu()
        WorkspaceManager.shared.reflowColumnsForGeometryChange()
        WorkspaceManager.shared.applyLayout(animated: true)
    }
    
    @objc private func toggleMagneticSnapping() {
        SettingsStore.shared.edgeSnapping.toggle()
        rebuildMenu()
    }
    
    @objc private func toggleFreeformScroll() {
        SettingsStore.shared.freeformScroll.toggle()
        rebuildMenu()
    }
    
    // [LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:StatusBarKineticActions]
    // Description: Menu bar handlers for toggling Inertial, Momentum, Smooth Scrolling, and switching Kinetic Profiles.
    // MARK: - Kinetic & Inertial Scrolling Actions
    
    @objc private func toggleInertialScrolling() {
        let settings = SettingsStore.shared
        let current = settings.inertialScrolling && !settings.freezeOnRelease
        settings.inertialScrolling = !current
        if !current {
            settings.freezeOnRelease = false
        }
        rebuildMenu()
    }
    
    @objc private func toggleMomentumScrolling() {
        SettingsStore.shared.momentumScrolling.toggle()
        rebuildMenu()
    }
    
    @objc private func toggleSmoothScrolling() {
        SettingsStore.shared.smoothScrollingEnabled.toggle()
        rebuildMenu()
    }
    
    @objc private func selectKineticProfile(_ sender: NSMenuItem) {
        if let profile = sender.representedObject as? KineticScrollingProfile {
            SettingsStore.shared.kineticScrollingProfile = profile
            rebuildMenu()
        }
    }
    // [END LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:StatusBarKineticActions]
    
    // MARK: - Tab Actions
    
    @objc private func newTabAction() {
        WorkspaceManager.shared.addTabToFocusedColumn()
    }
    
    @objc private func closeTabAction() {
        WorkspaceManager.shared.closeActiveTab()
    }
    
    @objc private func nextTabAction() {
        WorkspaceManager.shared.cycleTabInFocusedColumn(forward: true)
    }
    
    @objc private func previousTabAction() {
        WorkspaceManager.shared.cycleTabInFocusedColumn(forward: false)
    }
    
    @objc private func detachTabAction() {
        WorkspaceManager.shared.detachActiveTab()
    }
    
    @objc private func ungroupTabsAction() {
        WorkspaceManager.shared.ungroupFocusedTabGroup()
    }
    
    @objc private func toggleTabBarPinAction() {
        WorkspaceManager.shared.toggleActiveTabBarPin()
    }
    
    @objc private func tabSameAppAction() {
        WorkspaceManager.shared.tabSameAppWindows()
    }
    
    @objc private func tabAllAppsAction() {
        WorkspaceManager.shared.tabAllSameAppWindows()
    }
    
    @objc private func toggleAutoTabSameApp() {
        SettingsStore.shared.autoTabSameAppWindows.toggle()
        rebuildMenu()
    }
    
    @objc private func toggleWrapAroundFocus() {
        SettingsStore.shared.wrapAroundFocus.toggle()
        rebuildMenu()
    }
    
    @objc private func toggleFullWidthRestoresRatio() {
        SettingsStore.shared.fullWidthToggleRestoresRatio.toggle()
        rebuildMenu()
    }
    
    @objc private func toggleCycleTabsBeforeColumns() {
        SettingsStore.shared.cycleTabsBeforeColumns.toggle()
        rebuildMenu()
    }
    
    @objc private func toggleLoopMode() {
        SettingsStore.shared.loopMode.toggle()
        WorkspaceManager.shared.applyLayout(animated: true)
        rebuildMenu()
    }
    
    @objc private func selectHUDStyle(_ sender: NSMenuItem) {
        if let style = sender.representedObject as? MinimapHUDStyle {
            SettingsStore.shared.hudStyle = style
            rebuildMenu()
        }
    }
    
    @objc private func openCheatsheet() {
        ShortcutCheatsheetController.shared.toggle()
    }
    
    @objc public func openSettings() {
        NSApp.setActivationPolicy(.regular)
        if let window = settingsWindow {
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let hostingController = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Iume Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(CGSize(width: 700, height: 590))
        window.center()
        window.isReleasedWhenClosed = false
        self.settingsWindow = window
        
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    private var setupWindow: NSWindow?
    
    @objc private func sendToNextDisplayAction() {
        WorkspaceManager.shared.sendFocusedColumnToNextDisplay()
    }
    
    @objc public func openMacSetup() {
        NSApp.setActivationPolicy(.regular)
        if let window = setupWindow {
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let hostingController = NSHostingController(rootView: MacSetupView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Mac Setup & Conflict Checker"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(CGSize(width: 700, height: 550))
        window.center()
        window.isReleasedWhenClosed = false
        self.setupWindow = window
        
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func dumpDiagnosticsAction() {
        let dumpText = WorkspaceManager.shared.dumpAllWindows()
        let alert = NSAlert()
        alert.messageText = "Window Diagnostics Dump"
        alert.informativeText = dumpText
        alert.addButton(withTitle: "Copy to Clipboard")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(dumpText, forType: .string)
        }
    }
    
    @objc private func openPermissions() {
        PermissionManager.shared.openAccessibilityPreferences()
    }
    
    @objc private func quitApp() {
        WorkspaceManager.shared.stop()
        NSApplication.shared.terminate(nil)
    }
}
