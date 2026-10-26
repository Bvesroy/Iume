import Foundation
import CoreGraphics
import ApplicationServices
import AppKit
import Combine

/// Represents the workspace state for a specific physical display.
public struct DisplayWorkspace: Sendable {
    public var displayGeometry: DisplayGeometry
    public var columns: [WindowColumn]
    public var focusedColumnIndex: Int?
    public var viewportOffset: CGFloat
    public var manualFrames: [WindowId: CGRect]
    public var customBoxFrames: [WindowId: CGRect]
    
    public init(
        displayGeometry: DisplayGeometry,
        columns: [WindowColumn] = [],
        focusedColumnIndex: Int? = nil,
        viewportOffset: CGFloat = 0.0,
        manualFrames: [WindowId: CGRect] = [:],
        customBoxFrames: [WindowId: CGRect] = [:]
    ) {
        self.displayGeometry = displayGeometry
        self.columns = columns
        self.focusedColumnIndex = focusedColumnIndex
        self.viewportOffset = viewportOffset
        self.manualFrames = manualFrames
        self.customBoxFrames = customBoxFrames
    }
}

/// Central orchestrator coordinating displays, windows, layout calculations, and input events.
@MainActor
public final class WorkspaceManager: ObservableObject, MouseStateKeeperDelegate {
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
    public let spaceManager = SpaceManager.shared
    public let persistence = LayoutPersistenceManager.shared
    
    // Per-display and per-space workspaces
    private var lastFocusedWindowId: WindowId?
    private var isProgrammaticallyFocusing: Bool = false
    private var programmaticFocusResetTimer: Timer?
    private var suppressedFocusNotificationWindowId: WindowId?
    private var suppressedFocusExpiration: TimeInterval = 0
    @Published public internal(set) var spaceWorkspaces: [WorkspaceKey: DisplayWorkspace] = [:]
    @Published public internal(set) var workspaces: [CGDirectDisplayID: DisplayWorkspace] = [:]
    @Published public private(set) var activeDisplayId: CGDirectDisplayID = 0 {
        didSet {
            guard oldValue != activeDisplayId else { return }
            syncDisplayLinkWithActiveDisplay()
        }
    }
    @Published public private(set) var activeSpaceId: UInt64 = 1
    @Published public private(set) var activeWorkspaceIndex: Int = 1
    
    // High-frequency viewport offset tracking (decoupled from @Published workspaces to eliminate 60-120Hz Combine objectWillChange churn)
    private var activeViewportOffsets: [CGDirectDisplayID: CGFloat] = [:]
    private var lastMinimapUpdateTime: TimeInterval = 0
    private var lastViewportTraceTime: TimeInterval = 0
    private var pendingSettleWorkItem: DispatchWorkItem?

    public func activeViewportOffset(for displayId: CGDirectDisplayID) -> CGFloat {
        if displayId == activeDisplayId {
            return scrollController.currentOffset
        }
        return activeViewportOffsets[displayId] ?? workspaces[displayId]?.viewportOffset ?? 0.0
    }

    private func scheduleSettlePass() {
        pendingSettleWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingSettleWorkItem = nil
            self.performSettlePass()
        }
        pendingSettleWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func performSettlePass() {
        guard var ws = self.workspaces[self.activeDisplayId] else { return }
        let currentOffset = self.scrollController.currentOffset
        ws.viewportOffset = currentOffset
        self.activeViewportOffsets[self.activeDisplayId] = currentOffset
        // Authoritative commit to @Published workspaces so observers get final rest geometry
        self.workspaces[self.activeDisplayId] = ws
        
        self.applyPhysicalWindowPositions(workspace: ws)
        
        if let targetWinId = self.registry.focusedId,
           targetWinId != self.lastFocusedWindowId {
            self.suppressFocusNotification(for: targetWinId, duration: 0.60)
            self.focusWindowProgrammatically(targetWinId)
        }
    }
    
    public var pendingTabAdditionColumnId: UUID?
    public var pendingTabAdditionPID: pid_t?
    public var pendingTabAdditionBundleId: String?
    
    public func suppressFocusNotification(for windowId: WindowId, duration: TimeInterval = 0.60) {
        suppressedFocusNotificationWindowId = windowId
        suppressedFocusExpiration = ProcessInfo.processInfo.systemUptime + duration
    }
    
