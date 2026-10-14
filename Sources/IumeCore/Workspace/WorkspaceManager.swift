import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

/// Represents the workspace state for a specific physical display.
public struct DisplayWorkspace: Sendable {
    public var displayGeometry: DisplayGeometry
    public var columns: [WindowColumn]
    public var focusedColumnIndex: Int?
    public var viewportOffset: CGFloat
    
    public init(displayGeometry: DisplayGeometry, columns: [WindowColumn] = [], focusedColumnIndex: Int? = nil, viewportOffset: CGFloat = 0.0) {
        self.displayGeometry = displayGeometry
        self.columns = columns
        self.focusedColumnIndex = focusedColumnIndex
        self.viewportOffset = viewportOffset
    }
}

/// Central orchestrator coordinating displays, windows, layout calculations, and input events.
@MainActor
public final class WorkspaceManager: ObservableObject {
    public static let shared = WorkspaceManager()
    
    // Dependencies
    public let settings = SettingsStore.shared
    public let permissions = PermissionManager.shared
    public let registry = WindowRegistry()
    public let discovery = WindowDiscovery()
    public let appDiscovery = ApplicationDiscovery()
    public let observer = WindowObserver()
    public let controller = WindowController()
    public let scrollController = ScrollController()
    public let focusManager = FocusManager()
    public let displayManager = DisplayManager()
    public let shortcutManager = ShortcutManager.shared
    public let diagnostics = Diagnostics.shared
    
    // Per-display workspaces
    @Published public private(set) var workspaces: [CGDirectDisplayID: DisplayWorkspace] = [:]
    @Published public private(set) var activeDisplayId: CGDirectDisplayID = 0
    
    public func setWorkspace(_ workspace: DisplayWorkspace, for displayId: CGDirectDisplayID) {
        workspaces[displayId] = workspace
    }
    
    public func setActiveDisplayId(_ id: CGDirectDisplayID) {
        activeDisplayId = id
    }
    
    public var layoutEngine: LayoutEngine {
        LayoutEngine(
            windowGap: CGFloat(settings.windowGap),
            defaultColumnWidthRatio: CGFloat(settings.defaultColumnWidthRatio),
            defaultMinimumColumnWidth: 450.0
        )
    }
    
    public init() {
        setupBindings()
    }
    
    // MARK: - Lifecycle
    
    public func start() {
        diagnostics.log(category: "Lifecycle", message: "Starting Iume Window Manager")
        
        displayManager.refreshDisplays()
        initializeWorkspaces()
        
        guard permissions.checkPermission() else {
            diagnostics.log(level: "WARN", category: "Permissions", message: "Accessibility permission not yet granted")
            return
        }
        
        discoverAndRegisterWindows()
        shortcutManager.registerDefaultShortcuts()
        scrollController.startEventTap()
        applyLayout(animated: false)
    }
    
    public func stop() {
        diagnostics.log(category: "Lifecycle", message: "Stopping Iume Window Manager")
        scrollController.stopEventTap()
        shortcutManager.unregisterAll()
        registry.removeAll()
        workspaces.removeAll()
        FocusBorderOverlay.shared.hide()
        MinimapHUDController.shared.fadeOut()
    }
    
    // MARK: - Initial Setup
    
    private func initializeWorkspaces() {
        for display in displayManager.activeDisplays {
            if workspaces[display.id] == nil {
                workspaces[display.id] = DisplayWorkspace(displayGeometry: display)
            }
        }
        if let primary = displayManager.primaryDisplay() {
            activeDisplayId = primary.id
        }
    }
    
    public func discoverAndRegisterWindows() {
        let apps = appDiscovery.discoverEligibleApplications(excludedBundleIds: settings.excludedBundleIdentifiers)
        diagnostics.log(category: "Discovery", message: "Discovered \(apps.count) eligible applications")
        
        guard let primaryDisplay = displayManager.primaryDisplay() else { return }
        let targetDisplayId = primaryDisplay.id
        
        for app in apps {
            observer.observe(pid: app.id)
            let discovered = discovery.discoverWindows(for: app.id, bundleId: app.bundleIdentifier, appName: app.localizedName)
            
            for (managed, axElement) in discovered {
                registry.register(window: managed, axElement: axElement)
                
                if var ws = workspaces[targetDisplayId] {
                    _ = layoutEngine.insertWindow(
                        managed.id,
                        into: &ws.columns,
                        focusedColumnIndex: ws.focusedColumnIndex,
                        policy: settings.insertionPolicy,
                        visibleWidth: ws.displayGeometry.visibleFrame.width
                    )
                    workspaces[targetDisplayId] = ws
                }
            }
        }
        
        if var ws = workspaces[targetDisplayId], !ws.columns.isEmpty {
            ws.focusedColumnIndex = 0
            workspaces[targetDisplayId] = ws
            if let firstWinId = ws.columns.first?.windowIds.first {
                registry.focusedId = firstWinId
            }
        }
        
        diagnostics.updateMetrics(windows: registry.allWindows().count, columns: workspaces[targetDisplayId]?.columns.count ?? 0)
    }
    