    public func focusWindowProgrammatically(_ windowId: WindowId) {
        guard let ax = registry.getAXElement(windowId: windowId) else { return }
        lastFocusedWindowId = windowId
        registry.focusedId = windowId
        suppressFocusNotification(for: windowId, duration: 0.60)
        isProgrammaticallyFocusing = true
        observer.isPerformingProgrammaticUpdate = true
        controller.focus(element: ax, pid: windowId.pid, cgWindowID: UInt32(windowId.rawId))
        programmaticFocusResetTimer?.invalidate()
        programmaticFocusResetTimer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isProgrammaticallyFocusing = false
                self?.observer.isPerformingProgrammaticUpdate = false
            }
        }
    }
    
    public var currentWorkspaceKey: WorkspaceKey {
        WorkspaceKey(displayId: activeDisplayId, spaceId: activeSpaceId, workspaceIndex: activeWorkspaceIndex)
    }
    
    public func setWorkspace(_ workspace: DisplayWorkspace, for displayId: CGDirectDisplayID, spaceId: UInt64? = nil, workspaceIndex: Int? = nil) {
        let sId = spaceId ?? activeSpaceId
        let wIdx = workspaceIndex ?? activeWorkspaceIndex
        let key = WorkspaceKey(displayId: displayId, spaceId: sId, workspaceIndex: wIdx)
        spaceWorkspaces[key] = workspace
        if sId == activeSpaceId && wIdx == activeWorkspaceIndex {
            activeViewportOffsets[displayId] = workspace.viewportOffset
            workspaces[displayId] = workspace
        }
    }
    
    public func setActiveDisplayId(_ id: CGDirectDisplayID) {
        activeDisplayId = id
    }

    /// Keep the display link on the panel that actually owns the viewport. Without
    /// this it stays attached to the screen that was active at launch, so pacing
    /// silently degrades (or dies) after moving the workspace to another display.
    private func syncDisplayLinkWithActiveDisplay(force: Bool = false) {
        guard let screen = cachedScreen(for: activeDisplayId) ?? NSScreen.main else { return }
        scrollController.attachDisplayLink(to: screen, force: force)
    }
    
    private var screenCache: [CGDirectDisplayID: NSScreen] = [:]
    
    public func cachedScreen(for displayId: CGDirectDisplayID) -> NSScreen? {
        if let s = screenCache[displayId] { return s }
        let screen = NSScreen.screens.first { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == displayId }
        if let s = screen { screenCache[displayId] = s }
        return screen
    }
    
    public func clearScreenCache() {
        screenCache.removeAll()
    }
    
    public func setActiveSpaceId(_ id: UInt64) {
        activeSpaceId = id
    }
    
    public var layoutEngine: LayoutEngine {
        let gap = settings.appsEdgeTogether ? 0.0 : CGFloat(settings.windowGap)
        return LayoutEngine(
            windowGap: gap,
            edgeMargins: settings.edgeMargins,
            defaultColumnWidthRatio: CGFloat(settings.defaultColumnWidthRatio),
            defaultMinimumColumnWidth: 380.0,
            offScreenPeekSliverWidth: 12.0,
            centerMode: settings.centerMode
        )
    }
    
    private var parkedWindowIds: Set<WindowId> = []
    private var cancellables = Set<AnyCancellable>()
    
    public var magneticEngine = MagneticWindowEngine()
    public let mouseStateKeeper = MouseStateKeeper()
    private var activelyDraggingWindowId: WindowId?
    private var dragSuppressionTimer: Timer?
    private var globalMouseUpMonitor: Any?
    public var activeGroupingDropTargetColumnId: UUID?
    
    public init() {
        setupBindings()
        mouseStateKeeper.setDelegate(self)
        setupMouseUpMonitoring()
        setupMinimapHUDCallbacks()
    }
    
    // MARK: - Lifecycle
    
    public func start() {
        diagnostics.log(category: "Lifecycle", message: "Starting Iume Window Manager enabled=\(settings.isEnabled) layout=\(settings.layoutMode.rawValue) freeze=\(settings.freezeOnRelease) freeform=\(settings.freeformScroll) loop=\(settings.loopMode)")
        
        displayManager.refreshDisplays()
        initializeWorkspaces()
        
        guard permissions.checkPermission() else {
            diagnostics.log(level: "WARN", category: "Permissions", message: "Accessibility permission not yet granted")
            return
        }
        
        discoverAndRegisterWindows()
        diagnostics.log(category: "Registration", message: "Startup discovery registered windows=\(registry.allWindows().count) columns=\(workspaces[activeDisplayId]?.columns.count ?? 0)")
        shortcutManager.registerDefaultShortcuts()
        let tapStarted = scrollController.startEventTap()
        diagnostics.log(level: tapStarted ? "INFO" : "ERROR", category: "Gesture", message: "Startup event tap active=\(tapStarted)")
        mouseStateKeeper.startMonitoring()
        startPeriodicReconcile()
        applyLayout(animated: false)
    }
    
    /// Arranges all open eligible windows into continuous slide mode strip immediately.
    @discardableResult
    public func kickstart() -> Int {
        diagnostics.log(category: "Kickstart", message: "Kickstarting window arrangement into slide strip; previous enabled=\(settings.isEnabled)")
        
        displayManager.refreshDisplays()
        initializeWorkspaces()
        
        guard permissions.checkPermission() else {
            diagnostics.log(level: "WARN", category: "Permissions", message: "Accessibility permission missing on kickstart")
            permissions.promptForAccessibility()
            return 0
        }
        
        let wasEnabled = settings.isEnabled
        settings.isEnabled = true
        settings.layoutMode = .scrollStrip
        // [LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:KickstartPhysicsActivation]
        // Description: Guarantees kickstart activates full inertial, momentum, and smooth scrolling engine.
        // Ensure that kickstarting activates the full inertial, momentum, and smooth scrolling engine
        settings.freezeOnRelease = false
        settings.inertialScrolling = true
        settings.momentumScrolling = true
        settings.smoothScrollingEnabled = true
        // [END LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:KickstartPhysicsActivation]
        
        // Preserve pre-tiling frames if re-kickstarting while already actively managing
        registry.removeAll(keepOriginalFrames: wasEnabled)
        for id in workspaces.keys {
            if let display = displayManager.activeDisplays.first(where: { $0.id == id }) {
                workspaces[id] = DisplayWorkspace(displayGeometry: display)
            }
        }
        
        discoverAndRegisterWindows()
        diagnostics.log(category: "Registration", message: "Kickstart discovery registered windows=\(registry.allWindows().count) columns=\(workspaces[activeDisplayId]?.columns.count ?? 0)")
        shortcutManager.registerDefaultShortcuts()
        let tapStarted = scrollController.startEventTap()
        diagnostics.log(level: tapStarted ? "INFO" : "ERROR", category: "Gesture", message: "Kickstart event tap active=\(tapStarted)")
        mouseStateKeeper.startMonitoring()
        syncDisplayLinkWithActiveDisplay(force: true)
        settings.flushMemoryToDisk()
        startPeriodicReconcile()
        
        if var ws = workspaces[activeDisplayId] {
            ws.viewportOffset = 0
            ws.focusedColumnIndex = 0
            workspaces[activeDisplayId] = ws
        }
        
        // Kickstart is an activation transaction: register and place every
        // discovered window immediately, then leave scrolling to the live path.
        applyLayout(animated: false)
        
        let count = registry.allWindows().count
        diagnostics.log(category: "Kickstart", message: "Kickstart complete: \(count) windows arranged into slide strip; tap=\(tapStarted) monitoring=true")
        return count
    }
    
    public func stop(preserveEnabledState: Bool = false) {
        diagnostics.log(category: "Lifecycle", message: "Stopping Iume Window Manager")
        let wasEnabled = settings.isEnabled
        settings.isEnabled = false
        periodicReconcileTimer?.invalidate()
        periodicReconcileTimer = nil
        saveCurrentLayout()
        scrollController.stopEventTap()
        FocusBorderOverlay.shared.hide()
        TabBarOverlayController.shared.hideAll()
        DimmingOverlayController.shared.hide()
        MinimapHUDController.shared.fadeOut()
        if let monitor = globalMouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseUpMonitor = nil
        }
        mouseStateKeeper.stopMonitoring()
        mouseStateKeeper.reset()
        activelyDraggingWindowId = nil
        activelyResizingWindowId = nil
        dragSuppressionTimer?.invalidate()
        dragSuppressionTimer = nil
        restoreAllWindowFrames()
        parkedWindowIds.removeAll()
        registry.removeAll(keepOriginalFrames: false)
        workspaces.removeAll()
        spaceWorkspaces.removeAll()
        if preserveEnabledState {
            settings.isEnabled = wasEnabled
            settings.flushMemoryToDisk()
            diagnostics.log(category: "Lifecycle", message: "Termination cleanup preserved enabled=\(wasEnabled)")
        }
    }
    
    private func setupMouseUpMonitoring() {
        guard globalMouseUpMonitor == nil else { return }
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleMouseUp()
            }
        }
    }
    
    public func handleMouseUp() {
        guard activelyDraggingWindowId != nil || activelyResizingWindowId != nil else { return }
        let draggedId = activelyDraggingWindowId
        activelyDraggingWindowId = nil
        activelyResizingWindowId = nil
        dragSuppressionTimer?.invalidate()
        dragSuppressionTimer = nil
        resizeSuppressionTimer?.invalidate()
        resizeSuppressionTimer = nil
        
        GroupingPreviewOverlayController.shared.hide()
        if let dId = draggedId, let targetColId = activeGroupingDropTargetColumnId {
            activeGroupingDropTargetColumnId = nil
            combineWindow(dId, intoColumnWithId: targetColId)
            return
        }
        activeGroupingDropTargetColumnId = nil
        
        if var ws = workspaces[activeDisplayId] {
            // Apply Drag-to-Reorder on drop (mouse-up) to avoid mid-drag layout oscillation
            if let dId = draggedId, settings.dragToReorder,
               let colIdx = ws.columns.firstIndex(where: { $0.windowIds.contains(dId) }),
               let win = registry.get(windowId: dId) {
                var midpoints: [CGFloat] = []
                let effectiveGap = settings.appsEdgeTogether ? 0.0 : CGFloat(settings.windowGap)
                let stripOffsets = layoutEngine.columnStripOffsets(columns: ws.columns, gap: effectiveGap)
                for (idx, col) in ws.columns.enumerated() {
                    let colX = ws.displayGeometry.visibleFrame.minX + settings.edgeMargins.left + stripOffsets[idx] - ws.viewportOffset
                    midpoints.append(colX + (col.width / 2.0))
                }
                if let targetIdx = InteractionManager.shared.resolveDragReorderDropIndex(
                    draggedWindowId: dId,
                    cursorScreenX: win.frame.midX,
                    columnMidpointsScreenX: midpoints
                ), targetIdx != colIdx {
                    ws.focusedColumnIndex = layoutEngine.moveColumn(at: colIdx, direction: targetIdx > colIdx ? 1 : -1, columns: &ws.columns)
                }
            }
            
            // Synchronize any column widths to physical frames
            for (idx, col) in ws.columns.enumerated() {
                if let firstWinId = col.windowIds.first, let win = registry.get(windowId: firstWinId) {
                    if abs(win.frame.width - col.width) > 1.0 {
                        ws.columns[idx].width = win.frame.width
                    }
                }
            }
            workspaces[activeDisplayId] = ws
            applyLayout(animated: settings.enableTransitions)
            schedulePersistenceSave()
        }
    }
    
    // MARK: - Strip Overview & Reordering Support
    
    /// Reorders the columns on the active display strip and applies the physical layout.
    public func reorderColumns(newColumns: [WindowColumn]) {
        guard var ws = workspaces[activeDisplayId] else { return }
        ws.columns = newColumns
        workspaces[activeDisplayId] = ws
        applyLayout(animated: settings.enableTransitions)
        schedulePersistenceSave()
    }
    
    /// Selects and programmatically focuses the column at the given index, gliding the viewport to it.
    public func selectAndFocusColumn(at index: Int) {
        guard var ws = workspaces[activeDisplayId], index >= 0, index < ws.columns.count else { return }
        ws.focusedColumnIndex = index
        workspaces[activeDisplayId] = ws
        if let targetWinId = ws.columns[index].windowIds.first {
            focusWindowProgrammatically(targetWinId)
        }
        applyLayout(animated: settings.enableTransitions)
        schedulePersistenceSave()
    }
    
    // MARK: - Authoritative Scroll Geometry

    /// Resolves the current workspace scroll bounds exactly once. Every scroll,
    /// settle, snap, scrub, keyboard and drag path funnels through here so no
    /// caller can invent a different margin/gap/loop formula (D18, D03).
    private func scrollBounds(for ws: DisplayWorkspace) -> LayoutEngine.ScrollBounds {
        let totalWins = ws.columns.reduce(0) { $0 + $1.windowIds.count }
        let isBuiltin = CGDisplayIsBuiltin(ws.displayGeometry.id) == 1
        return layoutEngine.scrollBounds(
            columns: ws.columns,
            visibleFrame: ws.displayGeometry.visibleFrame,
            edgeMargins: settings.edgeMargins,
            totalWindowCount: totalWins,
            smartWindowMargins: settings.smartWindowMargins,
            disablePaddingOnBuiltinDisplay: settings.disablePaddingOnBuiltinDisplay,
            isBuiltinDisplay: isBuiltin,
            centerMode: settings.centerMode,
            windowGap: settings.appsEdgeTogether ? 0.0 : CGFloat(settings.windowGap),
            layoutMode: settings.layoutMode,
            loopMode: settings.loopMode
        )
    }

    /// Publishes the authoritative bounds onto the controller and returns them.
    /// The loop flag is derived from geometry, never from the setting alone.
    @discardableResult
    private func refreshScrollBounds(for ws: DisplayWorkspace) -> LayoutEngine.ScrollBounds {
        let bounds = scrollBounds(for: ws)
        scrollController.maxOffset = bounds.maxOffset
        scrollController.isLoopModeEnabled = bounds.loopEligible
        scrollController.loopPeriod = layoutEngine.cyclicStripPeriod(columns: ws.columns, gap: bounds.gap)
        return bounds
    }

    /// Centers the focused column through the same bounds every other scroll
    /// path uses. Menu-bar actions call this instead of re-deriving a limit.
    public func centerFocusedColumn() {
        guard let ws = workspaces[activeDisplayId], let current = ws.focusedColumnIndex else { return }
        let bounds = refreshScrollBounds(for: ws)
        let centerOffset = layoutEngine.centerColumnOffset(
            at: current,
            columns: ws.columns,
            visibleWidth: bounds.usableWidth,
            loopMode: bounds.loopEligible
        )
        let target = bounds.loopEligible ? centerOffset : min(centerOffset, bounds.maxOffset)
        scrollController.scrollTo(target: target, maxOffset: bounds.maxOffset, duration: settings.animationDuration)
    }

    public func setupMinimapHUDCallbacks() {
        let hud = MinimapHUDController.shared
        hud.onScrub = { [weak self] ratio in
            guard let self = self else { return }
            guard var ws = self.workspaces[self.activeDisplayId] else { return }
            // Scrub maps the ratio onto the authoritative scroll extent, so it
            // cannot disagree with trackpad, keyboard, or snap bounds (D18).
            let bounds = self.refreshScrollBounds(for: ws)
            let target = CGFloat(ratio) * bounds.maxOffset
            ws.viewportOffset = target
            self.workspaces[self.activeDisplayId] = ws
            self.applyLayout(animated: false)
        }
        hud.onScrubEnded = { [weak self] _ in
            self?.schedulePersistenceSave()
        }
        hud.onSelectColumn = { [weak self] colIndex in
            self?.selectAndFocusColumn(at: colIndex)
        }
        hud.onMoveColumn = { [weak self] fromIndex, toIndex in
            guard let self = self else { return }
            guard var ws = self.workspaces[self.activeDisplayId] else { return }
            guard fromIndex >= 0, fromIndex < ws.columns.count,
                  toIndex >= 0, toIndex < ws.columns.count,
                  fromIndex != toIndex else { return }
            let moving = ws.columns.remove(at: fromIndex)
            ws.columns.insert(moving, at: toIndex)
            ws.focusedColumnIndex = toIndex
            self.workspaces[self.activeDisplayId] = ws
            self.applyLayout(animated: self.settings.enableTransitions)
            self.schedulePersistenceSave()
        }
    }
    
    private var periodicReconcileTimer: Timer?
    
    private func startPeriodicReconcile() {
        periodicReconcileTimer?.invalidate()
        let timer = Timer(timeInterval: 60.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.reconcileUnmanagedWindows()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        periodicReconcileTimer = timer
    }
    
    public func reconcileUnmanagedWindows() {
        guard settings.isEnabled,
              !scrollController.isMoving,
              activelyDraggingWindowId == nil,
              activelyResizingWindowId == nil,
              mouseStateKeeper.state == .pointing else { return }
        
        // Self-healing watchdog: re-ensure event tap is active
        scrollController.startEventTap()
        
        guard let currentWs = workspaces[activeDisplayId] else { return }
        let currentWindowIds = Set(currentWs.columns.flatMap { $0.windowIds })
        
        let apps = appDiscovery.discoverEligibleApplications(excludedBundleIds: settings.excludedBundleIdentifiers)
        for app in apps {
            let pid = app.id
            observer.observe(pid: pid)
            let discovered = discovery.discoverWindows(for: pid, bundleId: app.bundleIdentifier, appName: app.localizedName)
            for (managed, axElement) in discovered {
                guard !managed.isFloating && !managed.isMinimized else { continue }
                if !currentWindowIds.contains(managed.id) {
                    registry.register(window: managed, axElement: axElement)
                    observer.observeWindow(element: axElement, pid: pid)
                    handleWindowCreated(element: axElement, pid: pid)
                }
            }
        }
    }
    
    public func dumpAllWindows() -> String {
        var report = "=== Iume Window Diagnostics Dump ===\n"
        let apps = appDiscovery.discoverEligibleApplications(excludedBundleIds: settings.excludedBundleIdentifiers)
        report += "Running Applications Found: \(apps.count)\n"
        for app in apps {
            report += "• [PID \(app.id)] \(app.localizedName) (\(app.bundleIdentifier))\n"
            let discovered = discovery.discoverWindows(for: app.id, bundleId: app.bundleIdentifier, appName: app.localizedName)
            if discovered.isEmpty {
                report += "   (No eligible windows)\n"
            }
            for (w, _) in discovered {
                let isManaged = registry.get(windowId: w.id) != nil
                report += "   ▶ [\(isManaged ? "MANAGED" : "UNMANAGED")] \"\(w.title)\" Frame: \(w.frame)\n"
            }
        }
        return report
    }
    
    /// Restores all managed windows back to their original pre-tiling positions on quit or disable.
    public func restoreAllWindowFrames() {
        diagnostics.log(category: "Lifecycle", message: "Restoring all managed windows to pre-tiling positions")
        observer.isPerformingProgrammaticUpdate = true
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.observer.isPerformingProgrammaticUpdate = false
            }
        }
        
        controller.clearFrameCache()
        
        let windows = registry.allWindows()
        for win in windows {
            guard let ax = registry.getAXElement(windowId: win.id) else { continue }
            var target = win.initialFrame
            if let display = displayManager.activeDisplays.first(where: { $0.frame.intersects(target) }) ?? displayManager.primaryDisplay() {
                let vis = display.visibleFrame
                var width = target.width >= 150 ? target.width : min(900, vis.width * 0.7)
                var height = target.height >= 120 ? target.height : min(650, vis.height * 0.7)
                width = min(width, vis.width)
                height = min(height, vis.height)
                var x = target.origin.x
                var y = target.origin.y
                if x < vis.minX || x > vis.maxX - 100 || x < -500 || x > 3000 {
                    x = max(vis.minX, vis.midX - width / 2)
                }
                if y < vis.minY || y > vis.maxY - 50 || y < -500 || y > 3000 {
                    y = max(vis.minY, vis.midY - height / 2)
                }
                target = CGRect(x: x, y: y, width: width, height: height)
            }
            controller.setFrame(element: ax, frame: target, windowId: win.id)
        }
    }
    
    // MARK: - Initial Setup
    
    private func initializeWorkspaces() {
        activeSpaceId = spaceManager.refreshCurrentSpace()
        for display in displayManager.activeDisplays {
            let key = WorkspaceKey(displayId: display.id, spaceId: activeSpaceId)
            if workspaces[display.id] == nil {
                let ws = DisplayWorkspace(displayGeometry: display)
                workspaces[display.id] = ws
                spaceWorkspaces[key] = ws
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
        let targetDisplayId = activeDisplayId != 0 ? activeDisplayId : primaryDisplay.id
        activeDisplayId = targetDisplayId
        
        var allDiscoveredWindows: [(ManagedWindow, AXUIElement)] = []
        
        for app in apps {
            observer.observe(pid: app.id)
            let discovered = discovery.discoverWindows(for: app.id, bundleId: app.bundleIdentifier, appName: app.localizedName)
            
            for (managed, axElement) in discovered {
                registry.register(window: managed, axElement: axElement)
                observer.observeWindow(element: axElement, pid: managed.pid)
                allDiscoveredWindows.append((managed, axElement))
                if managed.frame.width >= 200 {
                    controller.recordAppliedFrame(managed.frame, for: managed.id)
                }
            }
        }
        
        guard var ws = workspaces[targetDisplayId] else { return }
        
        // Restore saved layout (column order, widths, and stacks) if available
        let key = currentWorkspaceKey
        let savedState = persistence.load()
        if let savedSpace = savedState?.spaces[key.storageKey], !savedSpace.columns.isEmpty {
            diagnostics.log(category: "Persistence", message: "Restoring persisted layout for \(key): \(savedSpace.columns.count) columns")
            let availableWindows = allDiscoveredWindows.map { $0.0 }
            let restored = persistence.restoreSpaceLayout(
                savedLayout: savedSpace,
                availableWindows: availableWindows,
                visibleWidth: ws.displayGeometry.visibleFrame.width
            )
            
            ws.columns = restored.restoredColumns
            ws.focusedColumnIndex = restored.savedFocusedIndex ?? (ws.columns.isEmpty ? nil : 0)
            ws.viewportOffset = restored.savedViewportOffset
            
            // Add any newly launched windows not in saved state beside the focused column
            for (managed, _) in allDiscoveredWindows {
                guard !managed.isFloating && !managed.isMinimized else { continue }
                if !restored.placedWindowIds.contains(managed.id) {
                    let alreadyPresent = ws.columns.contains { $0.windowIds.contains(managed.id) }
                    if !alreadyPresent {
                        _ = layoutEngine.insertWindow(
                            managed.id,
                            into: &ws.columns,
                            focusedColumnIndex: ws.focusedColumnIndex,
                            policy: settings.insertionPolicy,
                            visibleWidth: ws.displayGeometry.visibleFrame.width
                        )
                    }
                }
            }
        } else {
            // Fresh arrangement: insert windows side-by-side along the strip
            for (managed, _) in allDiscoveredWindows {
                guard !managed.isFloating && !managed.isMinimized else { continue }
                let alreadyPresent = ws.columns.contains { $0.windowIds.contains(managed.id) }
                if !alreadyPresent {
                    _ = layoutEngine.insertWindow(
                        managed.id,
                        into: &ws.columns,
                        focusedColumnIndex: ws.focusedColumnIndex,
                        policy: settings.insertionPolicy,
                        visibleWidth: ws.displayGeometry.visibleFrame.width
                    )
                }
            }
            if !ws.columns.isEmpty {
                ws.focusedColumnIndex = 0
            }
        }
        
        workspaces[targetDisplayId] = ws
        spaceWorkspaces[key] = ws
        
        if let focusedIdx = ws.focusedColumnIndex, focusedIdx < ws.columns.count,
           let firstWinId = ws.columns[focusedIdx].windowIds.first {
            registry.focusedId = firstWinId
        } else if let firstWinId = ws.columns.first?.windowIds.first {
            registry.focusedId = firstWinId
        }
        
        diagnostics.updateMetrics(windows: registry.allWindows().count, columns: ws.columns.count)
        schedulePersistenceSave()
    }
    
    // MARK: - Event Bindings
    
    private func setupBindings() {
        // App lifecycle
        appDiscovery.onAppLaunched = { [weak self] app in
            guard let self = self, self.settings.isEnabled else { return }
            InteractionManager.shared.markUserInitiatedActivation(pid: app.processIdentifier)
            self.observer.observe(pid: app.processIdentifier)
            // Staggered discovery sequence: t = 0, 0.15, 0.5, 1.5, 4.0s
            for delay in [0.0, 0.15, 0.5, 1.5, 4.0] {
                if delay == 0.0 {
                    self.registerWindowsForApp(app)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self = self, self.settings.isEnabled else { return }
                        self.registerWindowsForApp(app)
                    }
                }
            }
        }
        
        appDiscovery.onAppActivated = { [weak self] app in
            guard let self = self, self.settings.isEnabled else { return }
            let pid = app.processIdentifier
            // If Iume itself programmatically activated this app on settle, ignore echo activation
            guard !self.isProgrammaticallyFocusing else { return }
            // If the app is already the active focused app in the current workspace, ignore echo
            if let curFocus = self.registry.focusedId, curFocus.pid == pid {
                return
            }
            InteractionManager.shared.markUserInitiatedActivation(pid: pid)
            self.observer.observe(pid: pid)
            self.registerWindowsForApp(app)
            self.syncFocusToActivatedApp(app)
        }
        
        appDiscovery.onAppTerminated = { [weak self] pid in
            guard let self = self else { return }
            self.observer.unobserve(pid: pid)
            self.handleAppTerminated(pid: pid)
        }
        
        appDiscovery.onSystemReconcileNeeded = { [weak self] in
            guard let self = self, self.settings.isEnabled else { return }
            self.reconcileUnmanagedWindows()
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
        
        observer.onWindowMiniaturized = { [weak self] element, pid in
            guard let self = self, self.settings.isEnabled else { return }
            self.handleWindowMiniaturized(element: element, pid: pid)
        }
        
        observer.onWindowDeminiaturized = { [weak self] element, pid in
            guard let self = self, self.settings.isEnabled else { return }
            self.handleWindowDeminiaturized(element: element, pid: pid)
        }
        
        observer.onFocusedWindowChanged = { [weak self] element, pid in
            guard let self = self, self.settings.isEnabled else { return }
            self.handleFocusedWindowChanged(element: element)
        }
        
        observer.onWindowTitleChanged = { [weak self] element, pid in
            guard let self = self, self.settings.isEnabled else { return }
            self.handleWindowTitleChanged(element: element)
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
        
        // Scroll updates (hardware display-link paced once per display refresh)
        // Query dynamic max offset on scroll start
        scrollController.onQueryMaxOffset = { [weak self] in
            guard let self = self, let ws = self.workspaces[self.activeDisplayId], !ws.columns.isEmpty else { return 0.0 }
            return self.refreshScrollBounds(for: ws).maxOffset
        }
        
        scrollController.onViewportOffsetChanged = { [weak self] newOffset in
            guard let self = self else { return }
            self.activeViewportOffsets[self.activeDisplayId] = newOffset
            guard var ws = self.workspaces[self.activeDisplayId] else { return }
            ws.viewportOffset = newOffset
            if UserDefaults.standard.bool(forKey: "iume.gestureDiagnostics") {
                let now = CACurrentMediaTime()
                if now - self.lastViewportTraceTime >= 0.10 {
                    self.lastViewportTraceTime = now
                    self.diagnostics.log(category: "Viewport", message: "offset=\(newOffset) moving=\(self.scrollController.isMoving) windows=\(self.registry.allWindows().count)")
                }
            }
            // Decoupled from @Published workspaces during continuous motion:
            // Do NOT reassign self.workspaces[self.activeDisplayId] = ws during continuous motion!
            // Passing `ws` with `newOffset` to `applyPhysicalWindowPositions(workspace: ws)`
            // ensures layout computation uses the real-time active offset without firing
            // Combine objectWillChange at 60-120 Hz.
            if self.scrollController.isMoving {
                self.pendingSettleWorkItem?.cancel()
                self.pendingSettleWorkItem = nil
                self.applyPhysicalWindowPositions(workspace: ws)
            }
        }
        
        // Minimap HUD activity updates (strictly throttled to ≤ 30 Hz & conditioned on user setting)
        scrollController.onScrollActivity = { [weak self] offset, maxOffset, velocity in
            guard let self = self, self.settings.showMinimapHUD else { return }
            let now = CACurrentMediaTime()
            guard now - self.lastMinimapUpdateTime >= 0.033 else { return }
            guard let ws = self.workspaces[self.activeDisplayId] else { return }
            self.lastMinimapUpdateTime = now
            let activeTitle = self.registry.focusedId.flatMap { self.registry.get(windowId: $0)?.title } ?? ""
            let screen = self.cachedScreen(for: self.activeDisplayId)
            MinimapHUDController.shared.update(
                columns: ws.columns,
                totalStripWidth: self.layoutEngine.totalStripWidth(columns: ws.columns),
                viewportOffset: offset,
                visibleWidth: ws.displayGeometry.visibleFrame.width,
                focusedIndex: ws.focusedColumnIndex,
                activeTitle: activeTitle,
                screen: screen,
                // Scroll activity is the explicit reveal boundary. Without this
                // flag an auto-hidden HUD receives state updates but is never
                // ordered back onto the screen.
                reveal: self.scrollController.lastActivitySource != .programmatic
            )
        }
        
        // Settle & snapping requested after 2-finger scroll
        scrollController.onSettleRequested = { [weak self] projectedOffset in
            guard let self = self, let ws = self.workspaces[self.activeDisplayId], !ws.columns.isEmpty else { return }
            let bounds = self.refreshScrollBounds(for: ws)
            let maxOffset = bounds.maxOffset
            let usableWidth = bounds.usableWidth
            let effectiveGap = bounds.gap
            
            if self.settings.freezeOnRelease || self.settings.freeformScroll || !self.settings.snapToColumn {
                let actualOffset = (self.settings.freeformScroll || !self.settings.snapToColumn) ? self.scrollController.currentOffset : projectedOffset
                let clampedOffset = min(max(0, actualOffset), maxOffset)
                let prominentColIdx = self.layoutEngine.prominentColumnIndex(
                    for: clampedOffset,
                    columns: ws.columns,
                    visibleWidth: usableWidth,
                    gap: effectiveGap
                )
                var updatedWs = ws
                updatedWs.viewportOffset = clampedOffset
                updatedWs.focusedColumnIndex = prominentColIdx
                if let targetWinId = ws.columns[prominentColIdx].windowIds.first {
                    self.registry.focusedId = targetWinId
                    self.lastFocusedWindowId = targetWinId
                    self.suppressFocusNotification(for: targetWinId, duration: 0.60)
                }
                self.workspaces[self.activeDisplayId] = updatedWs
                self.activeViewportOffsets[self.activeDisplayId] = clampedOffset
                self.scrollController.setOffset(clampedOffset, maxOffset: maxOffset)
                // Coalesce settle application onto main queue; do not run AX IPC inside displayLinkFired
                self.scheduleSettlePass()
                return
            }
            
            let snapTarget = self.layoutEngine.computeSnapTarget(
                for: projectedOffset,
                velocity: self.scrollController.settleVelocity,
                columns: ws.columns,
                visibleWidth: usableWidth,
                centerMode: self.settings.centerMode,
                gap: effectiveGap,
                loopMode: bounds.loopEligible,
                layoutMode: self.settings.layoutMode
            )
            
            var updatedWs = ws
            updatedWs.focusedColumnIndex = snapTarget.focusedColumnIndex
            if let targetWinId = ws.columns[snapTarget.focusedColumnIndex].windowIds.first {
                self.registry.focusedId = targetWinId
                self.lastFocusedWindowId = targetWinId
                self.suppressFocusNotification(for: targetWinId, duration: 0.60)
            }
            self.workspaces[self.activeDisplayId] = updatedWs
            
            self.scrollController.scrollTo(
                target: snapTarget.targetOffset,
                maxOffset: maxOffset,
                duration: self.settings.animationDuration,
                initialVelocity: self.scrollController.settleVelocity
            )
        }
        
        // Final settle pass when spring animation has settled
        scrollController.onAnimationCompleted = { [weak self] in
            guard let self = self else { return }
            // The strip can grow or shrink while a spring is in flight (window
            // closed, column removed, display resized). Re-query the authoritative
            // limit and clamp before the final frame write, otherwise we settle on
            // a destination that no longer exists.
            if let queried = self.scrollController.onQueryMaxOffset?(), queried.isFinite {
                let newMax = max(0, queried)
                if abs(newMax - self.scrollController.maxOffset) > 0.5 {
                    self.scrollController.maxOffset = newMax
                }
                if !self.scrollController.isLoopModeEnabled,
                   self.scrollController.currentOffset > newMax + 0.5 {
                    self.scrollController.setOffset(newMax, maxOffset: newMax)
                }
            }
            // Coalesce final settle application onto main queue
            self.scheduleSettlePass()
        }
        
        // Focus manager requests
        focusManager.onFocusRequested = { [weak self] winId, colIdx in
            self?.activateWindow(winId, inColumn: colIdx)
        }
        
        // Focus follows mouse hover requests (Amethyst sloppy focus)
        InteractionManager.shared.onFocusFollowsMouseTarget = { [weak self] winId in
            guard let self = self, self.settings.isEnabled else { return }
            guard let ws = self.workspaces[self.activeDisplayId] else { return }
            if let colIdx = ws.columns.firstIndex(where: { $0.windowIds.contains(winId) }) {
                if self.registry.focusedId != winId {
                    self.activateWindow(winId, inColumn: colIdx)
                }
            }
        }
        
        // Tab bar overlay requests
        TabBarOverlayController.shared.onTabSelected = { [weak self] winId, colId in
            self?.activateTab(windowId: winId, inColumnWithId: colId)
        }
        TabBarOverlayController.shared.onCloseTab = { [weak self] winId, colId in
            self?.closeTab(windowId: winId, inColumnWithId: colId)
        }
        TabBarOverlayController.shared.onAddNewWindow = { [weak self] colId in
            self?.addNewTab(toColumnWithId: colId)
        }
        TabBarOverlayController.shared.onAddExistingWindow = { [weak self] winId, colId in
            self?.addExistingWindowAsTab(winId, toColumnWithId: colId)
        }
        TabBarOverlayController.shared.onReorderTab = { [weak self] winId, colId, newIndex in
            self?.reorderTab(windowId: winId, inColumnWithId: colId, toIndex: newIndex)
        }
        TabBarOverlayController.shared.onDetachTab = { [weak self] winId, colId in
            self?.detachTab(windowId: winId, fromColumnWithId: colId)
        }
        TabBarOverlayController.shared.onUngroupAll = { [weak self] colId in
            self?.ungroupAllTabs(inColumnWithId: colId)
        }
        TabBarOverlayController.shared.onTogglePin = { [weak self] colId in
            self?.togglePinTabBar(forColumnWithId: colId)
        }
        TabBarOverlayController.shared.onMoveTabBetweenColumns = { [weak self] winId, fromColId, toColId in
            self?.moveTabBetweenColumns(windowId: winId, fromColumnId: fromColId, toColumnId: toColId)
        }
        TabBarOverlayController.shared.onCloseOtherTabs = { [weak self] winId, colId in
            self?.closeOtherTabs(windowId: winId, inColumnWithId: colId)
        }
        TabBarOverlayController.shared.onCloseTabsToRight = { [weak self] winId, colId in
            self?.closeTabsToRight(windowId: winId, inColumnWithId: colId)
        }
        TabBarOverlayController.shared.onRenameTab = { [weak self] winId, colId, newTitle in
            self?.renameTab(windowId: winId, inColumnWithId: colId, newTitle: newTitle)
        }
        TabBarOverlayController.shared.onResetTabTitle = { [weak self] winId, colId in
            self?.resetTabTitle(windowId: winId, inColumnWithId: colId)
        }
        TabBarOverlayController.shared.onToggleLockTab = { [weak self] winId, colId in
            self?.toggleLockTab(windowId: winId, inColumnWithId: colId)
        }
        TabBarOverlayController.shared.onRenameGroup = { [weak self] colId, newName in
            self?.renameTabGroup(inColumnWithId: colId, newName: newName)
        }
        TabBarOverlayController.shared.onChangeGroupColor = { [weak self] colId, colorHex in
            self?.setTabGroupColor(inColumnWithId: colId, colorHex: colorHex)
        }
        TabBarOverlayController.shared.onToggleCollapseGroup = { [weak self] colId in
            self?.toggleCollapseTabGroup(inColumnWithId: colId)
        }
        TabBarOverlayController.shared.onDuplicateTab = { [weak self] winId, colId in
            self?.duplicateTab(windowId: winId, inColumnWithId: colId)
        }
        
        // Window verification updates (app-quantized bounds sync, e.g. Terminal, Xcode)
        controller.onWindowFrameVerified = { [weak self] winId, verifiedFrame in
            DispatchQueue.main.async {
                self?.handleWindowFrameVerified(winId: winId, verifiedFrame: verifiedFrame)
            }
        }
        
        // Keyboard shortcuts
        shortcutManager.onShortcutTriggered = { [weak self] action in
            guard let self = self else { return }
            if !self.settings.isEnabled && action != .kickstart {
                return
            }
            self.handleShortcut(action)
        }
        
        // Display changes
        displayManager.onDisplaysChanged = { [weak self] displays in
            self?.handleDisplaysChanged(displays)
        }
        
        // Virtual Spaces change
        spaceManager.onActiveSpaceChanged = { [weak self] newSpaceId, displayId in
            guard let self = self, self.settings.isEnabled else { return }
            self.switchSpace(to: newSpaceId, displayId: displayId)
        }
        
        // Dynamic permission state changes
        permissions.onPermissionStateChanged = { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                self.diagnostics.log(level: "WARN", category: "Permissions", message: "Accessibility permission revoked. Suspending motion pipeline.")
                // Tear down the tap and park the physics so no animation keeps
                // running against an inaccessible WindowServer.
                self.scrollController.stopEventTap()
                self.scrollController.suspend()
                self.mouseStateKeeper.stopMonitoring()
                return
            }
            self.diagnostics.log(category: "Permissions", message: "Accessibility permission granted! Bootstrapping windows...")
            self.discoverAndRegisterWindows()
            self.shortcutManager.registerDefaultShortcuts()
            self.scrollController.startEventTap()
            self.mouseStateKeeper.startMonitoring()
            self.syncDisplayLinkWithActiveDisplay()
            self.applyLayout(animated: false)
        }
        
        // Reactive settings bindings - Ensure EVERY setting takes effect immediately without restart!
        settings.$windowGap
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self = self, self.settings.isEnabled else { return }
                self.reflowColumnsForGeometryChange()
                self.applyLayout(animated: false)
            }
            .store(in: &cancellables)
            
        settings.$appsEdgeTogether
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self = self, self.settings.isEnabled else { return }
                self.reflowColumnsForGeometryChange()
                self.applyLayout(animated: false)
            }
            .store(in: &cancellables)
            
        settings.$edgeMargins
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self = self, self.settings.isEnabled else { return }
                self.reflowColumnsForGeometryChange()
                self.applyLayout(animated: false)
            }
            .store(in: &cancellables)
            
        settings.$smartWindowMargins
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self = self, self.settings.isEnabled else { return }
                self.applyLayout(animated: false)
            }
            .store(in: &cancellables)
            
        settings.$disablePaddingOnBuiltinDisplay
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self = self, self.settings.isEnabled else { return }
                self.applyLayout(animated: false)
            }
            .store(in: &cancellables)
            
        settings.$defaultColumnWidthRatio
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self = self, self.settings.isEnabled else { return }
                self.reflowColumnsForGeometryChange()
                self.applyLayout(animated: true)
            }
            .store(in: &cancellables)
            
        settings.$centerMode
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self = self, self.settings.isEnabled else { return }
                self.applyLayout(animated: true)
            }
            .store(in: &cancellables)
            
        settings.$layoutMode
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self = self, self.settings.isEnabled else { return }
                self.applyLayout(animated: true)
            }
            .store(in: &cancellables)
            
        settings.$dimUnfocusedWindows
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self = self, self.settings.isEnabled else { return }
                if let ws = self.workspaces[self.activeDisplayId] {
                    DimmingOverlayController.shared.updateDimming(
                        visibleFrame: ws.displayGeometry.visibleFrame,
                        isFocusedFullscreen: false
                    )
                }
            }
            .store(in: &cancellables)
            
        settings.$showFocusBorder
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self = self, self.settings.isEnabled else { return }
                if enabled, let focusedId = self.registry.focusedId, let frame = self.registry.get(windowId: focusedId)?.frame, let ws = self.workspaces[self.activeDisplayId] {
                    FocusBorderOverlay.shared.updateFrame(frame, visibleFrame: ws.displayGeometry.visibleFrame, animated: true)
                } else {
                    FocusBorderOverlay.shared.hide()
                }
            }
            .store(in: &cancellables)
            
        settings.$showMinimapHUD
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self = self, self.settings.isEnabled else { return }
                if !enabled {
                    MinimapHUDController.shared.fadeOut()
                } else if self.workspaces[self.activeDisplayId] != nil {
                    self.applyLayout(animated: false)
                }
            }
            .store(in: &cancellables)
            
        settings.$useLegacyOptionShortcuts
            .removeDuplicates()
            .dropFirst()
            .sink { _ in
                ShortcutManager.shared.registerDefaultShortcuts()
            }
            .store(in: &cancellables)
    }
    
    /// Proportionally adapts column widths to newly configured gaps or margins so windows remain flush.
    public func reflowColumnsForGeometryChange() {
        for (displayId, var ws) in workspaces {
            guard !ws.columns.isEmpty else { continue }
            let vis = ws.displayGeometry.visibleFrame
            let usableW = max(200, vis.width - settings.edgeMargins.left - settings.edgeMargins.right)
            let gap = CGFloat(settings.windowGap)
            
            if ws.columns.count == 1 {
                ws.columns[0].width = usableW
            } else if ws.columns.count == 2 {
                let halfW = floor((usableW - gap) * CGFloat(settings.defaultColumnWidthRatio))
                ws.columns[0].width = halfW
                ws.columns[1].width = max(200, usableW - gap - halfW)
            } else {
                let defaultW = floor((usableW - gap) * CGFloat(settings.defaultColumnWidthRatio))
                for idx in ws.columns.indices {
                    if !ws.columns[idx].isFullWidth {
                        ws.columns[idx].width = defaultW
                    } else {
                        ws.columns[idx].width = usableW
                    }
                }
            }
            workspaces[displayId] = ws
        }
    }
    
    // MARK: - Action Handlers
    
    public func registerWindowsForApp(_ app: NSRunningApplication) {
        guard let bundleId = app.bundleIdentifier,
              !settings.excludedBundleIdentifiers.contains(bundleId) else { return }
        
        let targetDisplayId: CGDirectDisplayID = {
            if let focusedId = registry.focusedId {
                for (dispId, ws) in workspaces {
                    if ws.columns.contains(where: { $0.windowIds.contains(focusedId) }) {
                        return dispId
                    }
                }
            }
            return activeDisplayId != 0 ? activeDisplayId : (displayManager.primaryDisplay()?.id ?? 0)
        }()
        
        let discovered = discovery.discoverWindows(for: app.processIdentifier, bundleId: bundleId, appName: app.localizedName ?? "App")
        
        var addedAny = false
        for (managed, axElement) in discovered {
            if registry.get(windowId: managed.id) != nil { continue }
            registry.register(window: managed, axElement: axElement)
            observer.observeWindow(element: axElement, pid: managed.pid)
            if managed.frame.width >= 200 {
                controller.recordAppliedFrame(managed.frame, for: managed.id)
            }
            guard !managed.isFloating && !managed.isMinimized else { continue }
            
            if var ws = workspaces[targetDisplayId] {
                let alreadyPresent = ws.columns.contains { $0.windowIds.contains(managed.id) }
                if !alreadyPresent {
                    let effectiveFocusedIndex: Int? = {
                        if let f = ws.focusedColumnIndex, f >= 0, f < ws.columns.count {
                            return f
                        }
                        if let focusedId = registry.focusedId {
                            return ws.columns.firstIndex(where: { $0.windowIds.contains(focusedId) })
                        }
                        return ws.columns.isEmpty ? nil : (ws.columns.count - 1)
                    }()
                    let colIdx = layoutEngine.insertWindow(
                        managed.id,
                        into: &ws.columns,
                        focusedColumnIndex: effectiveFocusedIndex,
                        policy: settings.insertionPolicy,
                        visibleWidth: ws.displayGeometry.visibleFrame.width
                    )
                    ws.focusedColumnIndex = colIdx
                    workspaces[targetDisplayId] = ws
                    registry.focusedId = managed.id
                    addedAny = true
                    
                    // Activate and raise newly launched window
                    controller.focus(element: axElement, pid: managed.pid)
                }
            }
        }
        if addedAny {
            activeDisplayId = targetDisplayId
            applyLayout(animated: true)
            schedulePersistenceSave()
        }
    }
    
    /// Synchronizes strip focus and viewport position when the user switches to an already-managed app (via Click, Dock, or Cmd+Tab).
    public func syncFocusToActivatedApp(_ app: NSRunningApplication) {
        guard !scrollController.isMoving else { return }
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        
        // Try to match the app's currently focused AX window first, or fallback to its first managed window in the strip
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        var focusedRef: AnyObject?
        var targetWinId: WindowId? = nil
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
           let focEl = focusedRef {
            targetWinId = registry.findWindowId(matchingAXElement: focEl as! AXUIElement)
        }
        if targetWinId == nil {
            targetWinId = registry.windows(forPid: pid).first(where: { !$0.isFloating && !$0.isMinimized })?.id
        }
        guard let winId = targetWinId else { return }
        
        for (dispId, var ws) in workspaces {
            if let colIdx = ws.columns.firstIndex(where: { $0.windowIds.contains(winId) }) {
                if activeDisplayId == dispId && ws.focusedColumnIndex == colIdx {
                    var changed = false
                    if let tabIdx = ws.columns[colIdx].windowIds.firstIndex(of: winId),
                       ws.columns[colIdx].activeWindowIndex != tabIdx {
                        ws.columns[colIdx].activeWindowIndex = tabIdx
                        changed = true
                    }
                    if registry.focusedId != winId {
                        registry.focusedId = winId
                        changed = true
                    }
                    if changed { workspaces[dispId] = ws }
                    return
                }
                activeDisplayId = dispId
                ws.viewportOffset = activeViewportOffset(for: dispId)
                ws.focusedColumnIndex = colIdx
                if let tabIdx = ws.columns[colIdx].windowIds.firstIndex(of: winId) {
                    ws.columns[colIdx].activeWindowIndex = tabIdx
                }
                registry.focusedId = winId
                workspaces[dispId] = ws
                
                let isFreeform = settings.freeformScroll || !settings.snapToColumn
                let vis = ws.displayGeometry.visibleFrame
                let colOffsets = layoutEngine.columnStripOffsets(columns: ws.columns)
                if colIdx < colOffsets.count {
                    let colStripOffset = colOffsets[colIdx]
                    let colW = ws.columns[colIdx].width
                    let screenX = vis.origin.x + colStripOffset - ws.viewportOffset
                    let isVisible = (screenX + colW > vis.minX + 40) && (screenX < vis.maxX - 40)
                    if isFreeform || isVisible {
                        applyPhysicalWindowPositions(workspace: ws)
                        return
                    }
                }
                
                applyLayout(animated: settings.enableTransitions)
                return
            }
        }
    }
    
    private func handleWindowCreated(element: AXUIElement, pid: pid_t, retry: Int = 0) {
        let runningApp = NSRunningApplication(processIdentifier: pid)
        let bundleId = runningApp?.bundleIdentifier ?? "app.\(pid)"
        let appName = runningApp?.localizedName ?? "App"
        guard !settings.excludedBundleIdentifiers.contains(bundleId) else { return }
        
        if discovery.isEligibleWindow(element) {
            let classification = discovery.classifyWindow(element)
            let isFullscreen = discovery.copyBoolAttribute(element, attribute: "AXFullScreen" as CFString) ?? false
            guard !isFullscreen else { return }
            
            let title = discovery.copyStringAttribute(element, attribute: kAXTitleAttribute as CFString) ?? "\(appName) Window"
            let frame = discovery.copyFrame(element) ?? CGRect(x: 100, y: 100, width: 800, height: 600)
            let rawId: UInt64 = {
                if let cgId = getCGWindowID(for: element) {
                    return UInt64(cgId)
                }
                return UInt64(CFHash(element))
            }()
            let windowId = WindowId(pid: pid, rawId: rawId)
            
            // Prevent duplicate registration
            if registry.get(windowId: windowId) != nil { return }
            
            let managed = ManagedWindow(
                id: windowId,
                pid: pid,
                bundleIdentifier: bundleId,
                appName: appName,
                title: title,
                frame: frame,
                initialFrame: frame,
                isFloating: (classification == .float)
            )
            
            registry.register(window: managed, axElement: element)
            observer.observeWindow(element: element, pid: pid)
            
            if classification == .float {
                diagnostics.log(category: "Window", message: "Registered floating window: \(title)")
                return
            }
            
            let targetDisplayId: CGDirectDisplayID = {
                if let focusedId = registry.focusedId {
                    for (dispId, ws) in workspaces {
                        if ws.columns.contains(where: { $0.windowIds.contains(focusedId) }) {
                            return dispId
                        }
                    }
                }
                return activeDisplayId != 0 ? activeDisplayId : (displayManager.primaryDisplay()?.id ?? 0)
            }()
            
            guard var ws = workspaces[targetDisplayId] else { return }
            let alreadyPresent = ws.columns.contains { $0.windowIds.contains(windowId) }
            guard !alreadyPresent else { return }
            
            // 1. Check if there is an explicit pending tab addition for this column (+ button in tab bar)
            if let targetColId = pendingTabAdditionColumnId,
               (pid == pendingTabAdditionPID || bundleId == pendingTabAdditionBundleId) {
                if let targetColIdx = ws.columns.firstIndex(where: { $0.id == targetColId }) {
                    ws.columns[targetColIdx].presentationMode = .tabbed
                    if !ws.columns[targetColIdx].windowIds.contains(windowId) {
                        ws.columns[targetColIdx].windowIds.append(windowId)
                    }
                    ws.columns[targetColIdx].activeWindowIndex = ws.columns[targetColIdx].windowIds.count - 1
                    ws.focusedColumnIndex = targetColIdx
                    registry.focusedId = windowId
                    workspaces[targetDisplayId] = ws
                    activeDisplayId = targetDisplayId
                    controller.focus(element: element, pid: pid, cgWindowID: UInt32(windowId.rawId))
                    applyLayout(animated: true)
                    schedulePersistenceSave()
                    diagnostics.log(category: "Tab", message: "Attached newly created tab for \(appName) to column \(targetColIdx)")
                    pendingTabAdditionColumnId = nil
                    pendingTabAdditionPID = nil
                    pendingTabAdditionBundleId = nil
                    return
                }
            }
            
            // 2. Auto-Tab windows of the same app together (if enabled by policy or toggle)
            let shouldAutoTab = settings.autoTabSameAppWindows || settings.smartGroupingPolicy == .sameApp
            if shouldAutoTab && settings.smartGroupingPolicy != .manualOnly {
                if let existingColIdx = ws.columns.firstIndex(where: { col in
                    col.windowIds.contains { wid in
                        registry.get(windowId: wid)?.bundleIdentifier == bundleId || wid.pid == pid
                    }
                }) {
                    ws.columns[existingColIdx].presentationMode = .tabbed
                    if !ws.columns[existingColIdx].windowIds.contains(windowId) {
                        ws.columns[existingColIdx].windowIds.append(windowId)
                    }
                    ws.columns[existingColIdx].activeWindowIndex = ws.columns[existingColIdx].windowIds.count - 1
                    ws.focusedColumnIndex = existingColIdx
                    registry.focusedId = windowId
                    workspaces[targetDisplayId] = ws
                    activeDisplayId = targetDisplayId
                    controller.focus(element: element, pid: pid, cgWindowID: UInt32(windowId.rawId))
                    applyLayout(animated: true)
                    schedulePersistenceSave()
                    diagnostics.log(category: "Tab", message: "Auto-tabbed window for \(appName) into existing column \(existingColIdx)")
                    return
                }
            }
            
            let effectiveFocusedIndex: Int? = {
                if let focusedId = registry.focusedId,
                   let idx = ws.columns.firstIndex(where: { $0.windowIds.contains(focusedId) }) {
                    return idx
                }
                if let f = ws.focusedColumnIndex, f >= 0, f < ws.columns.count {
                    return f
                }
                return ws.columns.isEmpty ? nil : (ws.columns.count - 1)
            }()
            // New windows must open immediately to the right of the focused strip — explicit parity with tilemymac/chainyourmac.
            let newColIdx = layoutEngine.insertWindow(
                windowId,
                into: &ws.columns,
                focusedColumnIndex: effectiveFocusedIndex,
                policy: .afterFocused,
                visibleWidth: ws.displayGeometry.visibleFrame.width
            )
            let isUserInitiated = (NSWorkspace.shared.frontmostApplication?.processIdentifier == pid) ||
                InteractionManager.shared.shouldFocusNewlyCreatedWindow(appPID: pid, currentFocusedPID: registry.focusedId?.pid)
            if isUserInitiated {
                ws.focusedColumnIndex = newColIdx
                workspaces[targetDisplayId] = ws
                registry.focusedId = windowId
                activeDisplayId = targetDisplayId
                
                // Activate and raise newly created user-launched window
                controller.focus(element: element, pid: pid)
                applyLayout(animated: true)
            } else {
                // Background popup: slot beside focused column silently, do not steal focus, do not scroll
                workspaces[targetDisplayId] = ws
                applyLayout(animated: false)
            }
            schedulePersistenceSave()
            diagnostics.log(category: "Window", message: "Created & slotted window beside focused: \(title) (isUserInitiated: \(isUserInitiated))")
            return
        }
        
        // If not directly eligible yet, retry and also fallback to registering windows for the app
        if retry < 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self = self, self.settings.isEnabled else { return }
                self.handleWindowCreated(element: element, pid: pid, retry: retry + 1)
                if let runningApp = NSRunningApplication(processIdentifier: pid) {
                    self.registerWindowsForApp(runningApp)
                }
            }
        }
    }
    
    private func handleWindowMiniaturized(element: AXUIElement, pid: pid_t) {
        guard let winId = registry.findWindowId(matchingAXElement: element) else { return }
        guard var ws = workspaces[activeDisplayId] else { return }
        guard ws.columns.contains(where: { $0.windowIds.contains(winId) }) else { return }
        
        ws.focusedColumnIndex = layoutEngine.removeWindow(winId, from: &ws.columns, currentFocusedIndex: ws.focusedColumnIndex)
        workspaces[activeDisplayId] = ws
        applyLayout(animated: true)
        schedulePersistenceSave()
        diagnostics.log(category: "Window", message: "Miniaturized window: \(winId)")
    }
    
    private func handleWindowDeminiaturized(element: AXUIElement, pid: pid_t) {
        handleWindowCreated(element: element, pid: pid)
        diagnostics.log(category: "Window", message: "Deminiaturized window for PID \(pid)")
    }
    
    private func handleWindowDestroyed(element: AXUIElement, pid: pid_t) {
        guard let winId = registry.findWindowId(matchingAXElement: element) else { return }
        registry.unregister(windowId: winId)
        
        guard var ws = workspaces[activeDisplayId] else { return }
        ws.focusedColumnIndex = layoutEngine.removeWindow(winId, from: &ws.columns, currentFocusedIndex: ws.focusedColumnIndex)
        workspaces[activeDisplayId] = ws
        
        applyLayout(animated: true)
        schedulePersistenceSave()
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
        schedulePersistenceSave()
        diagnostics.log(category: "App", message: "Terminated app PID \(pid)")
    }
    
    public func displayId(containing windowId: WindowId) -> CGDirectDisplayID? {
        for (dispId, ws) in workspaces {
            if ws.columns.contains(where: { $0.windowIds.contains(windowId) }) {
                return dispId
            }
        }
        return activeDisplayId != 0 ? activeDisplayId : nil
    }
    
    private func handleFocusedWindowChanged(element: AXUIElement) {
        guard !scrollController.isMoving else { return }
        guard !isProgrammaticallyFocusing else { return }
        guard !observer.isPerformingProgrammaticUpdate else { return }
        
        // Prevent settle feedback loop by suppressing our own programmatic focus echo
        if let suppressedId = suppressedFocusNotificationWindowId,
           ProcessInfo.processInfo.systemUptime < suppressedFocusExpiration,
           let matchingId = registry.findWindowId(matchingAXElement: element),
           matchingId == suppressedId {
            return
        }
        
        let isFreeform = settings.freeformScroll || !settings.snapToColumn
        
        // 1. Direct match with registered window
        if let winId = registry.findWindowId(matchingAXElement: element) {
            let targetDispId = displayId(containing: winId) ?? activeDisplayId
            guard var ws = workspaces[targetDispId] else { return }
            ws.viewportOffset = activeViewportOffset(for: targetDispId)
            if let colIdx = ws.columns.firstIndex(where: { $0.windowIds.contains(winId) }) {
                if let tabIdx = ws.columns[colIdx].windowIds.firstIndex(of: winId) {
                    ws.columns[colIdx].activeWindowIndex = tabIdx
                }
                if registry.focusedId == winId && ws.focusedColumnIndex == colIdx && activeDisplayId == targetDispId {
                    workspaces[targetDispId] = ws
                    return
                }
                activeDisplayId = targetDispId
                ws.focusedColumnIndex = colIdx
                registry.focusedId = winId
                workspaces[targetDispId] = ws
                
                let vis = ws.displayGeometry.visibleFrame
                let colOffsets = layoutEngine.columnStripOffsets(columns: ws.columns)
                if colIdx < colOffsets.count {
                    let colStripOffset = colOffsets[colIdx]
                    let colW = ws.columns[colIdx].width
                    let screenX = vis.origin.x + colStripOffset - ws.viewportOffset
                    let isVisible = (screenX + colW > vis.minX + 40) && (screenX < vis.maxX - 40)
                    if isFreeform || isVisible {
                        applyPhysicalWindowPositions(workspace: ws)
                        return
                    }
                }
                applyLayout(animated: true)
            }
            return
        }
        
        // 2. Control/subview focus: check if element is inside an already registered window
        var parentWindowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &parentWindowRef) == .success,
           let parentWindow = parentWindowRef,
           let parentWinId = registry.findWindowId(matchingAXElement: (parentWindow as! AXUIElement)) {
            let targetDispId = displayId(containing: parentWinId) ?? activeDisplayId
            if let suppressedId = suppressedFocusNotificationWindowId,
               ProcessInfo.processInfo.systemUptime < suppressedFocusExpiration,
               parentWinId == suppressedId {
                return
            }
            guard var ws = workspaces[targetDispId] else { return }
            ws.viewportOffset = activeViewportOffset(for: targetDispId)
            if let colIdx = ws.columns.firstIndex(where: { $0.windowIds.contains(parentWinId) }) {
                if let tabIdx = ws.columns[colIdx].windowIds.firstIndex(of: parentWinId) {
                    ws.columns[colIdx].activeWindowIndex = tabIdx
                }
                if registry.focusedId == parentWinId && ws.focusedColumnIndex == colIdx && activeDisplayId == targetDispId {
                    workspaces[targetDispId] = ws
                    return
                }
                activeDisplayId = targetDispId
                ws.focusedColumnIndex = colIdx
                registry.focusedId = parentWinId
                workspaces[targetDispId] = ws
                
                let vis = ws.displayGeometry.visibleFrame
                let colOffsets = layoutEngine.columnStripOffsets(columns: ws.columns)
                if colIdx < colOffsets.count {
                    let colStripOffset = colOffsets[colIdx]
                    let colW = ws.columns[colIdx].width
                    let screenX = vis.origin.x + colStripOffset - ws.viewportOffset
                    let isVisible = (screenX + colW > vis.minX + 40) && (screenX < vis.maxX - 40)
                    if isFreeform || isVisible {
                        applyPhysicalWindowPositions(workspace: ws)
                        return
                    }
                }
                applyLayout(animated: true)
            }
            return
        }
        
        // 3. Only process truly new windows if element is an eligible top-level standard window
        guard discovery.isEligibleWindow(element) else {
            return
        }
        
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != 0 else { return }
        
        handleWindowCreated(element: element, pid: pid)
    }
    
    public func refreshTabBarOverlays() {
        guard let workspace = workspaces[activeDisplayId] else { return }
        updateTabBarOverlays(for: workspace)
    }
    
    private func handleWindowTitleChanged(element: AXUIElement) {
        guard let winId = registry.findWindowId(matchingAXElement: element),
              let current = registry.get(windowId: winId),
              let newTitle = discovery.copyStringAttribute(element, attribute: kAXTitleAttribute as CFString),
              !newTitle.isEmpty,
              current.title != newTitle else { return }
        
        registry.update(windowId: winId) { $0.title = newTitle }
        // Refresh the strip in place; a title change must never re-tile windows.
        refreshTabBarOverlays()
    }
    
    private func handleShortcut(_ action: ShortcutAction) {
        guard var ws = workspaces[activeDisplayId] else { return }
        
        switch action {
        case .focusLeft:
            focusManager.focusLeft(columns: ws.columns, currentColumnIndex: ws.focusedColumnIndex, wrapAround: settings.wrapAroundFocus)
        case .focusRight:
            focusManager.focusRight(columns: ws.columns, currentColumnIndex: ws.focusedColumnIndex, wrapAround: settings.wrapAroundFocus)
        case .focusUp:
            focusManager.focusUp(columns: ws.columns, currentColumnIndex: ws.focusedColumnIndex, currentWindowId: registry.focusedId, wrapAround: settings.wrapAroundFocus)
        case .focusDown:
            focusManager.focusDown(columns: ws.columns, currentColumnIndex: ws.focusedColumnIndex, currentWindowId: registry.focusedId, wrapAround: settings.wrapAroundFocus)
        case .moveColumnLeft:
            if let current = ws.focusedColumnIndex {
                ws.focusedColumnIndex = layoutEngine.moveColumn(at: current, direction: -1, columns: &ws.columns)
                workspaces[activeDisplayId] = ws
                applyLayout(animated: true)
                schedulePersistenceSave()
            }
        case .moveColumnRight:
            if let current = ws.focusedColumnIndex {
                ws.focusedColumnIndex = layoutEngine.moveColumn(at: current, direction: 1, columns: &ws.columns)
                workspaces[activeDisplayId] = ws
                applyLayout(animated: true)
                schedulePersistenceSave()
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
            cycleWindowOrTab(forward: true)
        case .cyclePrev:
            cycleWindowOrTab(forward: false)
        case .scrollLeft:
            let bounds = refreshScrollBounds(for: ws)
            let base = scrollController.isMoving ? scrollController.smoothTargetOffset : scrollController.currentOffset
            let targetOffset = bounds.loopEligible ? base - 180 : max(0, base - 180)
            if settings.enableTransitions {
                scrollController.scrollTo(target: targetOffset, maxOffset: bounds.maxOffset, duration: settings.animationDuration, initialVelocity: scrollController.currentVelocity)
            } else {
                scrollController.scrollBy(deltaX: -180, maxOffset: bounds.maxOffset)
            }
        case .scrollRight:
            let bounds = refreshScrollBounds(for: ws)
            let base = scrollController.isMoving ? scrollController.smoothTargetOffset : scrollController.currentOffset
            let targetOffset = bounds.loopEligible ? base + 180 : min(bounds.maxOffset, base + 180)
            if settings.enableTransitions {
                scrollController.scrollTo(target: targetOffset, maxOffset: bounds.maxOffset, duration: settings.animationDuration, initialVelocity: scrollController.currentVelocity)
            } else {
                scrollController.scrollBy(deltaX: 180, maxOffset: bounds.maxOffset)
            }
        case .cycleWidth:
            if let current = ws.focusedColumnIndex {
                _ = layoutEngine.cyclePresetWidth(at: current, columns: &ws.columns, visibleWidth: ws.displayGeometry.visibleFrame.width, backward: false)
                workspaces[activeDisplayId] = ws
                applyLayout(animated: true)
                schedulePersistenceSave()
            }
        case .cycleWidthBackward:
            if let current = ws.focusedColumnIndex {
                _ = layoutEngine.cyclePresetWidth(at: current, columns: &ws.columns, visibleWidth: ws.displayGeometry.visibleFrame.width, backward: true)
                workspaces[activeDisplayId] = ws
                applyLayout(animated: true)
                schedulePersistenceSave()
            }
        case .nudgeWider:
            if let current = ws.focusedColumnIndex {
                _ = layoutEngine.nudgeColumnWidth(at: current, columns: &ws.columns, deltaRatio: 0.05, visibleWidth: ws.displayGeometry.visibleFrame.width)
                workspaces[activeDisplayId] = ws
                applyLayout(animated: true)
                schedulePersistenceSave()
            }
        case .nudgeNarrower:
            if let current = ws.focusedColumnIndex {
                _ = layoutEngine.nudgeColumnWidth(at: current, columns: &ws.columns, deltaRatio: -0.05, visibleWidth: ws.displayGeometry.visibleFrame.width)
                workspaces[activeDisplayId] = ws
                applyLayout(animated: true)
                schedulePersistenceSave()
            }
        case .centerColumn:
            if let current = ws.focusedColumnIndex {
                let bounds = refreshScrollBounds(for: ws)
                let centerOffset = layoutEngine.centerColumnOffset(
                    at: current,
                    columns: ws.columns,
                    visibleWidth: bounds.usableWidth,
                    loopMode: bounds.loopEligible
                )
                let target = bounds.loopEligible ? centerOffset : min(centerOffset, bounds.maxOffset)
                scrollController.scrollTo(target: target, maxOffset: bounds.maxOffset, duration: settings.animationDuration)
            }
        case .fullWidth:
            if let current = ws.focusedColumnIndex {
                layoutEngine.maximizeColumn(at: current, columns: &ws.columns, visibleWidth: ws.displayGeometry.visibleFrame.width)
                workspaces[activeDisplayId] = ws
                applyLayout(animated: true)
                schedulePersistenceSave()
            }
        case .stackLeft:
            stackFocusedWindow(direction: -1)
        case .stackRight:
            stackFocusedWindow(direction: 1)
        case .unstack:
            unstackFocusedWindow()
        case .toggleTabbedMode:
            toggleColumnTabbedMode()
        case .tabSameAppWindows:
            tabSameAppWindows()
        case .tabAllSameAppWindows:
            tabAllSameAppWindows()
        case .nextTab:
            cycleTabInFocusedColumn(forward: true)
        case .prevTab:
            cycleTabInFocusedColumn(forward: false)
        case .newTab:
            addTabToFocusedColumn()
        case .closeTab:
            closeActiveTab()
        case .detachTab:
            detachActiveTab()
        case .toggleTabBarPin:
            toggleActiveTabBarPin()
        case .ungroupActiveTab:
            ungroupFocusedTabGroup()
        case .selectTab1: selectTabByPosition(1)
        case .selectTab2: selectTabByPosition(2)
        case .selectTab3: selectTabByPosition(3)
        case .selectTab4: selectTabByPosition(4)
        case .selectTab5: selectTabByPosition(5)
        case .selectTab6: selectTabByPosition(6)
        case .selectTab7: selectTabByPosition(7)
        case .selectTab8: selectTabByPosition(8)
        case .selectLastTab: selectLastTab()
        case .moveTabLeft: reorderActiveTabInFocusedColumn(direction: -1)
        case .moveTabRight: reorderActiveTabInFocusedColumn(direction: 1)
        case .sendToNextDisplay:
            sendFocusedColumnToNextDisplay(follow: false)
        case .sendToNextDisplayFollow:
            sendFocusedColumnToNextDisplay(follow: true)
        case .switchWorkspace1: switchVirtualWorkspace(1)
        case .switchWorkspace2: switchVirtualWorkspace(2)
        case .switchWorkspace3: switchVirtualWorkspace(3)
        case .switchWorkspace4: switchVirtualWorkspace(4)
        case .switchWorkspace5: switchVirtualWorkspace(5)
        case .switchWorkspace6: switchVirtualWorkspace(6)
        case .switchWorkspace7: switchVirtualWorkspace(7)
        case .switchWorkspace8: switchVirtualWorkspace(8)
        case .switchWorkspace9: switchVirtualWorkspace(9)
        case .moveWorkspace1: moveFocusedWindowToVirtualWorkspace(1)
        case .moveWorkspace2: moveFocusedWindowToVirtualWorkspace(2)
        case .moveWorkspace3: moveFocusedWindowToVirtualWorkspace(3)
        case .moveWorkspace4: moveFocusedWindowToVirtualWorkspace(4)
        case .moveWorkspace5: moveFocusedWindowToVirtualWorkspace(5)
        case .moveWorkspace6: moveFocusedWindowToVirtualWorkspace(6)
        case .moveWorkspace7: moveFocusedWindowToVirtualWorkspace(7)
        case .moveWorkspace8: moveFocusedWindowToVirtualWorkspace(8)
        case .moveWorkspace9: moveFocusedWindowToVirtualWorkspace(9)
        case .kickstart:
            kickstart()
        case .stopAndRestore:
            stop()
            StatusBarController.current?.rebuildMenu()
        case .toggleAppsEdgeTogether:
            settings.appsEdgeTogether.toggle()
            reflowColumnsForGeometryChange()
            applyLayout(animated: true)
            schedulePersistenceSave()
        case .toggleMagneticSnapping:
            settings.edgeSnapping.toggle()
            StatusBarController.current?.rebuildMenu()
            schedulePersistenceSave()
        case .openSettings:
            StatusBarController.current?.openSettings()
        case .focusFirst:
            if let firstWin = ws.columns.first?.windowIds.first {
                activateWindow(firstWin, inColumn: 0)
            }
        case .focusLast:
            if !ws.columns.isEmpty, let lastWin = ws.columns.last?.windowIds.first {
                activateWindow(lastWin, inColumn: ws.columns.count - 1)
            }
        case .nudgeStackTaller:
            if let current = ws.focusedColumnIndex, let focId = registry.focusedId {
                layoutEngine.nudgeStackWindowHeight(windowId: focId, at: current, deltaRatio: 0.10, columns: &ws.columns)
                workspaces[activeDisplayId] = ws
                applyLayout(animated: true)
                schedulePersistenceSave()
            }
        case .nudgeStackShorter:
            if let current = ws.focusedColumnIndex, let focId = registry.focusedId {
                layoutEngine.nudgeStackWindowHeight(windowId: focId, at: current, deltaRatio: -0.10, columns: &ws.columns)
                workspaces[activeDisplayId] = ws
                applyLayout(animated: true)
                schedulePersistenceSave()
            }
        case .equalizeStackHeights:
            if let current = ws.focusedColumnIndex {
                layoutEngine.equalizeStackHeights(at: current, columns: &ws.columns)
                workspaces[activeDisplayId] = ws
                applyLayout(animated: true)
                schedulePersistenceSave()
            }
        case .toggleFloatWindow:
            if let focId = registry.focusedId, let win = registry.get(windowId: focId) {
                let newFloating = !win.isFloating
                registry.update(windowId: focId) { $0.isFloating = newFloating }
                if newFloating {
                    ws.focusedColumnIndex = layoutEngine.removeWindow(focId, from: &ws.columns, currentFocusedIndex: ws.focusedColumnIndex)
                } else {
                    let idx = layoutEngine.insertWindow(
                        focId,
                        into: &ws.columns,
                        focusedColumnIndex: ws.focusedColumnIndex,
                        policy: settings.insertionPolicy,
                        visibleWidth: ws.displayGeometry.visibleFrame.width
                    )
                    ws.focusedColumnIndex = idx
                }
                workspaces[activeDisplayId] = ws
                applyLayout(animated: true)
                schedulePersistenceSave()
            }
        case .throwSpaceLeft:
            throwFocusedWindowToSpace(direction: -1)
        case .throwSpaceRight:
            throwFocusedWindowToSpace(direction: 1)
        case .focusDisplay1:
            focusDisplay(index: 0)
        case .focusDisplay2:
            focusDisplay(index: 1)
        case .focusDisplay3:
            focusDisplay(index: 2)
        case .reevaluateWindows:
            reevaluateWindows()
        case .relaunchIume:
            relaunchIume()
        case .toggleOverview:
            StripOverviewController.shared.toggle()
        case .toggleLoopMode:
            settings.loopMode.toggle()
            StatusBarController.current?.rebuildMenu()
            applyLayout(animated: true)
        case .cycleLayoutMode:
            let all = LayoutMode.allCases
            if let idx = all.firstIndex(of: settings.layoutMode) {
                settings.layoutMode = all[(idx + 1) % all.count]
                applyLayout(animated: true)
            }
        case .tileAllToGrid:
            settings.layoutMode = .grid
            applyLayout(animated: true)
        case .tileAllToTall:
            settings.layoutMode = .tall
            applyLayout(animated: true)
        case .openRadialMenu:
            RadialMenuOverlayController.shared.toggle(visibleFrameQuartz: ws.displayGeometry.visibleFrame)
        case .openCustomBoxGrid:
            CustomGridOverlayController.shared.toggle()
        case .showCheatsheet:
            ShortcutCheatsheetController.shared.toggle()
        case .snapLeftHalf:
            snapActiveWindow(to: .leftHalf)
        case .snapRightHalf:
            snapActiveWindow(to: .rightHalf)
        case .snapTopHalf:
            snapActiveWindow(to: .topHalf)
        case .snapBottomHalf:
            snapActiveWindow(to: .bottomHalf)
        case .snapTopLeft:
            snapActiveWindow(to: .topLeft)
        case .snapTopRight:
            snapActiveWindow(to: .topRight)
        case .snapBottomLeft:
            snapActiveWindow(to: .bottomLeft)
        case .snapBottomRight:
            snapActiveWindow(to: .bottomRight)
        case .snapFirstThird:
            snapActiveWindow(to: .firstThird)
        case .snapCenterThird:
            snapActiveWindow(to: .centerThird)
        case .snapLastThird:
            snapActiveWindow(to: .lastThird)
        case .snapMaximize:
            snapActiveWindow(to: .maximize)
        case .snapAlmostMaximize:
            snapActiveWindow(to: .almostMaximize)
        case .snapCenter:
            snapActiveWindow(to: .center)
        case .scaleLarger:
            scaleActiveWindow(factor: 1.1)
        case .scaleSmaller:
            scaleActiveWindow(factor: 0.9)
        case .balanceSizes:
            balanceColumnSizes()
        case .swapWindowWithMain:
            if let current = ws.focusedColumnIndex, current > 0, current < ws.columns.count {
                ws.columns.swapAt(0, current)
                ws.focusedColumnIndex = 0
                workspaces[activeDisplayId] = ws
                applyLayout(animated: true)
                schedulePersistenceSave()
                LaunchHUDController.shared.showTemporaryNotification(message: "Swapped with Main Window", color: .blue)
            }
        }
    }
    
    private var lastSnapAction: WindowBoxAction?
    private var lastSnapTime: Date = .distantPast
    private var currentCycleFraction: CGFloat = 0.50
    
    private var isBoxTiledLayout: Bool {
        switch settings.layoutMode {
        case .grid, .tall, .wide, .bsp, .row, .column:
            return true
        case .scrollStrip, .focusColumn, .centeredFocus, .manualLayout:
            return false
        }
    }
    
    private var lastObservedBoxWindowIds: [CGDirectDisplayID: Set<WindowId>] = [:]

    @discardableResult
    public func clearStaleBoxOverridesIfNeeded(_ ws: inout DisplayWorkspace) -> Bool {
        let currentWindowIds = Set(ws.columns.flatMap { $0.windowIds })
        guard let previous = lastObservedBoxWindowIds[ws.displayGeometry.id] else {
            lastObservedBoxWindowIds[ws.displayGeometry.id] = currentWindowIds
            return false
        }
        if previous == currentWindowIds {
            return false
        }
        lastObservedBoxWindowIds[ws.displayGeometry.id] = currentWindowIds
        if !ws.customBoxFrames.isEmpty {
            ws.customBoxFrames.removeAll()
            return true
        }
        return false
    }

    public func boxFreeResizeFrames(
        windowId: WindowId,
        proposedFrame: CGRect,
        previousFrame: CGRect?,
        tiledFrames: [WindowId: CGRect],
        gap: CGFloat,
        screenBounds: CGRect
    ) -> [WindowId: CGRect] {
        guard let previousFrame else { return [:] }
        var result: [WindowId: CGRect] = [windowId: proposedFrame]
        let engine = BoxTilingEngine(windowGap: gap)
        let adjustments = engine.computeCooperativeAdjustments(
            resizingWindowId: windowId,
            oldFrame: previousFrame,
            newFrame: proposedFrame,
            tiledWindows: tiledFrames,
            screenBounds: screenBounds
        )
        for adj in adjustments {
            result[adj.windowId] = adj.adjustedFrame
        }
        return result
    }

    public func clearCustomBoxFrames() {
        guard var ws = workspaces[activeDisplayId] else { return }
        ws.customBoxFrames.removeAll()
        workspaces[activeDisplayId] = ws
    }
    
    public func applyCustomBoxFrameToActiveWindow(_ targetFrame: CGRect, label: String = "Custom Window Box") {
        guard let focId = registry.focusedId,
              let ax = registry.getAXElement(windowId: focId),
              var ws = workspaces[activeDisplayId] else { return }
        observer.recordExpectedFrame(targetFrame, for: focId, duration: 0.65)
        _ = controller.setFrame(element: ax, frame: targetFrame, windowId: focId)
        registry.update(windowId: focId) {
            $0.frame = targetFrame
            $0.preferredWidth = targetFrame.width
        }
        ws.customBoxFrames[focId] = targetFrame
        if settings.layoutMode == .manualLayout {
            ws.manualFrames[focId] = targetFrame
        } else if let colIdx = ws.columns.firstIndex(where: { $0.windowIds.contains(focId) }) {
            ws.columns[colIdx].width = targetFrame.width
        }
        workspaces[activeDisplayId] = ws
        schedulePersistenceSave()
        BoxPreviewHUDController.shared.flash(
            title: label,
            subtitle: "\(Int(round(targetFrame.width))) × \(Int(round(targetFrame.height)))",
            systemImageName: "squareshape.split.2x2",
            screen: cachedScreen(for: activeDisplayId)
        )
    }
    
    public func snapActiveWindow(to action: WindowBoxAction) {
        guard let focId = registry.focusedId,
              let ax = registry.getAXElement(windowId: focId),
              let ws = workspaces[activeDisplayId] else { return }
        
        let now = Date()
        if lastSnapAction == action && now.timeIntervalSince(lastSnapTime) < 1.5 {
            currentCycleFraction = BoxTilingEngine.nextCycleFraction(after: currentCycleFraction)
        } else {
            currentCycleFraction = 0.50
        }
        lastSnapAction = action
        lastSnapTime = now
        
        let gap = settings.appsEdgeTogether ? 0.0 : CGFloat(settings.windowGap)
        let boxEngine = BoxTilingEngine(
            windowGap: gap,
            edgeMargins: settings.edgeMargins
        )
        let targetFrame = boxEngine.frame(for: action, in: ws.displayGeometry.visibleFrame, cycleFraction: currentCycleFraction)
        observer.recordExpectedFrame(targetFrame, for: focId, duration: 0.65)
        _ = controller.setFrame(element: ax, frame: targetFrame, windowId: focId)
        registry.update(windowId: focId) { $0.frame = targetFrame }
        var updatedWs = ws
        updatedWs.customBoxFrames[focId] = targetFrame
        if settings.layoutMode == .manualLayout {
            updatedWs.manualFrames[focId] = targetFrame
        } else if let colIdx = ws.columns.firstIndex(where: { $0.windowIds.contains(focId) }) {
            updatedWs.columns[colIdx].width = targetFrame.width
        }
        workspaces[activeDisplayId] = updatedWs
        
        let fractionDesc = (action == .leftHalf || action == .rightHalf || action == .topHalf || action == .bottomHalf)
            ? " (\(Int(round(currentCycleFraction * 100)))%)"
            : ""
        BoxPreviewHUDController.shared.flash(
            title: action.rawValue + fractionDesc,
            subtitle: "Adjusted Window Box",
            systemImageName: "rectangle.inset.filled",
            screen: cachedScreen(for: activeDisplayId)
        )
    }

    public func scaleActiveWindow(factor: CGFloat) {
        guard let focId = registry.focusedId,
              let ax = registry.getAXElement(windowId: focId),
              let currentFrame = registry.get(windowId: focId)?.frame,
              let ws = workspaces[activeDisplayId] else { return }
        let bounds = ws.displayGeometry.visibleFrame
        
        if isBoxTiledLayout {
            scaleActiveTiledWindow(windowId: focId, currentFrame: currentFrame, factor: factor, workspace: ws)
            return
        }
        
        let newW = max(200.0, min(bounds.width, currentFrame.width * factor))
        let newH = max(150.0, min(bounds.height, currentFrame.height * factor))
        let newX = max(bounds.minX, min(bounds.maxX - newW, currentFrame.midX - newW / 2.0))
        let newY = max(bounds.minY, min(bounds.maxY - newH, currentFrame.midY - newH / 2.0))
        let targetFrame = CGRect(x: newX, y: newY, width: newW, height: newH)
        observer.recordExpectedFrame(targetFrame, for: focId, duration: 0.65)
        _ = controller.setFrame(element: ax, frame: targetFrame, windowId: focId)
        registry.update(windowId: focId) { $0.frame = targetFrame }
        if settings.layoutMode == .manualLayout {
            var updatedWs = ws
            updatedWs.manualFrames[focId] = targetFrame
            workspaces[activeDisplayId] = updatedWs
        } else if let colIdx = ws.columns.firstIndex(where: { $0.windowIds.contains(focId) }) {
            var updatedWs = ws
            updatedWs.columns[colIdx].width = targetFrame.width
            workspaces[activeDisplayId] = updatedWs
        }
        BoxPreviewHUDController.shared.flash(
            title: factor > 1.0 ? "Expanded Window" : "Shrunk Window",
            subtitle: "\(Int(round(newW))) × \(Int(round(newH)))",
            systemImageName: factor > 1.0 ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
            screen: cachedScreen(for: activeDisplayId)
        )
    }

    private func scaleActiveTiledWindow(
        windowId: WindowId,
        currentFrame: CGRect,
        factor: CGFloat,
        workspace ws: DisplayWorkspace
    ) {
        let bounds = ws.displayGeometry.visibleFrame
        let gap = settings.appsEdgeTogether ? 0.0 : CGFloat(settings.windowGap)
        let engine = BoxTilingEngine(windowGap: gap, edgeMargins: settings.edgeMargins)
        
        var frames: [WindowId: CGRect] = [:]
        for column in ws.columns {
            for id in column.windowIds {
                if let frame = registry.get(windowId: id)?.frame {
                    frames[id] = frame
                }
            }
        }
        guard !frames.isEmpty else { return }
        
        var updated = engine.resizeTiledWindow(
            windowId: windowId,
            frames: frames,
            edge: .right,
            delta: currentFrame.width * (factor - 1.0),
            screenBounds: bounds,
            gap: gap
        )
        var afterWidth = frames
        for (id, frame) in updated { afterWidth[id] = frame }
        
        let vertical = engine.resizeTiledWindow(
            windowId: windowId,
            frames: afterWidth,
            edge: .bottom,
            delta: currentFrame.height * (factor - 1.0),
            screenBounds: bounds,
            gap: gap
        )
        for (id, frame) in vertical { updated[id] = frame }
        
        guard !updated.isEmpty, let resizedFocused = updated[windowId] else { return }
        
        controller.withAtomicScreenUpdates {
            for (id, frame) in updated {
                registry.update(windowId: id) {
                    $0.frame = frame
                    $0.preferredWidth = frame.width
                }
                if let element = registry.getAXElement(windowId: id) {
                    observer.recordExpectedFrame(frame, for: id, duration: 0.65)
                    _ = controller.setFrame(element: element, frame: frame, windowId: id)
                }
            }
        }
        
        BoxPreviewHUDController.shared.flash(
            title: factor > 1.0 ? "Expanded Window" : "Shrunk Window",
            subtitle: "\(Int(round(resizedFocused.width))) × \(Int(round(resizedFocused.height)))",
            systemImageName: factor > 1.0 ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
            screen: cachedScreen(for: activeDisplayId)
        )
    }
    
    public func balanceColumnSizes() {
        guard var ws = workspaces[activeDisplayId], !ws.columns.isEmpty else { return }
        ws.customBoxFrames.removeAll()
        let equalWidth = max(200.0, ws.displayGeometry.visibleFrame.width / CGFloat(ws.columns.count))
        for i in 0..<ws.columns.count {
            ws.columns[i].width = equalWidth
        }
        workspaces[activeDisplayId] = ws
        applyLayout(animated: true)
        schedulePersistenceSave()
        LaunchHUDController.shared.showTemporaryNotification(message: "Balanced Column Sizes", color: .blue)
    }
    
    public func throwFocusedWindowToSpace(direction: Int) {
        guard registry.focusedId != nil else { return }
        let currentSpace = spaceManager.currentSpaceId
        let targetSpace = direction > 0 ? (currentSpace + 1) : (currentSpace > 1 ? currentSpace - 1 : currentSpace)
        guard targetSpace != currentSpace else { return }
        
        moveFocusedWindowToVirtualWorkspace(Int(targetSpace))
        LaunchHUDController.shared.showTemporaryNotification(message: "Window Thrown to Space \(targetSpace)", color: .blue)
    }
    
    public func focusDisplay(index: Int) {
        let displays = displayManager.activeDisplays.sorted { $0.frame.minX < $1.frame.minX }
        guard index >= 0, index < displays.count else { return }
        let target = displays[index]
        activeDisplayId = target.id
        if let ws = workspaces[target.id], let colIdx = ws.focusedColumnIndex, colIdx < ws.columns.count {
            if let winId = ws.columns[colIdx].windowIds.first {
                activateWindow(winId, inColumn: colIdx)
            }
        }
        LaunchHUDController.shared.showTemporaryNotification(message: "Focused Display \(index + 1): \(target.name)", color: .blue)
    }
    
    public func reevaluateWindows() {
        diagnostics.log(category: "Lifecycle", message: "Manually re-evaluating all windows...")
        clearScreenCache()
        discoverAndRegisterWindows()
        reflowColumnsForGeometryChange()
        applyLayout(animated: true)
        LaunchHUDController.shared.showTemporaryNotification(message: "Windows Re-evaluated & Refreshed", color: .green)
    }
    
    public func relaunchIume() {
        diagnostics.log(category: "Lifecycle", message: "Relaunching Iume daemon...")
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
    
    public func sendFocusedColumnToNextDisplay(follow: Bool = false) {
        let displays = displayManager.activeDisplays
        guard displays.count > 1 else { return }
        guard var currentWs = workspaces[activeDisplayId],
              let colIdx = currentWs.focusedColumnIndex,
              colIdx < currentWs.columns.count else { return }
        
        let sortedDisplays = displays.sorted { $0.frame.minX < $1.frame.minX }
        guard let currentIdx = sortedDisplays.firstIndex(where: { $0.id == activeDisplayId }) else { return }
        let nextDisplay = sortedDisplays[(currentIdx + 1) % sortedDisplays.count]
        
        var columnToMove = currentWs.columns.remove(at: colIdx)
        let sourceWidth = currentWs.displayGeometry.visibleFrame.width
        let targetWidth = nextDisplay.visibleFrame.width
        if sourceWidth > 0 && targetWidth > 0 {
            columnToMove.width = max(380, min(targetWidth, columnToMove.width * (targetWidth / sourceWidth)))
        }
        
        currentWs.focusedColumnIndex = currentWs.columns.isEmpty ? nil : min(colIdx, currentWs.columns.count - 1)
        workspaces[activeDisplayId] = currentWs
        
        var nextWs = workspaces[nextDisplay.id] ?? DisplayWorkspace(displayGeometry: nextDisplay)
        nextWs.columns.append(columnToMove)
        nextWs.focusedColumnIndex = nextWs.columns.count - 1
        workspaces[nextDisplay.id] = nextWs
        
        if follow {
            activeDisplayId = nextDisplay.id
            if let firstWinId = columnToMove.windowIds.first, let ax = registry.getAXElement(windowId: firstWinId) {
                registry.focusedId = firstWinId
                controller.focus(element: ax, pid: firstWinId.pid)
            }
        }
        
        applyLayout(animated: true)
        schedulePersistenceSave()
        diagnostics.log(category: "Display", message: "Sent column to display \(nextDisplay.id) (follow: \(follow))")
    }
    
    public func stackFocusedWindow(direction: Int) {
        guard var ws = workspaces[activeDisplayId],
              let current = ws.focusedColumnIndex,
              let focusedId = registry.focusedId else { return }
        let target = current + direction
        guard target >= 0, target < ws.columns.count else { return }
        
        layoutEngine.stackWindow(
            windowId: focusedId,
            fromColumnIndex: current,
            toColumnIndex: target,
            columns: &ws.columns
        )
        ws.focusedColumnIndex = min(target, ws.columns.count - 1)
        workspaces[activeDisplayId] = ws
        applyLayout(animated: true)
        schedulePersistenceSave()
        diagnostics.log(category: "Stack", message: "Stacked window \(focusedId) into column \(target)")
    }
    
    public func unstackFocusedWindow() {
        guard var ws = workspaces[activeDisplayId],
              let current = ws.focusedColumnIndex,
              let focusedId = registry.focusedId else { return }
        guard ws.columns[current].windowIds.count > 1 else { return }
        
        let newColIdx = layoutEngine.unstackWindow(
            windowId: focusedId,
            fromColumnIndex: current,
            columns: &ws.columns,
            visibleWidth: ws.displayGeometry.visibleFrame.width
        )
        ws.focusedColumnIndex = newColIdx
        workspaces[activeDisplayId] = ws
        applyLayout(animated: true)
        schedulePersistenceSave()
        diagnostics.log(category: "Stack", message: "Unstacked window \(focusedId) into new column \(newColIdx)")
    }
    
    public func toggleColumnTabbedMode() {
        guard var ws = workspaces[activeDisplayId],
              let current = ws.focusedColumnIndex else { return }
        layoutEngine.toggleColumnTabbedMode(at: current, columns: &ws.columns)
        workspaces[activeDisplayId] = ws
        applyLayout(animated: true)
        schedulePersistenceSave()
        diagnostics.log(category: "Tab", message: "Toggled tabbed mode for column \(current)")
    }
    
    public func tabSameAppWindows() {
        guard var ws = workspaces[activeDisplayId] else { return }
        let focusedId = registry.focusedId ?? (ws.focusedColumnIndex.flatMap { (0 <= $0 && $0 < ws.columns.count) ? ws.columns[$0].windowIds.first : nil })
        guard let focusedId = focusedId,
              let focusedWin = registry.get(windowId: focusedId) else { return }
        let targetBundle = focusedWin.bundleIdentifier
        let targetPid = focusedWin.pid
        let appName = focusedWin.appName
        
        var sameAppWinIds: [WindowId] = []
        for col in ws.columns {
            for winId in col.windowIds {
                if let win = registry.get(windowId: winId),
                   (!targetBundle.isEmpty && win.bundleIdentifier == targetBundle) || (win.pid == targetPid) {
                    if !sameAppWinIds.contains(winId) {
                        sameAppWinIds.append(winId)
                    }
                }
            }
        }
        
        // If only 1 window of this app is open, switch its column to tabbed
        // presentation mode so the tab bar and Add Tab (+) button appear.
        if sameAppWinIds.count <= 1 {
            let colIdx = ws.columns.firstIndex(where: { $0.windowIds.contains(focusedId) }) ?? ws.focusedColumnIndex
            if let colIdx, colIdx >= 0 && colIdx < ws.columns.count {
                ws.columns[colIdx].presentationMode = .tabbed
                ws.columns[colIdx].tabBarPinned = true
                workspaces[activeDisplayId] = ws
                applyLayout(animated: true)
                schedulePersistenceSave()
                diagnostics.log(category: "Tab", message: "Turned column \(colIdx) into tabbed mode with Add Tab (+) support for \(appName)")
            }
            return
        }
        
        let insertIdx = ws.focusedColumnIndex ?? ws.columns.count
        let wasPinned = ws.columns.first(where: { $0.presentationMode == .tabbed && $0.windowIds.contains(focusedId) })?.tabBarPinned ?? false
        guard let newIdx = layoutEngine.groupWindows(
            sameAppWinIds,
            into: &ws.columns,
            at: insertIdx,
            activeWindowId: focusedId
        ) else { return }
        
        ws.columns[newIdx].tabBarPinned = wasPinned
        ws.focusedColumnIndex = newIdx
        workspaces[activeDisplayId] = ws
        applyLayout(animated: true)
        schedulePersistenceSave()
        diagnostics.log(category: "Tab", message: "Tabbed \(sameAppWinIds.count) windows of \(appName)")
    }
    
    public func tabAllSameAppWindows() {
        guard var ws = workspaces[activeDisplayId] else { return }
        
        var appGroups: [String: [WindowId]] = [:]
        for col in ws.columns {
            for winId in col.windowIds {
                if let win = registry.get(windowId: winId) {
                    let key = win.bundleIdentifier.isEmpty ? "pid_\(win.pid)" : win.bundleIdentifier
                    appGroups[key, default: []].append(winId)
                }
            }
        }
        
        var newColumns: [WindowColumn] = []
        var handledWindowIds = Set<WindowId>()
        
        for col in ws.columns {
            for winId in col.windowIds {
                guard !handledWindowIds.contains(winId) else { continue }
                if let win = registry.get(windowId: winId) {
                    let key = win.bundleIdentifier.isEmpty ? "pid_\(win.pid)" : win.bundleIdentifier
                    let group = appGroups[key] ?? [winId]
                    if group.count > 1 {
                        let sourceWidth = ws.columns.first(where: { $0.windowIds.contains(winId) })?.width
                        let wasPinned = ws.columns.first(where: { $0.windowIds.contains(winId) && $0.tabBarPinned }) != nil
                        var tabbedCol = WindowColumn(
                            windowIds: group,
                            width: sourceWidth ?? 800,
                            presentationMode: .tabbed,
                            tabBarPinned: wasPinned
                        )
                        if let focusedId = registry.focusedId,
                           let activeIdx = group.firstIndex(of: focusedId) {
                            tabbedCol.activeWindowIndex = activeIdx
                        }
                        newColumns.append(tabbedCol)
                        for gid in group { handledWindowIds.insert(gid) }
                    } else {
                        newColumns.append(WindowColumn(windowIds: [winId]))
                        handledWindowIds.insert(winId)
                    }
                } else {
                    newColumns.append(WindowColumn(windowIds: [winId]))
                    handledWindowIds.insert(winId)
                }
            }
        }
        
        ws.columns = newColumns
        if let focId = registry.focusedId {
            ws.focusedColumnIndex = ws.columns.firstIndex(where: { $0.windowIds.contains(focId) })
        }
        workspaces[activeDisplayId] = ws
        applyLayout(animated: true)
        schedulePersistenceSave()
        diagnostics.log(category: "Tab", message: "Tabbed all same-app windows across active display")
    }
    
    public func activateTab(windowId: WindowId, inColumnWithId columnId: UUID) {
        guard var ws = workspaces[activeDisplayId] else { return }
        guard let colIdx = ws.columns.firstIndex(where: { $0.id == columnId }) else { return }
        ws.focusedColumnIndex = colIdx
        ws.columns[colIdx].selectWindow(windowId)
        registry.focusedId = windowId
        workspaces[activeDisplayId] = ws
        
        suppressFocusNotification(for: windowId, duration: 0.60)
        focusWindowProgrammatically(windowId)
        
        if settings.mouseFollowsFocus {
            if let frame = registry.get(windowId: windowId)?.frame {
                InteractionManager.shared.warpMouseIfNeeded(to: frame)
            }
        }
        applyLayout(animated: true)
    }

    public func closeTab(windowId: WindowId, inColumnWithId columnId: UUID) {
        guard var ws = workspaces[activeDisplayId] else { return }
        guard let colIdx = ws.columns.firstIndex(where: { $0.id == columnId }) else { return }
        
        // 1. Request AX to close window
        if let ax = registry.getAXElement(windowId: windowId) {
            controller.close(element: ax)
        }
        
        // 2. Remove window from column
        ws.columns[colIdx].removeWindow(windowId)
        ws.columns[colIdx].normalizeTabPresentation()
        
        if ws.columns[colIdx].windowIds.isEmpty {
            ws.columns.remove(at: colIdx)
            ws.focusedColumnIndex = ws.columns.isEmpty ? nil : min(colIdx, ws.columns.count - 1)
            if let fIdx = ws.focusedColumnIndex, let firstWinId = ws.columns[fIdx].activeWindowId ?? ws.columns[fIdx].windowIds.first {
                registry.focusedId = firstWinId
                focusWindowProgrammatically(firstWinId)
            } else {
                registry.focusedId = nil
            }
        } else {
            if let activeId = ws.columns[colIdx].activeWindowId {
                registry.focusedId = activeId
                focusWindowProgrammatically(activeId)
            }
        }
        
        workspaces[activeDisplayId] = ws
        applyLayout(animated: true)
        schedulePersistenceSave()
        diagnostics.log(category: "Tab", message: "Closed tab window \(windowId) in column \(colIdx)")
    }
    
    public func addNewTab(toColumnWithId columnId: UUID) {
        guard var ws = workspaces[activeDisplayId] else { return }
        guard let colIdx = ws.columns.firstIndex(where: { $0.id == columnId }) else { return }
        let col = ws.columns[colIdx]
        
        let targetWinId = col.activeWindowId ?? col.windowIds.first
        guard let winId = targetWinId, let managed = registry.get(windowId: winId) else { return }
        
        let pid = managed.pid
        let bundleId = managed.bundleIdentifier
        let appName = managed.appName
        
        pendingTabAdditionColumnId = columnId
        pendingTabAdditionPID = pid
        pendingTabAdditionBundleId = bundleId
        
        // Ensure column is in tabbed presentation mode. An explicit request for
        // a new tab keeps the bar visible while the app opens its window.
        ws.columns[colIdx].presentationMode = .tabbed
        if ws.columns[colIdx].windowIds.count == 1 {
            ws.columns[colIdx].tabBarPinned = true
        }
        workspaces[activeDisplayId] = ws
        
        // Timeout to reset pending state if user or app cancels
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            if self?.pendingTabAdditionColumnId == columnId {
                self?.pendingTabAdditionColumnId = nil
                self?.pendingTabAdditionPID = nil
                self?.pendingTabAdditionBundleId = nil
            }
        }
        
        // Activate the application
        if let runningApp = NSRunningApplication(processIdentifier: pid) {
            runningApp.activate()
        }
        
        // Request a new window from the application (Cmd+N)
        spawnNewWindowForApp(pid: pid, bundleId: bundleId, appName: appName)
        
        diagnostics.log(category: "Tab", message: "Requested new tab window for \(appName) in column \(colIdx)")
    }

    public func addExistingWindowAsTab(_ windowId: WindowId, toColumnWithId columnId: UUID) {
        guard let ws = workspaces[activeDisplayId] else { return }
        guard let targetIdx = ws.columns.firstIndex(where: { $0.id == columnId }) else { return }
        
        // Already a tab in this group: just bring it to the front.
        if ws.columns[targetIdx].windowIds.contains(windowId) {
            activateTab(windowId: windowId, inColumnWithId: columnId)
            return
        }
        
        // Floating windows must rejoin the strip before they can be tabbed.
        if let window = registry.get(windowId: windowId), window.isFloating {
            registry.update(windowId: windowId) { $0.isFloating = false }
        }
        
        // Guarantee a window is never a member of two strips/spaces at once.
        removeWindowFromOtherStrips(windowId: windowId, exceptColumnId: columnId)
        
        guard var updated = workspaces[activeDisplayId],
              let colIdx = updated.columns.firstIndex(where: { $0.id == columnId }) else { return }
        updated.columns[colIdx].presentationMode = .tabbed
        if !updated.columns[colIdx].windowIds.contains(windowId) {
            updated.columns[colIdx].windowIds.append(windowId)
        }
        updated.columns[colIdx].activeWindowIndex = updated.columns[colIdx].windowIds.count - 1
        updated.focusedColumnIndex = colIdx
        registry.focusedId = windowId
        workspaces[activeDisplayId] = updated
        
        focusWindowProgrammatically(windowId)
        applyLayout(animated: true)
        schedulePersistenceSave()
        diagnostics.log(category: "Tab", message: "Added existing window \(windowId) to tab group in column \(colIdx)")
    }
    
    /// Removes a window from every strip column except the target, including
    /// columns on other displays and in other virtual workspaces.
    private func removeWindowFromOtherStrips(windowId: WindowId, exceptColumnId: UUID) {
        func prune(_ workspace: inout DisplayWorkspace) -> Bool {
            var changed = false
            for idx in workspace.columns.indices where workspace.columns[idx].id != exceptColumnId {
                if workspace.columns[idx].windowIds.contains(windowId) {
                    workspace.columns[idx].removeWindow(windowId)
                    workspace.columns[idx].normalizeTabPresentation()
                    changed = true
                }
            }
            guard changed else { return false }
            workspace.columns.removeAll { $0.windowIds.isEmpty }
            if let focused = workspace.focusedColumnIndex {
                workspace.focusedColumnIndex = workspace.columns.isEmpty ? nil : min(focused, workspace.columns.count - 1)
            }
            return true
        }
        
        for (displayId, var workspace) in workspaces {
            if prune(&workspace) {
                workspaces[displayId] = workspace
                updateTabBarOverlays(for: workspace)
            }
        }
        for (key, var workspace) in spaceWorkspaces where key != currentWorkspaceKey {
            if prune(&workspace) {
                spaceWorkspaces[key] = workspace
            }
        }
    }

    public func reorderTab(windowId: WindowId, inColumnWithId columnId: UUID, toIndex: Int) {
        guard var ws = workspaces[activeDisplayId] else { return }
        guard let colIdx = ws.columns.firstIndex(where: { $0.id == columnId }) else { return }
        
        guard ws.columns[colIdx].moveWindow(windowId, to: toIndex) else { return }
        workspaces[activeDisplayId] = ws
        applyLayout(animated: true)
        schedulePersistenceSave()
        diagnostics.log(category: "Tab", message: "Reordered tab \(windowId) in column \(colIdx) to index \(toIndex)")
    }

    public func detachTab(windowId: WindowId, fromColumnWithId columnId: UUID) {
        guard var ws = workspaces[activeDisplayId] else { return }
        guard let colIdx = ws.columns.firstIndex(where: { $0.id == columnId }) else { return }
        guard let newIdx = layoutEngine.detachTab(
            windowId: windowId,
            fromColumnIndex: colIdx,
            columns: &ws.columns
        ) else { return }
        
        ws.focusedColumnIndex = newIdx
        registry.focusedId = windowId
        
        workspaces[activeDisplayId] = ws
        focusWindowProgrammatically(windowId)
        applyLayout(animated: true)
        schedulePersistenceSave()
        diagnostics.log(category: "Tab", message: "Detached tab \(windowId) from column \(colIdx) into column \(newIdx)")
    }

    public func ungroupAllTabs(inColumnWithId columnId: UUID) {
        guard var ws = workspaces[activeDisplayId] else { return }
        guard let colIdx = ws.columns.firstIndex(where: { $0.id == columnId }) else { return }
        let newIndices = layoutEngine.ungroupAllTabs(at: colIdx, columns: &ws.columns)
        guard !newIndices.isEmpty else { return }
        
        if let focusedId = registry.focusedId,
           let focusedIndex = ws.columns.firstIndex(where: { $0.windowIds.contains(focusedId) }) {
            ws.focusedColumnIndex = focusedIndex
        } else {
            ws.focusedColumnIndex = newIndices.first
        }
        workspaces[activeDisplayId] = ws
        applyLayout(animated: true)
        schedulePersistenceSave()
        diagnostics.log(category: "Tab", message: "Ungrouped all tabs in column \(colIdx)")
    }

    public func togglePinTabBar(forColumnWithId columnId: UUID) {
        guard var ws = workspaces[activeDisplayId] else { return }
        guard let colIdx = ws.columns.firstIndex(where: { $0.id == columnId }) else { return }
        
        if ws.columns[colIdx].presentationMode == .tabbed {
            ws.columns[colIdx].tabBarPinned.toggle()
            ws.columns[colIdx].normalizeTabPresentation()
        } else {
            // Pinning a normal column explicitly opts it into tabbed presentation.
            ws.columns[colIdx].presentationMode = .tabbed
            ws.columns[colIdx].tabBarPinned = true
        }
        
        workspaces[activeDisplayId] = ws
        applyLayout(animated: true)
        schedulePersistenceSave()
        diagnostics.log(category: "Tab", message: "Toggled tab bar pin to \(ws.columns[colIdx].tabBarPinned) for column \(colIdx)")
    }

    public func cycleTabInFocusedColumn(forward: Bool) {
        guard let ws = workspaces[activeDisplayId],
              let current = ws.focusedColumnIndex,
              current >= 0, current < ws.columns.count else { return }
        let col = ws.columns[current]
        guard col.presentationMode == .tabbed, col.windowIds.count > 1 else { return }
        let count = col.windowIds.count
        var nextIdx = col.activeWindowIndex + (forward ? 1 : -1)
        if nextIdx < 0 { nextIdx = count - 1 }
        if nextIdx >= count { nextIdx = 0 }
        if nextIdx != col.activeWindowIndex {
            TabMotionProfile.current.haptic(.alignment)
        }
        activateTab(windowId: col.windowIds[nextIdx], inColumnWithId: col.id)
    }
    
    // MARK: - Focused Tab Commands (shortcuts & menu)
    
    public func addTabToFocusedColumn() {
        guard var ws = workspaces[activeDisplayId],
              let current = ws.focusedColumnIndex,
              current >= 0, current < ws.columns.count else { return }
        // Asking for a new tab is an explicit request to keep the bar visible.
        ws.columns[current].presentationMode = .tabbed
        if ws.columns[current].windowIds.count == 1 {
            ws.columns[current].tabBarPinned = true
        }
        workspaces[activeDisplayId] = ws
        addNewTab(toColumnWithId: ws.columns[current].id)
    }
    
    public func closeActiveTab() {
        guard let ws = workspaces[activeDisplayId],
              let current = ws.focusedColumnIndex,
              current >= 0, current < ws.columns.count,
              let activeId = ws.columns[current].activeWindowId else { return }
        if ws.columns[current].isLocked(activeId) {
            diagnostics.log(category: "Tab", message: "Prevented closing locked tab \(activeId)")
            return
        }
        closeTab(windowId: activeId, inColumnWithId: ws.columns[current].id)
    }
    
    public func detachActiveTab() {
        guard let ws = workspaces[activeDisplayId],
              let current = ws.focusedColumnIndex,
              current >= 0, current < ws.columns.count,
              ws.columns[current].presentationMode == .tabbed,
              ws.columns[current].windowIds.count > 1,
              let activeId = ws.columns[current].activeWindowId else { return }
        detachTab(windowId: activeId, fromColumnWithId: ws.columns[current].id)
    }
    
    public func ungroupFocusedTabGroup() {
        guard let ws = workspaces[activeDisplayId],
              let current = ws.focusedColumnIndex,
              current >= 0, current < ws.columns.count else { return }
        ungroupAllTabs(inColumnWithId: ws.columns[current].id)
    }
    
    public func toggleActiveTabBarPin() {
        guard let ws = workspaces[activeDisplayId],
              let current = ws.focusedColumnIndex,
              current >= 0, current < ws.columns.count else { return }
        togglePinTabBar(forColumnWithId: ws.columns[current].id)
    }

    // MARK: - Advanced Multi-Window Tab Grouping & Group Controls
    
    public func combineWindow(_ windowId: WindowId, intoColumnWithId columnId: UUID) {
        guard let ws = workspaces[activeDisplayId] else { return }
        guard let targetIdx = ws.columns.firstIndex(where: { $0.id == columnId }) else { return }
        
        // Already a tab in this group
        if ws.columns[targetIdx].windowIds.contains(windowId) {
            activateTab(windowId: windowId, inColumnWithId: columnId)
            return
        }
        
        // Floating windows must rejoin the strip
        if let window = registry.get(windowId: windowId), window.isFloating {
            registry.update(windowId: windowId) { $0.isFloating = false }
        }
        
        removeWindowFromOtherStrips(windowId: windowId, exceptColumnId: columnId)
        
        guard var updated = workspaces[activeDisplayId],
              let colIdx = updated.columns.firstIndex(where: { $0.id == columnId }) else { return }
        
        updated.columns[colIdx].presentationMode = .tabbed
        if !updated.columns[colIdx].windowIds.contains(windowId) {
            updated.columns[colIdx].windowIds.append(windowId)
        }
        updated.columns[colIdx].activeWindowIndex = updated.columns[colIdx].windowIds.count - 1
        updated.focusedColumnIndex = colIdx
        registry.focusedId = windowId
        workspaces[activeDisplayId] = updated
        
        TabMotionProfile.current.haptic(.alignment)
        focusWindowProgrammatically(windowId)
        applyLayout(animated: settings.enableTransitions)
        schedulePersistenceSave()
        diagnostics.log(category: "Tab", message: "Combined window \(windowId) into tab group in column \(colIdx)")
    }
    
    public func moveTabBetweenColumns(windowId: WindowId, fromColumnId: UUID, toColumnId: UUID, toIndex: Int? = nil) {
        guard var ws = workspaces[activeDisplayId] else { return }
        guard let fromColIdx = ws.columns.firstIndex(where: { $0.id == fromColumnId }),
              let toColIdx = ws.columns.firstIndex(where: { $0.id == toColumnId }) else { return }
        
        layoutEngine.moveTabBetweenGroups(
            windowId: windowId,
            fromColumnIndex: fromColIdx,
            toColumnIndex: toColIdx,
            toIndex: toIndex,
            columns: &ws.columns
        )
        
        if let updatedToIdx = ws.columns.firstIndex(where: { $0.id == toColumnId }) {
            ws.focusedColumnIndex = updatedToIdx
            registry.focusedId = windowId
            focusWindowProgrammatically(windowId)
        }
        
        workspaces[activeDisplayId] = ws
        TabMotionProfile.current.haptic(.alignment)
        applyLayout(animated: settings.enableTransitions)
        schedulePersistenceSave()
        diagnostics.log(category: "Tab", message: "Moved tab \(windowId) from column \(fromColumnId) to column \(toColumnId)")
    }
    
    public func closeOtherTabs(windowId: WindowId, inColumnWithId columnId: UUID) {
        guard var ws = workspaces[activeDisplayId] else { return }
        guard let colIdx = ws.columns.firstIndex(where: { $0.id == columnId }) else { return }
        
        let removedIds = layoutEngine.closeOtherTabsInGroup(windowId: windowId, at: colIdx, columns: &ws.columns)
        for rId in removedIds {
            if let ax = registry.getAXElement(windowId: rId) {
                controller.close(element: ax)
            }
        }
        
        ws.focusedColumnIndex = colIdx
        registry.focusedId = windowId
        focusWindowProgrammatically(windowId)
        workspaces[activeDisplayId] = ws
        applyLayout(animated: true)
        schedulePersistenceSave()
        diagnostics.log(category: "Tab", message: "Closed other tabs in column \(colIdx), kept \(windowId)")
    }
    
    public func closeTabsToRight(windowId: WindowId, inColumnWithId columnId: UUID) {
        guard var ws = workspaces[activeDisplayId] else { return }
        guard let colIdx = ws.columns.firstIndex(where: { $0.id == columnId }) else { return }
        
        let removedIds = layoutEngine.closeTabsToRightInGroup(windowId: windowId, at: colIdx, columns: &ws.columns)
        for rId in removedIds {
            if let ax = registry.getAXElement(windowId: rId) {
                controller.close(element: ax)
            }
        }
        
        ws.focusedColumnIndex = colIdx
        if let activeId = ws.columns[colIdx].activeWindowId {
            registry.focusedId = activeId
            focusWindowProgrammatically(activeId)
        }
        workspaces[activeDisplayId] = ws
        applyLayout(animated: true)
        schedulePersistenceSave()
        diagnostics.log(category: "Tab", message: "Closed tabs to right of \(windowId) in column \(colIdx)")
    }
    
    public func renameTab(windowId: WindowId, inColumnWithId columnId: UUID, newTitle: String) {
        guard var ws = workspaces[activeDisplayId] else { return }
        guard let colIdx = ws.columns.firstIndex(where: { $0.id == columnId }) else { return }
        
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        ws.columns[colIdx].setCustomTitle(trimmed.isEmpty ? nil : trimmed, for: windowId)
        workspaces[activeDisplayId] = ws
        updateTabBarOverlays(for: ws)
        schedulePersistenceSave()
        diagnostics.log(category: "Tab", message: "Renamed tab \(windowId) to '\(newTitle)' in column \(colIdx)")
    }
    
    public func resetTabTitle(windowId: WindowId, inColumnWithId columnId: UUID) {
        guard var ws = workspaces[activeDisplayId] else { return }
        guard let colIdx = ws.columns.firstIndex(where: { $0.id == columnId }) else { return }
        
        ws.columns[colIdx].setCustomTitle(nil, for: windowId)
        workspaces[activeDisplayId] = ws
        updateTabBarOverlays(for: ws)
        schedulePersistenceSave()
        diagnostics.log(category: "Tab", message: "Reset tab title for \(windowId) in column \(colIdx)")
    }
    
    public func toggleLockTab(windowId: WindowId, inColumnWithId columnId: UUID) {
        guard var ws = workspaces[activeDisplayId] else { return }
        guard let colIdx = ws.columns.firstIndex(where: { $0.id == columnId }) else { return }
        
        ws.columns[colIdx].toggleLock(windowId)
        workspaces[activeDisplayId] = ws
        updateTabBarOverlays(for: ws)
        schedulePersistenceSave()
        diagnostics.log(category: "Tab", message: "Toggled lock for tab \(windowId) in column \(colIdx)")
    }
    
    public func renameTabGroup(inColumnWithId columnId: UUID, newName: String?) {
        guard var ws = workspaces[activeDisplayId] else { return }
        guard let colIdx = ws.columns.firstIndex(where: { $0.id == columnId }) else { return }
        
        let trimmed = newName?.trimmingCharacters(in: .whitespacesAndNewlines)
        ws.columns[colIdx].customGroupName = (trimmed?.isEmpty == false) ? trimmed : nil
        workspaces[activeDisplayId] = ws
        updateTabBarOverlays(for: ws)
        schedulePersistenceSave()
        diagnostics.log(category: "Tab", message: "Renamed tab group in column \(colIdx) to '\(newName ?? "")'")
    }
    
    public func setTabGroupColor(inColumnWithId columnId: UUID, colorHex: String?) {
        guard var ws = workspaces[activeDisplayId] else { return }
        guard let colIdx = ws.columns.firstIndex(where: { $0.id == columnId }) else { return }
        
        ws.columns[colIdx].customColorHex = colorHex
        workspaces[activeDisplayId] = ws
        updateTabBarOverlays(for: ws)
        schedulePersistenceSave()
        diagnostics.log(category: "Tab", message: "Set tab group color to '\(colorHex ?? "nil")' in column \(colIdx)")
    }
    
    public func toggleCollapseTabGroup(inColumnWithId columnId: UUID) {
        guard var ws = workspaces[activeDisplayId] else { return }
        guard let colIdx = ws.columns.firstIndex(where: { $0.id == columnId }) else { return }
        
        ws.columns[colIdx].isCollapsed.toggle()
        workspaces[activeDisplayId] = ws
        applyLayout(animated: settings.enableTransitions)
        schedulePersistenceSave()
        diagnostics.log(category: "Tab", message: "Toggled collapse to \(ws.columns[colIdx].isCollapsed) in column \(colIdx)")
    }
    
    public func duplicateTab(windowId: WindowId, inColumnWithId columnId: UUID) {
        guard let managed = registry.get(windowId: windowId) else { return }
        pendingTabAdditionColumnId = columnId
        pendingTabAdditionPID = managed.pid
        pendingTabAdditionBundleId = managed.bundleIdentifier
        spawnNewWindowForApp(pid: managed.pid, bundleId: managed.bundleIdentifier, appName: managed.appName)
        diagnostics.log(category: "Tab", message: "Duplicating tab for \(managed.appName) into column \(columnId)")
    }
    
    public func selectTabByPosition(_ position: Int) {
        guard let ws = workspaces[activeDisplayId],
              let colIdx = ws.focusedColumnIndex,
              colIdx >= 0 && colIdx < ws.columns.count else { return }
        let col = ws.columns[colIdx]
        guard col.presentationMode == .tabbed else { return }
        let zeroIndex = position - 1
        guard zeroIndex >= 0 && zeroIndex < col.windowIds.count else { return }
        let targetId = col.windowIds[zeroIndex]
        activateTab(windowId: targetId, inColumnWithId: col.id)
    }
    
    public func selectLastTab() {
        guard let ws = workspaces[activeDisplayId],
              let colIdx = ws.focusedColumnIndex,
              colIdx >= 0 && colIdx < ws.columns.count else { return }
        let col = ws.columns[colIdx]
        guard col.presentationMode == .tabbed, let lastId = col.windowIds.last else { return }
        activateTab(windowId: lastId, inColumnWithId: col.id)
    }
    
    public func reorderActiveTabInFocusedColumn(direction: Int) {
        guard let ws = workspaces[activeDisplayId],
              let colIdx = ws.focusedColumnIndex,
              colIdx >= 0 && colIdx < ws.columns.count else { return }
        let col = ws.columns[colIdx]
        guard col.presentationMode == .tabbed, col.windowIds.count > 1 else { return }
        let currentIdx = col.activeWindowIndex
        let newIdx = currentIdx + direction
        guard newIdx >= 0 && newIdx < col.windowIds.count else { return }
        let winId = col.windowIds[currentIdx]
        reorderTab(windowId: winId, inColumnWithId: col.id, toIndex: newIdx)
    }
    
    public func focusNextWindow() {
        guard let ws = workspaces[activeDisplayId] else { return }
        focusManager.focusRight(columns: ws.columns, currentColumnIndex: ws.focusedColumnIndex, wrapAround: settings.wrapAroundFocus)
    }
    
    public func focusPreviousWindow() {
        guard let ws = workspaces[activeDisplayId] else { return }
        focusManager.focusLeft(columns: ws.columns, currentColumnIndex: ws.focusedColumnIndex, wrapAround: settings.wrapAroundFocus)
    }
    
    public func focusWindowAbove() {
        guard let ws = workspaces[activeDisplayId] else { return }
        focusManager.focusUp(columns: ws.columns, currentColumnIndex: ws.focusedColumnIndex, currentWindowId: registry.focusedId, wrapAround: settings.wrapAroundFocus)
    }
    
    public func focusWindowDown() {
        guard let ws = workspaces[activeDisplayId] else { return }
        focusManager.focusDown(columns: ws.columns, currentColumnIndex: ws.focusedColumnIndex, currentWindowId: registry.focusedId, wrapAround: settings.wrapAroundFocus)
    }
    
    public func moveColumnLeft() {
        guard var ws = workspaces[activeDisplayId], let current = ws.focusedColumnIndex else { return }
        ws.focusedColumnIndex = layoutEngine.moveColumn(at: current, direction: -1, columns: &ws.columns)
        workspaces[activeDisplayId] = ws
        applyLayout(animated: true)
        schedulePersistenceSave()
    }
    
    public func moveColumnRight() {
        guard var ws = workspaces[activeDisplayId], let current = ws.focusedColumnIndex else { return }
        ws.focusedColumnIndex = layoutEngine.moveColumn(at: current, direction: 1, columns: &ws.columns)
        workspaces[activeDisplayId] = ws
        applyLayout(animated: true)
        schedulePersistenceSave()
    }
    
    public func toggleFullWidthColumn() {
        guard var ws = workspaces[activeDisplayId], let current = ws.focusedColumnIndex else { return }
        layoutEngine.maximizeColumn(at: current, columns: &ws.columns, visibleWidth: ws.displayGeometry.visibleFrame.width)
        workspaces[activeDisplayId] = ws
        applyLayout(animated: true)
        schedulePersistenceSave()
    }
    
    public func closeActiveWindow() {
        if let focusedId = registry.focusedId, let ax = registry.getAXElement(windowId: focusedId) {
            controller.close(element: ax)
        }
    }
    
    public func cycleNextWindowOrTab() {
        cycleWindowOrTab(forward: true)
    }
    
    public func cyclePreviousWindowOrTab() {
        cycleWindowOrTab(forward: false)
    }
    
    private func cycleWindowOrTab(forward: Bool) {
        guard let ws = workspaces[activeDisplayId] else { return }
        if settings.cycleTabsBeforeColumns,
           let current = ws.focusedColumnIndex,
           current >= 0, current < ws.columns.count,
           ws.columns[current].presentationMode == .tabbed,
           ws.columns[current].windowIds.count > 1 {
            cycleTabInFocusedColumn(forward: forward)
        } else {
            focusManager.cycleWindows(columns: ws.columns, currentWindowId: registry.focusedId, forward: forward)
        }
    }
    
    public func spawnNewWindowForApp(pid: pid_t, bundleId: String, appName: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        // 0x2D is 'N' key
        if let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x2D, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.postToPid(pid)
        }
        if let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x2D, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.postToPid(pid)
        }
        
        // Fallback via AppleScript for maximum compatibility across macOS apps
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, self.pendingTabAdditionColumnId != nil else { return }
            let scriptSource = """
            tell application "System Events"
                tell process id \(pid)
                    keystroke "n" using command down
                end tell
            end tell
            """
            if let script = NSAppleScript(source: scriptSource) {
                var errorInfo: NSDictionary?
                script.executeAndReturnError(&errorInfo)
            }
        }
    }
    
    public func switchVirtualWorkspace(_ index: Int) {
        guard index >= 1 && index <= 9, index != activeWorkspaceIndex else { return }
        diagnostics.log(category: "Workspace", message: "Switching to virtual workspace \(index) on display \(activeDisplayId)")
        
        if let currentWs = workspaces[activeDisplayId] {
            spaceWorkspaces[currentWorkspaceKey] = currentWs
        }
        
        activeWorkspaceIndex = index
        let targetKey = currentWorkspaceKey
        
        if let existingWs = spaceWorkspaces[targetKey] {
            workspaces[activeDisplayId] = existingWs
            applyLayout(animated: false)
        } else if let display = displayManager.activeDisplays.first(where: { $0.id == activeDisplayId }) {
            let ws = DisplayWorkspace(displayGeometry: display)
            workspaces[activeDisplayId] = ws
            spaceWorkspaces[targetKey] = ws
            applyLayout(animated: false)
        }
    }
    
    public func moveFocusedWindowToVirtualWorkspace(_ index: Int) {
        guard index >= 1 && index <= 9, index != activeWorkspaceIndex else { return }
        guard var currentWs = workspaces[activeDisplayId],
              let colIdx = currentWs.focusedColumnIndex,
              colIdx < currentWs.columns.count else { return }
        
        let columnToMove = currentWs.columns.remove(at: colIdx)
        currentWs.focusedColumnIndex = currentWs.columns.isEmpty ? nil : min(colIdx, currentWs.columns.count - 1)
        workspaces[activeDisplayId] = currentWs
        
        let targetKey = WorkspaceKey(displayId: activeDisplayId, spaceId: activeSpaceId, workspaceIndex: index)
        var targetWs = spaceWorkspaces[targetKey] ?? {
            let display = currentWs.displayGeometry
            return DisplayWorkspace(displayGeometry: display)
        }()
        
        targetWs.columns.append(columnToMove)
        targetWs.focusedColumnIndex = targetWs.columns.count - 1
        spaceWorkspaces[targetKey] = targetWs
        
        applyLayout(animated: true)
        schedulePersistenceSave()
        diagnostics.log(category: "Workspace", message: "Moved column to virtual workspace \(index)")
    }
    
    public func activateWindow(_ winId: WindowId, inColumn colIdx: Int) {
        guard var ws = workspaces[activeDisplayId] else { return }
        ws.viewportOffset = activeViewportOffset(for: activeDisplayId)
        ws.focusedColumnIndex = colIdx
        if colIdx >= 0 && colIdx < ws.columns.count {
            if let wIdx = ws.columns[colIdx].windowIds.firstIndex(of: winId) {
                ws.columns[colIdx].activeWindowIndex = wIdx
            }
        }
        registry.focusedId = winId
        workspaces[activeDisplayId] = ws
        
        suppressFocusNotification(for: winId, duration: 0.60)
        focusWindowProgrammatically(winId)
        
        if settings.mouseFollowsFocus {
            if let frame = registry.get(windowId: winId)?.frame {
                InteractionManager.shared.warpMouseIfNeeded(to: frame)
            }
        }
        
        let isFreeform = settings.freeformScroll || !settings.snapToColumn
        let vis = ws.displayGeometry.visibleFrame
        let colOffsets = layoutEngine.columnStripOffsets(columns: ws.columns)
        if colIdx < colOffsets.count {
            let colStripOffset = colOffsets[colIdx]
            let colW = ws.columns[colIdx].width
            let screenX = vis.origin.x + colStripOffset - ws.viewportOffset
            let isVisible = (screenX + colW > vis.minX + 40) && (screenX < vis.maxX - 40)
            if isFreeform || isVisible {
                applyPhysicalWindowPositions(workspace: ws)
                return
            }
        }
        
        applyLayout(animated: true)
    }

    
    // MARK: - Layout Application
    
    public func applyLayout(animated: Bool = true) {
        guard var ws = workspaces[activeDisplayId] else { return }
        guard !settings.disabledDisplayIds.contains(ws.displayGeometry.id) else { return }
        ws.viewportOffset = activeViewportOffset(for: activeDisplayId)
        
        let isFreeform = settings.freeformScroll || !settings.snapToColumn
        let effectiveLayoutMode: LayoutMode = settings.layoutMode
        let bounds = refreshScrollBounds(for: ws)
        
        let computation = layoutEngine.computeLayout(
            columns: ws.columns,
            windows: registry.windowMap(),
            focusedColumnIndex: ws.focusedColumnIndex,
            visibleFrame: ws.displayGeometry.visibleFrame,
            viewportOffset: ws.viewportOffset,
            layoutMode: effectiveLayoutMode,
            centerMode: settings.centerMode,
            edgeMargins: settings.edgeMargins,
            gap: bounds.gap,
            isBuiltinDisplay: CGDisplayIsBuiltin(ws.displayGeometry.id) == 1,
            disablePaddingOnBuiltinDisplay: settings.disablePaddingOnBuiltinDisplay,
            smartWindowMargins: settings.smartWindowMargins,
            loopMode: bounds.loopEligible
        )
        
        // Update Minimap HUD (strictly throttled & conditioned on user setting)
        if settings.showMinimapHUD {
            let activeTitle = registry.focusedId.flatMap { registry.get(windowId: $0)?.title } ?? ""
            let screen = cachedScreen(for: activeDisplayId)
            MinimapHUDController.shared.update(
                columns: ws.columns,
                totalStripWidth: computation.totalStripWidth,
                viewportOffset: ws.viewportOffset,
                visibleWidth: ws.displayGeometry.visibleFrame.width,
                focusedIndex: ws.focusedColumnIndex,
                activeTitle: activeTitle,
                screen: screen
            )
        }
        
        let targetOffset = isFreeform ? ws.viewportOffset : computation.targetViewportOffset
        if animated && !scrollController.isMoving && !isFreeform && abs(targetOffset - ws.viewportOffset) > 8.0 {
            scrollController.scrollTo(
                target: targetOffset,
                maxOffset: bounds.maxOffset,
                duration: settings.animationDuration
            )
        } else {
            var updatedWs = ws
            updatedWs.viewportOffset = targetOffset
            workspaces[activeDisplayId] = updatedWs
            scrollController.setOffset(targetOffset, maxOffset: bounds.maxOffset)
            applyPhysicalWindowPositions(workspace: updatedWs)
        }
    }
    
    private var programmaticResetTimer: Timer?
    private var isPhysicalUpdateScheduled: Bool = false
    
    public func requestPhysicalWindowLayout() {
        guard !isPhysicalUpdateScheduled else { return }
        isPhysicalUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isPhysicalUpdateScheduled = false
            if let ws = self.workspaces[self.activeDisplayId] {
                self.applyPhysicalWindowPositions(workspace: ws)
            }
        }
    }
    
    private func applyPhysicalWindowPositions(workspace: DisplayWorkspace, resizingWindowId: WindowId? = nil) {
        guard !settings.disabledDisplayIds.contains(workspace.displayGeometry.id) else { return }
        let isMoving = scrollController.isMoving
        if resizingWindowId == nil {
            observer.isPerformingProgrammaticUpdate = true
            // Always invalidate any pending reset timer so it never fires mid-scroll!
            programmaticResetTimer?.invalidate()
            if !isMoving {
                programmaticResetTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.observer.isPerformingProgrammaticUpdate = false
                    }
                }
            }
        }
        
        // Pre-layout sync: ensure single-window columns reflect their verified physical width
        var effectiveWorkspace = workspace
        var columnsAdjusted = false
        for (idx, col) in effectiveWorkspace.columns.enumerated() where col.windowIds.count == 1 {
            let winId = col.windowIds[0]
            if let bundleId = NSRunningApplication(processIdentifier: winId.pid)?.bundleIdentifier,
               bundleId == "com.apple.Terminal" {
                continue
            }
            if let verifiedWidth = controller.frameState(for: winId)?.verifiedFrame?.width,
               verifiedWidth >= 200.0 {
                let diff = abs(verifiedWidth - col.width)
                if diff >= 1.0 && diff <= 300.0 {
                    effectiveWorkspace.columns[idx].width = verifiedWidth
                    columnsAdjusted = true
                }
            }
        }
        if columnsAdjusted {
            workspaces[workspace.displayGeometry.id] = effectiveWorkspace
        }
        
        let effectiveLayoutMode: LayoutMode = settings.layoutMode
        let isBuiltin = CGDisplayIsBuiltin(effectiveWorkspace.displayGeometry.id) != 0
        let bounds = refreshScrollBounds(for: effectiveWorkspace)
        let effectiveGap = bounds.gap
        let computation = layoutEngine.computeLayout(
            columns: effectiveWorkspace.columns,
            windows: registry.windowMap(),
            focusedColumnIndex: effectiveWorkspace.focusedColumnIndex,
            visibleFrame: effectiveWorkspace.displayGeometry.visibleFrame,
            viewportOffset: effectiveWorkspace.viewportOffset,
            layoutMode: effectiveLayoutMode,
            centerMode: settings.centerMode,
            edgeMargins: settings.edgeMargins,
            gap: effectiveGap,
            isBuiltinDisplay: isBuiltin,
            disablePaddingOnBuiltinDisplay: settings.disablePaddingOnBuiltinDisplay,
            smartWindowMargins: settings.smartWindowMargins,
            loopMode: bounds.loopEligible
        )
        
        let vis = effectiveWorkspace.displayGeometry.visibleFrame
        
        var placements: [WindowPlacement] = []
        placements.reserveCapacity(computation.targetFrames.count)
        
        // Order placements deterministically by column strip sequence so adjacent windows are always updated in strict sequence
        for col in effectiveWorkspace.columns {
            for winId in col.windowIds {
                guard let targetFrame = computation.targetFrames[winId],
                      let ax = registry.getAXElement(windowId: winId) else { continue }
                let cgId = registry.getCGWindowID(for: winId, ax: ax)
                placements.append(WindowPlacement(windowId: winId, axElement: ax, cgWindowID: UInt32(cgId), targetFrame: targetFrame))
                if !isMoving {
                    registry.update(windowId: winId) { $0.frame = targetFrame }
                }
            }
        }
        
        // Edge Sliver Clamping and CGS Z-Ordering (TileMyMac & ChainYourMac Parity)
        let writtenFrames = controller.applyStripFrames(
            placements: placements,
            visibleFrame: vis,
            focusedWindowId: registry.focusedId,
            isMoving: isMoving,
            resizingWindowId: resizingWindowId
        )
        
        // Scoped expected-frame registration: only register frames for windows where a genuine write was issued.
        // This eliminates dictionary churn and prevents feedback loops on stationary/resizing windows.
        for (winId, targetFrame) in writtenFrames {
            observer.recordExpectedFrame(targetFrame, for: winId, duration: 0.65)
        }
        
        // Tab Bar Overlay: floating Chrome-style strips aligned to their columns.
        // Contents only change when the layout settles; during motion only the
        // positions move, so skip the per-column candidate rebuild.
        updateTabBarOverlays(for: effectiveWorkspace, refreshContent: !isMoving)
        
        // Inactive Window Dimming
        if settings.dimUnfocusedWindows {
            DimmingOverlayController.shared.updateDimming(
                visibleFrame: vis,
                isFocusedFullscreen: false
            )
        } else {
            DimmingOverlayController.shared.hide()
        }
        
        // Focus Border Overlay: hide during active swipe/movement, show with smooth animated transition when settled
        if !isMoving {
            let focusedWindowFrame = registry.focusedId.flatMap { computation.targetFrames[$0] }
            FocusBorderOverlay.shared.updateFrame(focusedWindowFrame, visibleFrame: vis, animated: settings.enableTransitions)
        } else {
            FocusBorderOverlay.shared.hide()
        }
        
        // Mouse Follows Focus (only when settled)
        if !isMoving && settings.mouseFollowsFocus, let focusedId = registry.focusedId, let frame = computation.targetFrames[focusedId] {
            InteractionManager.shared.warpMouseIfNeeded(to: frame)
        }
    }
    
    /// Positions or hides the floating tab bars for one display. Keeping this in
    /// one place means title changes and focus changes can refresh tab content
    /// without re-tiling application windows.
    private func updateTabBarOverlays(for workspace: DisplayWorkspace, refreshContent: Bool = true) {
        let displayId = workspace.displayGeometry.id
        guard !settings.disabledDisplayIds.contains(displayId),
              workspace.columns.contains(where: { $0.showsTabBar }) else {
            TabBarOverlayController.shared.hideTabs(for: displayId)
            return
        }
        
        let vis = workspace.displayGeometry.visibleFrame
        let isBuiltin = CGDisplayIsBuiltin(displayId) == 1
        let totalWins = workspace.columns.reduce(0) { $0 + $1.windowIds.count }
        let collapseMargins = (settings.smartWindowMargins && totalWins <= 1) ||
            (settings.disablePaddingOnBuiltinDisplay && isBuiltin)
        let effectiveMargins = collapseMargins ? EdgeMargins.zero : settings.edgeMargins
        let effectiveGap = (settings.smartWindowMargins && totalWins <= 1) ? 0.0 : CGFloat(settings.windowGap)
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? vis.maxY
        let columnFrames = layoutEngine.columnScreenFrames(
            columns: workspace.columns,
            viewportOffset: workspace.viewportOffset,
            visibleFrame: vis,
            gap: effectiveGap,
            margins: effectiveMargins
        )
        
        TabBarOverlayController.shared.updateTabs(
            for: workspace.columns,
            windows: registry.windowMap(),
            visibleFrame: vis,
            displayId: displayId,
            primaryScreenHeight: primaryScreenHeight,
            columnFrames: columnFrames,
            refreshContent: refreshContent
        )
    }
    
    private var activelyResizingWindowId: WindowId?
    private var resizeSuppressionTimer: Timer?
    
    // MARK: - Frame Change & Scroll Handlers
    
    private func handleWindowFrameChanged(element: AXUIElement, pid: pid_t) {
        guard let winId = registry.findWindowId(matchingAXElement: element),
              let observedFrame = discovery.copyFrame(element) else { return }
        
        // Check current mouse state for active interactions (Amethyst architecture)
        switch mouseStateKeeper.state {
        case let .moving(activeId, _):
            if activeId != winId { return } // Lock out secondary neighbor notifications while dragging activeId
        case let .resizing(activeId, _):
            if activeId != winId { return } // Lock out secondary neighbor notifications while resizing activeId
        default:
            break
        }
        
        // Guard against programmatic echoes
        guard !observer.isSelfOriginatedFrameChange(windowId: winId, observedFrame: observedFrame) else {
            return
        }
        
        // Check mouse interaction state (Amethyst & Rectangle parity: only treat as manual window
        // manipulation if the mouse is actively dragging, or within dragRaceThreshold after release)
        switch mouseStateKeeper.state {
        case .dragging, .moving, .resizing:
            let expectedWidth = workspaces[activeDisplayId]?.columns.first(where: { $0.windowIds.contains(winId) })?.width ?? observedFrame.width
            let widthChanged = abs(observedFrame.width - expectedWidth) >= 2.0
            let currentWinFrame = registry.get(windowId: winId)?.frame ?? observedFrame
            if widthChanged {
                mouseStateKeeper.upgradeToResizing(windowId: winId, initialFrame: currentWinFrame)
            } else {
                mouseStateKeeper.upgradeToMoving(windowId: winId, initialFrame: currentWinFrame)
            }
            reconcileExternalFrameChange(windowId: winId, newFrame: observedFrame)
            return
            
        case let .doneDragging(atTime, _, _):
            let elapsed = Date().timeIntervalSince(atTime)
            if elapsed < mouseStateKeeper.dragRaceThresholdSeconds {
                let currentWinFrame = registry.get(windowId: winId)?.frame ?? observedFrame
                mouseStateKeeper.upgradeToMoving(windowId: winId, initialFrame: currentWinFrame)
                reconcileExternalFrameChange(windowId: winId, newFrame: observedFrame)
                return
            }
            fallthrough
            
        default:
            // Ordinary in-window interaction (clicking, text selection, typing, web browsing).
            // Do NOT engage magnetic snapping, column reflows, or compositor locks!
            registry.update(windowId: winId) { $0.frame = observedFrame }
            // If an app enforced a quantized/minimum width (e.g. Terminal character grid or AXMinSize),
            // sync the column width to the window's true physical width so adjacent edges remain flush without gaps or overlaps!
            if !scrollController.isMoving,
               activelyResizingWindowId == nil,
               activelyDraggingWindowId == nil,
               var ws = workspaces[activeDisplayId],
               let colIdx = ws.columns.firstIndex(where: { $0.windowIds.contains(winId) }),
               ws.columns[colIdx].windowIds.count == 1 {
                let widthDiff = abs(observedFrame.width - ws.columns[colIdx].width)
                if widthDiff >= 1.0 && widthDiff <= 300.0 && observedFrame.width >= 200.0 {
                    ws.columns[colIdx].width = observedFrame.width
                    workspaces[activeDisplayId] = ws
                    applyPhysicalWindowPositions(workspace: ws)
                }
            }
            return
        }
    }

    /// Synchronizes column width to an application's verified physical frame (e.g. Terminal character grid quantization)
    public func handleWindowFrameVerified(winId: WindowId, verifiedFrame: CGRect) {
        guard !scrollController.isMoving else { return }
        guard activelyResizingWindowId == nil, activelyDraggingWindowId == nil else { return }
        
        for (dispId, var ws) in workspaces {
            guard let colIdx = ws.columns.firstIndex(where: { $0.windowIds.contains(winId) }) else { continue }
            guard ws.columns[colIdx].windowIds.count == 1 else { continue }
            if let bundleId = NSRunningApplication(processIdentifier: winId.pid)?.bundleIdentifier,
               bundleId == "com.apple.Terminal" {
                continue
            }
            
            let col = ws.columns[colIdx]
            let widthDiff = abs(verifiedFrame.width - col.width)
            
            if widthDiff >= 1.0 && widthDiff <= 300.0 && verifiedFrame.width >= 200.0 {
                diagnostics.log(category: "Layout", message: "Syncing column \(colIdx) width from \(col.width) to verified width \(verifiedFrame.width) for window \(winId)")
                ws.columns[colIdx].width = verifiedFrame.width
                workspaces[dispId] = ws
                if dispId == activeDisplayId {
                    applyPhysicalWindowPositions(workspace: ws)
                }
                schedulePersistenceSave()
                return
            }
        }
    }
    
    public func reconcileExternalFrameChange(windowId: WindowId, newFrame: CGRect) {
        guard registry.get(windowId: windowId) != nil else { return }
        guard var ws = workspaces[activeDisplayId] else { return }
        guard let colIdx = ws.columns.firstIndex(where: { $0.windowIds.contains(windowId) }) else { return }
        
        let visibleFrame = ws.displayGeometry.visibleFrame
        // Ensure window is on-screen (not parked in negative offscreen space)
        guard newFrame.maxX > visibleFrame.minX + 30 && newFrame.minX < visibleFrame.maxX - 30 else {
            return
        }
        
        let minWidth: CGFloat = 220.0
        let stripOffsets = layoutEngine.columnStripOffsets(columns: ws.columns)
        let expectedColScreenX = visibleFrame.minX + settings.edgeMargins.left + stripOffsets[colIdx] - ws.viewportOffset
        let expectedWidth = ws.columns[colIdx].width
        
        let deltaWidth = newFrame.width - expectedWidth
        let deltaLeft = newFrame.minX - expectedColScreenX
        let widthChanged = abs(deltaWidth) >= 2.0
        
        let gap = settings.appsEdgeTogether ? 0.0 : CGFloat(settings.windowGap)
        
        // Drag to Reorder evaluation if only moved horizontally without width resize
        if !widthChanged {
            activelyDraggingWindowId = windowId
            dragSuppressionTimer?.invalidate()
            dragSuppressionTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.handleMouseUp()
                }
            }
            
            // Drag-to-Group: evaluate candidate column to combine windows into tabs (Section 4)
            var groupingTargetCol: WindowColumn? = nil
            var groupingTargetFrame: CGRect? = nil
            let draggedManaged = registry.get(windowId: windowId)
            let draggedCenter = CGPoint(x: newFrame.midX, y: newFrame.midY)
            
            for (idx, otherCol) in ws.columns.enumerated() {
                guard otherCol.id != ws.columns[colIdx].id else { continue }
                let otherColX = visibleFrame.minX + settings.edgeMargins.left + stripOffsets[idx] - ws.viewportOffset
                let otherColFrame = CGRect(
                    x: otherColX,
                    y: visibleFrame.minY + settings.edgeMargins.top,
                    width: otherCol.width,
                    height: max(100, visibleFrame.height - settings.edgeMargins.top - settings.edgeMargins.bottom)
                )
                
                guard otherColFrame.maxX > visibleFrame.minX + 40 && otherColFrame.minX < visibleFrame.maxX - 40 else { continue }
                
                let isCompatible: Bool = {
                    if settings.allowCrossAppGrouping { return true }
                    guard let dragged = draggedManaged else { return false }
                    return otherCol.windowIds.contains { otherWinId in
                        guard let otherWin = registry.get(windowId: otherWinId) else { return false }
                        return otherWin.bundleIdentifier == dragged.bundleIdentifier || otherWin.appName == dragged.appName
                    }
                }()
                
                guard isCompatible else { continue }
                
                let intersection = newFrame.intersection(otherColFrame)
                let substantialOverlap = !intersection.isNull && (intersection.width >= min(120, otherCol.width * 0.35))
                let centerContained = otherColFrame.contains(draggedCenter)
                
                if substantialOverlap || centerContained {
                    groupingTargetCol = otherCol
                    groupingTargetFrame = otherColFrame
                    break
                }
            }
            
            if let targetCol = groupingTargetCol, let targetFrame = groupingTargetFrame {
                activeGroupingDropTargetColumnId = targetCol.id
                let targetAppName = targetCol.windowIds.compactMap({ registry.get(windowId: $0)?.appName }).first ?? draggedManaged?.appName ?? "Tab Group"
                GroupingPreviewOverlayController.shared.show(
                    targetFrame: targetFrame,
                    targetDisplayId: activeDisplayId,
                    appName: targetAppName
                )
            } else {
                activeGroupingDropTargetColumnId = nil
                GroupingPreviewOverlayController.shared.hide()
            }
            

            
            // Magnetic Snapping and Adhesion: adjacent windows remain together,
            // and windows snap together when brought closer!
            if settings.edgeSnapping {
                var effectiveFrame = newFrame
                
                // 1. Distance-based magnetic snap when brought closer to candidate windows
                var otherWindows: [(id: WindowId, frame: CGRect)] = []
                for col in ws.columns {
                    for otherId in col.windowIds where otherId != windowId {
                        if let frame = registry.get(windowId: otherId)?.frame {
                            otherWindows.append((id: otherId, frame: frame))
                        }
                    }
                }
                
                if let snap = magneticEngine.evaluateMagneticSnap(
                    draggedWindowId: windowId,
                    draggedFrame: newFrame,
                    candidateWindows: otherWindows,
                    gap: gap,
                    visibleFrame: visibleFrame
                ) {
                    effectiveFrame = snap.snappedFrame
                    if let ax = registry.getAXElement(windowId: windowId) {
                        observer.recordExpectedFrame(effectiveFrame, for: windowId, duration: 0.65)
                        controller.setPositionAsync(element: ax, position: effectiveFrame.origin, size: effectiveFrame.size, windowId: windowId)
                    }
                }
                
                registry.update(windowId: windowId) { $0.frame = effectiveFrame }
                
                // 2. Chained adjacent neighbors: keep adjacent windows attached!
                let chained = magneticEngine.computeChainedNeighborFrames(
                    draggedWindowId: windowId,
                    draggedFrame: effectiveFrame,
                    columns: ws.columns,
                    windows: registry.windowMap(),
                    gap: gap,
                    visibleFrame: visibleFrame
                )
                
                if !chained.isEmpty {
                    for (neighborId, chainedFrame) in chained {
                        registry.update(windowId: neighborId) { $0.frame = chainedFrame }
                        if let ax = registry.getAXElement(windowId: neighborId) {
                            observer.recordExpectedFrame(chainedFrame, for: neighborId, duration: 0.65)
                            controller.setPositionAsync(element: ax, position: chainedFrame.origin, size: chainedFrame.size, windowId: neighborId)
                        }
                    }
                }
            } else {
                registry.update(windowId: windowId) { $0.frame = newFrame }
            }
            
            return
        }
        
        // User is actively resizing this window! Mark it to prevent neighbor feedback loops
        activelyResizingWindowId = windowId
        resizeSuppressionTimer?.invalidate()
        resizeSuppressionTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleMouseUp()
            }
        }
        
        let margins = settings.edgeMargins
        let baseOriginY = visibleFrame.minY + margins.top
        let usableHeight = max(100, visibleFrame.height - margins.top - margins.bottom)
        
        // Manual edge resize: automatically adjust adjacent window edge seamlessly
        if abs(deltaLeft) < 10.0 {
            // Right edge was dragged
            if colIdx + 1 < ws.columns.count {
                let combined = ws.columns[colIdx].width + ws.columns[colIdx + 1].width
                var clampedColWidth = min(max(minWidth, newFrame.width), combined - minWidth)
                if settings.edgeSnapping {
                    clampedColWidth = MagneticWindowEngine.snapSeamRatio(
                        combinedWidth: combined,
                        targetWidth: clampedColWidth,
                        snapRadius: 18.0
                    )
                }
                let adjustedNextWidth = combined - clampedColWidth
                
                ws.columns[colIdx].width = clampedColWidth
                ws.columns[colIdx + 1].width = adjustedNextWidth
                
                registry.update(windowId: windowId) {
                    $0.frame = newFrame
                    $0.preferredWidth = clampedColWidth
                }
                
                let nextColScreenX = expectedColScreenX + clampedColWidth + gap
                let nextFrame = CGRect(
                    x: round(nextColScreenX),
                    y: round(baseOriginY),
                    width: round(adjustedNextWidth),
                    height: round(usableHeight)
                )
                
                controller.withAtomicScreenUpdates {
                    for nextWinId in ws.columns[colIdx + 1].windowIds {
                        registry.update(windowId: nextWinId) {
                            $0.preferredWidth = adjustedNextWidth
                            $0.frame = nextFrame
                        }
                        if let ax = registry.getAXElement(windowId: nextWinId) {
                            observer.recordExpectedFrame(nextFrame, for: nextWinId, duration: 0.65)
                            controller.setFrame(element: ax, frame: nextFrame, windowId: nextWinId)
                        }
                    }
                }
            } else {
                let clampedColWidth = min(max(minWidth, newFrame.width), visibleFrame.width)
                ws.columns[colIdx].width = clampedColWidth
                registry.update(windowId: windowId) {
                    $0.frame = newFrame
                    $0.preferredWidth = clampedColWidth
                }
            }
        } else {
            // Left edge was dragged
            if colIdx > 0 {
                let combined = ws.columns[colIdx - 1].width + ws.columns[colIdx].width
                let prevColOriginX = expectedColScreenX - gap - ws.columns[colIdx - 1].width
                let targetPrevWidth = (newFrame.minX - gap) - prevColOriginX
                var clampedPrevWidth = min(max(minWidth, targetPrevWidth), combined - minWidth)
                if settings.edgeSnapping {
                    clampedPrevWidth = MagneticWindowEngine.snapSeamRatio(
                        combinedWidth: combined,
                        targetWidth: clampedPrevWidth,
                        snapRadius: 18.0
                    )
                }
                let adjustedColWidth = combined - clampedPrevWidth
                
                ws.columns[colIdx - 1].width = clampedPrevWidth
                ws.columns[colIdx].width = adjustedColWidth
                
                registry.update(windowId: windowId) {
                    $0.frame = newFrame
                    $0.preferredWidth = adjustedColWidth
                }
                
                let prevFrame = CGRect(
                    x: round(prevColOriginX),
                    y: round(baseOriginY),
                    width: round(clampedPrevWidth),
                    height: round(usableHeight)
                )
                
                controller.withAtomicScreenUpdates {
                    for prevWinId in ws.columns[colIdx - 1].windowIds {
                        registry.update(windowId: prevWinId) {
                            $0.preferredWidth = clampedPrevWidth
                            $0.frame = prevFrame
                        }
                        if let ax = registry.getAXElement(windowId: prevWinId) {
                            observer.recordExpectedFrame(prevFrame, for: prevWinId, duration: 0.65)
                            controller.setFrame(element: ax, frame: prevFrame, windowId: prevWinId)
                        }
                    }
                }
            } else {
                let clampedColWidth = min(max(minWidth, newFrame.width), visibleFrame.width)
                ws.columns[colIdx].width = clampedColWidth
                let pinnedFrame = CGRect(x: round(expectedColScreenX), y: round(baseOriginY), width: round(clampedColWidth), height: round(usableHeight))
                registry.update(windowId: windowId) {
                    $0.frame = pinnedFrame
                    $0.preferredWidth = clampedColWidth
                }
                if let ax = registry.getAXElement(windowId: windowId) {
                    controller.setFrameAsync(element: ax, frame: pinnedFrame, windowId: windowId)
                }
            }
        }
        
        ws.focusedColumnIndex = colIdx
        registry.focusedId = windowId
        workspaces[activeDisplayId] = ws
        
        controller.recordAppliedFrame(newFrame, for: windowId)
        
        // Update Minimap HUD (strictly throttled & conditioned on user setting)
        if settings.showMinimapHUD {
            let activeTitle = registry.get(windowId: windowId)?.title ?? ""
            let screen = cachedScreen(for: activeDisplayId)
            MinimapHUDController.shared.update(
                columns: ws.columns,
                totalStripWidth: layoutEngine.totalStripWidth(columns: ws.columns),
                viewportOffset: ws.viewportOffset,
                visibleWidth: ws.displayGeometry.visibleFrame.width,
                focusedIndex: colIdx,
                activeTitle: activeTitle,
                screen: screen
            )
        }
        
        schedulePersistenceSave()
        diagnostics.log(category: "Reconcile", message: "Seamlessly adjusted adjacent edge for column \(colIdx)")
    }
    
    public func applyScrollDelta(_ delta: CGFloat) {
        guard let ws = workspaces[activeDisplayId] else { return }
        let bounds = refreshScrollBounds(for: ws)
        let maxOffset = bounds.maxOffset
        let multiplier: CGFloat = settings.trackpadNaturalScroll ? -1.0 : 1.0
        let effectiveDelta = delta * multiplier
        scrollController.scrollBy(deltaX: effectiveDelta, maxOffset: maxOffset)
    }
    
    // MARK: - Space & Layout Persistence Management
    
    private var persistenceTimer: Timer?
    
    public func schedulePersistenceSave() {
        persistenceTimer?.invalidate()
        persistenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.saveCurrentLayout()
            }
        }
    }
    
    public func saveCurrentLayout() {
        if let currentWs = workspaces[activeDisplayId] {
            spaceWorkspaces[currentWorkspaceKey] = currentWs
        }
        
        var spacesDict: [String: SavedSpaceLayout] = [:]
        for (key, ws) in spaceWorkspaces {
            let saved = persistence.captureSpaceLayout(
                columns: ws.columns,
                windows: registry.windowMap(),
                focusedColumnIndex: ws.focusedColumnIndex,
                viewportOffset: ws.viewportOffset
            )
            spacesDict[key.storageKey] = saved
        }
        persistence.save(state: PersistedLayoutState(spaces: spacesDict))
    }
    
    public func switchSpace(to newSpaceId: UInt64, displayId: CGDirectDisplayID) {
        guard newSpaceId != activeSpaceId else { return }
        diagnostics.log(category: "Space", message: "Switching from Space \(activeSpaceId) to Space \(newSpaceId) on display \(displayId)")
        
        // Save state of current active strip
        if let currentWs = workspaces[activeDisplayId] {
            spaceWorkspaces[currentWorkspaceKey] = currentWs
        }
        
        activeSpaceId = newSpaceId
        let targetKey = currentWorkspaceKey
        
        if let existingWs = spaceWorkspaces[targetKey], !existingWs.columns.isEmpty {
            workspaces[activeDisplayId] = existingWs
            applyLayout(animated: false)
        } else if let saved = persistence.load()?.spaces[targetKey.storageKey],
                  !saved.columns.isEmpty,
                  let display = displayManager.activeDisplays.first(where: { $0.id == activeDisplayId }) {
            var ws = DisplayWorkspace(displayGeometry: display)
            let allWindows = registry.allWindows()
            let restored = persistence.restoreSpaceLayout(
                savedLayout: saved,
                availableWindows: allWindows,
                visibleWidth: display.visibleFrame.width
            )
            ws.columns = restored.restoredColumns
            ws.focusedColumnIndex = restored.savedFocusedIndex
            ws.viewportOffset = restored.savedViewportOffset
            workspaces[activeDisplayId] = ws
            spaceWorkspaces[targetKey] = ws
            applyLayout(animated: false)
        } else if let display = displayManager.activeDisplays.first(where: { $0.id == activeDisplayId }) {
            let ws = DisplayWorkspace(displayGeometry: display)
            workspaces[activeDisplayId] = ws
            spaceWorkspaces[targetKey] = ws
            applyLayout(animated: false)
            reconcileUnmanagedWindows()
        }
        
        if workspaces[activeDisplayId]?.columns.isEmpty == true {
            reconcileUnmanagedWindows()
        }
    }
    
    // MARK: - Multi-Monitor Handling

    
    private func handleDisplaysChanged(_ displays: [DisplayGeometry]) {
        guard !displays.isEmpty else {
            // Every display went away (clamshell/undock). Holding a CADisplayLink
            // to a removed panel is not safe; park motion until a display returns.
            scrollController.suspend()
            return
        }
        // NSScreen handles can survive a monitor swap in the cache; force a rebuild
        // before reattaching the display link.
        clearScreenCache()
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
        syncDisplayLinkWithActiveDisplay(force: true)
        applyLayout(animated: false)
    }
}