    // MARK: - Event Bindings
    
    private func setupBindings() {
        // App lifecycle
        appDiscovery.onAppLaunched = { [weak self] app in
            guard let self = self, self.settings.isEnabled else { return }
            self.observer.observe(pid: app.processIdentifier)
        }
        
        appDiscovery.onAppTerminated = { [weak self] pid in
            guard let self = self else { return }
            self.observer.unobserve(pid: pid)
            self.handleAppTerminated(pid: pid)
        }
        
        // Window events
        observer.onWindowCreated = { [weak self] element, pid in
            guard let self = self, self.settings.isEnabled else { return }
            self.handleWindowCreated(element: element, pid: pid)
        }
        
        observer.onWindowDestroyed = { [weak self] element, pid in
            guard let self = self else { return }
            self.handleWindowDestroyed(element: element, pid: pid)
        }
        
        observer.onFocusedWindowChanged = { [weak self] element, pid in
            guard let self = self, self.settings.isEnabled else { return }
            self.handleFocusedWindowChanged(element: element)
        }
        
        // Manual external window move & resize reconciliation
        observer.onWindowMoved = { [weak self] element, pid in
            guard let self = self, self.settings.isEnabled else { return }
            self.handleWindowFrameChanged(element: element, pid: pid)
        }
        
        observer.onWindowResized = { [weak self] element, pid in
            guard let self = self, self.settings.isEnabled else { return }
            self.handleWindowFrameChanged(element: element, pid: pid)
        }
        
        // Scroll updates
        scrollController.onViewportOffsetChanged = { [weak self] newOffset in
            guard let self = self else { return }
            guard var ws = self.workspaces[self.activeDisplayId] else { return }
            ws.viewportOffset = newOffset
            self.workspaces[self.activeDisplayId] = ws
            self.applyPhysicalWindowPositions(workspace: ws)
        }
        
        // Minimap HUD activity updates
        scrollController.onScrollActivity = { [weak self] offset, maxOffset, velocity in
            guard let self = self, let ws = self.workspaces[self.activeDisplayId] else { return }
            let activeTitle = self.registry.focusedId.flatMap { self.registry.get(windowId: $0)?.title } ?? ""
            let screen = NSScreen.screens.first { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == self.activeDisplayId }
            MinimapHUDController.shared.update(
                columns: ws.columns,
                totalStripWidth: self.layoutEngine.totalStripWidth(columns: ws.columns),
                viewportOffset: offset,
                visibleWidth: ws.displayGeometry.visibleFrame.width,
                focusedIndex: ws.focusedColumnIndex,
                activeTitle: activeTitle,
                screen: screen
            )
        }
        
        // Settle & snapping requested after 2-finger scroll
        scrollController.onSettleRequested = { [weak self] projectedOffset in
            guard let self = self, let ws = self.workspaces[self.activeDisplayId], !ws.columns.isEmpty else { return }
            let totalW = self.layoutEngine.totalStripWidth(columns: ws.columns)
            let maxOffset = max(0, totalW - ws.displayGeometry.visibleFrame.width)
            let targetColIdx = self.layoutEngine.findClosestColumnIndex(
                for: projectedOffset,
                columns: ws.columns,
                visibleWidth: ws.displayGeometry.visibleFrame.width
            )
            let offsets = self.layoutEngine.columnStripOffsets(columns: ws.columns)
            let targetOffset = min(max(0, offsets[targetColIdx]), maxOffset)
            
            self.scrollController.scrollTo(target: targetOffset, maxOffset: maxOffset, duration: self.settings.animationDuration)
            
            if let targetWinId = ws.columns[targetColIdx].windowIds.first {
                self.activateWindow(targetWinId, inColumn: targetColIdx)
            }
        }
        
        // Focus manager requests
        focusManager.onFocusRequested = { [weak self] winId, colIdx in
            self?.activateWindow(winId, inColumn: colIdx)
        }
        
        // Keyboard shortcuts
        shortcutManager.onShortcutTriggered = { [weak self] action in
            guard let self = self, self.settings.isEnabled else { return }
            self.handleShortcut(action)
        }
        
        // Display changes
        displayManager.onDisplaysChanged = { [weak self] displays in
            self?.handleDisplaysChanged(displays)
        }
    }
    
    // MARK: - Action Handlers
    
    private func handleWindowCreated(element: AXUIElement, pid: pid_t) {
        guard discovery.isEligibleWindow(element) else { return }
        guard let app = NSRunningApplication(processIdentifier: pid),
              let bundleId = app.bundleIdentifier else { return }
        
        if settings.excludedBundleIdentifiers.contains(bundleId) { return }
        
        let title = discovery.copyStringAttribute(element, attribute: kAXTitleAttribute as CFString) ?? (app.localizedName ?? "Window")
        let frame = discovery.copyFrame(element) ?? CGRect(x: 100, y: 100, width: 800, height: 600)
        let rawId = UInt64(CFHash(element))
        let windowId = WindowId(pid: pid, rawId: rawId)
        
        let managed = ManagedWindow(
            id: windowId,
            pid: pid,
            bundleIdentifier: bundleId,
            appName: app.localizedName ?? "App",
            title: title,
            frame: frame
        )
        
        registry.register(window: managed, axElement: element)
        
        guard var ws = workspaces[activeDisplayId] else { return }
        let newColIdx = layoutEngine.insertWindow(
            windowId,
            into: &ws.columns,
            focusedColumnIndex: ws.focusedColumnIndex,
            policy: settings.insertionPolicy,
            visibleWidth: ws.displayGeometry.visibleFrame.width
        )
        ws.focusedColumnIndex = newColIdx
        workspaces[activeDisplayId] = ws
        registry.focusedId = windowId
        
        applyLayout(animated: true)
        diagnostics.log(category: "Window", message: "Created & added window: \(title)")
    }
    
    private func handleWindowDestroyed(element: AXUIElement, pid: pid_t) {
        guard let winId = registry.findWindowId(matchingAXElement: element) else { return }
        registry.unregister(windowId: winId)
        
        guard var ws = workspaces[activeDisplayId] else { return }
        ws.focusedColumnIndex = layoutEngine.removeWindow(winId, from: &ws.columns, currentFocusedIndex: ws.focusedColumnIndex)
        workspaces[activeDisplayId] = ws
        
        applyLayout(animated: true)
        diagnostics.log(category: "Window", message: "Destroyed window: \(winId)")
    }
    
    private func handleAppTerminated(pid: pid_t) {
        let wins = registry.windows(forPid: pid)
        guard !wins.isEmpty else { return }
        
        guard var ws = workspaces[activeDisplayId] else { return }
        for w in wins {
            registry.unregister(windowId: w.id)
            ws.focusedColumnIndex = layoutEngine.removeWindow(w.id, from: &ws.columns, currentFocusedIndex: ws.focusedColumnIndex)
        }
        workspaces[activeDisplayId] = ws
        applyLayout(animated: true)
        diagnostics.log(category: "App", message: "Terminated app PID \(pid)")
    }
    
    private func handleFocusedWindowChanged(element: AXUIElement) {
        guard let winId = registry.findWindowId(matchingAXElement: element) else { return }
        guard var ws = workspaces[activeDisplayId] else { return }
        
        if let colIdx = ws.columns.firstIndex(where: { $0.windowIds.contains(winId) }) {
            ws.focusedColumnIndex = colIdx
            registry.focusedId = winId
            workspaces[activeDisplayId] = ws
            applyLayout(animated: true)
        }
    }
    