// MARK: - MouseStateKeeperDelegate (Amethyst Parity)

extension WorkspaceManager {
    public func mouseStateDidBeginDragging(windowId: WindowId) {
        activelyDraggingWindowId = windowId
    }
    
    public func mouseStateDidEndDragging(windowId: WindowId, initialFrame: CGRect) {
        activelyDraggingWindowId = nil
        dragSuppressionTimer?.invalidate()
        dragSuppressionTimer = nil
        
        GroupingPreviewOverlayController.shared.hide()
        
        if let targetColId = activeGroupingDropTargetColumnId {
            activeGroupingDropTargetColumnId = nil
            combineWindow(windowId, intoColumnWithId: targetColId)
            return
        }
        activeGroupingDropTargetColumnId = nil
        
        guard var ws = workspaces[activeDisplayId] else { return }
        
        // 1. Sync any column widths to physical frames
        for (idx, col) in ws.columns.enumerated() {
            if let firstWinId = col.windowIds.first, let win = registry.get(windowId: firstWinId) {
                if abs(win.frame.width - col.width) > 1.0 {
                    ws.columns[idx].width = win.frame.width
                }
            }
        }
        
        // 2. Settle drag displacement into viewportOffset so windows don't bounce back
        let finalFrame = registry.get(windowId: windowId)?.frame ?? initialFrame
        let deltaX = finalFrame.minX - initialFrame.minX
        let bounds = refreshScrollBounds(for: ws)
        
        if abs(deltaX) > 2.0 {
            ws.viewportOffset = max(0, min(bounds.maxOffset, ws.viewportOffset - deltaX))
        }
        
        workspaces[activeDisplayId] = ws
        applyLayout(animated: settings.enableTransitions)
        schedulePersistenceSave()
    }
    
    public func mouseStateDidEndResizing(windowId: WindowId, initialFrame: CGRect) {
        activelyResizingWindowId = nil
        resizeSuppressionTimer?.invalidate()
        resizeSuppressionTimer = nil
        
        handleMouseUp()
    }
}