    private func handleShortcut(_ action: ShortcutAction) {
        guard var ws = workspaces[activeDisplayId] else { return }
        
        switch action {
        case .focusLeft:
            focusManager.focusLeft(columns: ws.columns, currentColumnIndex: ws.focusedColumnIndex)
        case .focusRight:
            focusManager.focusRight(columns: ws.columns, currentColumnIndex: ws.focusedColumnIndex)
        case .focusUp:
            focusManager.focusUp(columns: ws.columns, currentColumnIndex: ws.focusedColumnIndex, currentWindowId: registry.focusedId)
        case .focusDown:
            focusManager.focusDown(columns: ws.columns, currentColumnIndex: ws.focusedColumnIndex, currentWindowId: registry.focusedId)
        case .moveColumnLeft:
            if let current = ws.focusedColumnIndex {
                ws.focusedColumnIndex = layoutEngine.moveColumn(at: current, direction: -1, columns: &ws.columns)
                workspaces[activeDisplayId] = ws
                applyLayout(animated: true)
            }
        case .moveColumnRight:
            if let current = ws.focusedColumnIndex {
                ws.focusedColumnIndex = layoutEngine.moveColumn(at: current, direction: 1, columns: &ws.columns)
                workspaces[activeDisplayId] = ws
                applyLayout(animated: true)
            }
        case .toggleZoom:
            if let focusedId = registry.focusedId, let ax = registry.getAXElement(windowId: focusedId) {
                controller.zoom(element: ax)
            }
        case .closeWindow:
            if let focusedId = registry.focusedId, let ax = registry.getAXElement(windowId: focusedId) {
                controller.close(element: ax)
            }
        case .cycleNext:
            focusManager.cycleWindows(columns: ws.columns, currentWindowId: registry.focusedId, forward: true)
        case .cyclePrev:
            focusManager.cycleWindows(columns: ws.columns, currentWindowId: registry.focusedId, forward: false)
        case .scrollLeft:
            let maxOffset = max(0, layoutEngine.totalStripWidth(columns: ws.columns) - ws.displayGeometry.visibleFrame.width)
            scrollController.scrollBy(deltaX: -160, maxOffset: maxOffset)
        case .scrollRight:
            let maxOffset = max(0, layoutEngine.totalStripWidth(columns: ws.columns) - ws.displayGeometry.visibleFrame.width)
            scrollController.scrollBy(deltaX: 160, maxOffset: maxOffset)
        case .cycleWidth:
            if let current = ws.focusedColumnIndex {
                _ = layoutEngine.cycleColumnWidth(at: current, columns: &ws.columns, visibleWidth: ws.displayGeometry.visibleFrame.width)
                workspaces[activeDisplayId] = ws
                applyLayout(animated: true)
            }
        case .centerColumn:
            if let current = ws.focusedColumnIndex {
                let centerOffset = layoutEngine.centerColumnOffset(at: current, columns: ws.columns, visibleWidth: ws.displayGeometry.visibleFrame.width)
                let maxOffset = max(0, layoutEngine.totalStripWidth(columns: ws.columns) - ws.displayGeometry.visibleFrame.width)
                scrollController.scrollTo(target: centerOffset, maxOffset: maxOffset, duration: settings.animationDuration)
            }
        case .fullWidth:
            if let current = ws.focusedColumnIndex {
                layoutEngine.maximizeColumn(at: current, columns: &ws.columns, visibleWidth: ws.displayGeometry.visibleFrame.width)
                workspaces[activeDisplayId] = ws
                applyLayout(animated: true)
            }
        }
    }
    
    public func activateWindow(_ winId: WindowId, inColumn colIdx: Int) {
        guard var ws = workspaces[activeDisplayId] else { return }
        ws.focusedColumnIndex = colIdx
        registry.focusedId = winId
        workspaces[activeDisplayId] = ws
        
        if let ax = registry.getAXElement(windowId: winId) {
            controller.focus(element: ax, pid: winId.pid)
        }
        applyLayout(animated: true)
    }
    
    // MARK: - Layout Application
    
    public func applyLayout(animated: Bool = true) {
        guard let ws = workspaces[activeDisplayId] else { return }
        
        let computation = layoutEngine.computeLayout(
            columns: ws.columns,
            windows: registry.windowMap(),
            focusedColumnIndex: ws.focusedColumnIndex,
            visibleFrame: ws.displayGeometry.visibleFrame,
            viewportOffset: ws.viewportOffset,
            layoutMode: settings.layoutMode
        )
        
        let maxOffset = max(0, computation.totalStripWidth - ws.displayGeometry.visibleFrame.width)
        scrollController.maxOffset = maxOffset
        
        // Update Minimap HUD
        let activeTitle = registry.focusedId.flatMap { registry.get(windowId: $0)?.title } ?? ""
        let screen = NSScreen.screens.first { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == activeDisplayId }
        MinimapHUDController.shared.update(
            columns: ws.columns,
            totalStripWidth: computation.totalStripWidth,
            viewportOffset: ws.viewportOffset,
            visibleWidth: ws.displayGeometry.visibleFrame.width,
            focusedIndex: ws.focusedColumnIndex,
            activeTitle: activeTitle,
            screen: screen
        )
        
        if animated && abs(computation.targetViewportOffset - ws.viewportOffset) > 1.0 {
            scrollController.scrollTo(
                target: computation.targetViewportOffset,
                maxOffset: maxOffset,
                duration: settings.animationDuration
            )
        } else {
            scrollController.setOffset(computation.targetViewportOffset, maxOffset: maxOffset)
            applyPhysicalWindowPositions(workspace: ws)
        }
    }
    
    private func applyPhysicalWindowPositions(workspace: DisplayWorkspace) {
        observer.isPerformingProgrammaticUpdate = true
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.observer.isPerformingProgrammaticUpdate = false
            }
        }
        
        let computation = layoutEngine.computeLayout(
            columns: workspace.columns,
            windows: registry.windowMap(),
            focusedColumnIndex: workspace.focusedColumnIndex,
            visibleFrame: workspace.displayGeometry.visibleFrame,
            viewportOffset: workspace.viewportOffset,
            layoutMode: settings.layoutMode
        )
        
        var focusedWindowFrame: CGRect? = nil
        for (winId, targetFrame) in computation.targetFrames {
            if let ax = registry.getAXElement(windowId: winId) {
                observer.recordExpectedFrame(targetFrame, for: winId)
                controller.setFrame(element: ax, frame: targetFrame, windowId: winId)
                registry.update(windowId: winId) { $0.frame = targetFrame }
                
                if winId == registry.focusedId {
                    focusedWindowFrame = targetFrame
                }
            }
        }
        
        // Update Focus Border Overlay
        FocusBorderOverlay.shared.updateFrame(focusedWindowFrame, visibleFrame: workspace.displayGeometry.visibleFrame)
    }
    
    // MARK: - Frame Change & Scroll Handlers
    
    private func handleWindowFrameChanged(element: AXUIElement, pid: pid_t) {
        guard let winId = registry.findWindowId(matchingAXElement: element),
              let observedFrame = discovery.copyFrame(element) else { return }
        
        // Guard against programmatic echoes
        guard !observer.isSelfOriginatedFrameChange(windowId: winId, observedFrame: observedFrame) else {
            return
        }
        
        reconcileExternalFrameChange(windowId: winId, newFrame: observedFrame)
    }
    
    public func reconcileExternalFrameChange(windowId: WindowId, newFrame: CGRect) {
        guard let win = registry.get(windowId: windowId) else { return }
        guard var ws = workspaces[activeDisplayId] else { return }
        
        let widthChanged = abs(newFrame.width - win.frame.width) > 4.0
        
        registry.update(windowId: windowId) {
            $0.frame = newFrame
            if widthChanged {
                $0.preferredWidth = newFrame.width
            }
        }
        
        if widthChanged, let colIdx = ws.columns.firstIndex(where: { $0.windowIds.contains(windowId) }) {
            ws.columns[colIdx].width = newFrame.width
            workspaces[activeDisplayId] = ws
        }
        
        applyLayout(animated: false)
        diagnostics.log(category: "Reconcile", message: "Reconciled manual frame change for \(windowId)")
    }
    
    public func applyScrollDelta(_ delta: CGFloat) {
        guard let ws = workspaces[activeDisplayId] else { return }
        let totalWidth = layoutEngine.totalStripWidth(columns: ws.columns)
        let maxOffset = max(0, totalWidth - ws.displayGeometry.visibleFrame.width)
        let multiplier: CGFloat = settings.trackpadNaturalScroll ? -1.0 : 1.0
        let effectiveDelta = delta * multiplier
        scrollController.scrollBy(deltaX: effectiveDelta, maxOffset: maxOffset)
    }
    
    // MARK: - Multi-Monitor Handling
    
    private func handleDisplaysChanged(_ displays: [DisplayGeometry]) {
        guard !displays.isEmpty else { return }
        let currentIds = Set(displays.map { $0.id })
        
        // Recover disconnected monitors: migrate windows to primary
        guard let primary = displays.first(where: { $0.isPrimary }) ?? displays.first else { return }
        
        for (dispId, ws) in workspaces {
            if !currentIds.contains(dispId) {
                diagnostics.log(level: "WARN", category: "Display", message: "Display \(dispId) disconnected. Migrating \(ws.columns.count) columns to primary.")
                if var primaryWs = workspaces[primary.id] {
                    primaryWs.columns.append(contentsOf: ws.columns)
                    workspaces[primary.id] = primaryWs
                }
                workspaces.removeValue(forKey: dispId)
            }
        }
        
        // Update geometry of existing displays
        for display in displays {
            if var existing = workspaces[display.id] {
                existing.displayGeometry = display
                workspaces[display.id] = existing
            } else {
                workspaces[display.id] = DisplayWorkspace(displayGeometry: display)
            }
        }
        
        activeDisplayId = primary.id
        applyLayout(animated: false)
    }
}
