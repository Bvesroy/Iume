import AppKit
import CoreGraphics
import Combine

/// Manages interactive user behaviors: Drag-to-Reorder, No Focus Stealing heuristics,
/// Focus Follows Mouse, and Mouse Follows Focus.
@MainActor
public final class InteractionManager: ObservableObject {
    public static let shared = InteractionManager()
    
    public var isDragToReorderEnabled: Bool {
        SettingsStore.shared.dragToReorder
    }
    
    public var isFocusFollowsMouseEnabled: Bool {
        SettingsStore.shared.focusFollowsMouse
    }
    
    public var isMouseFollowsFocusEnabled: Bool {
        SettingsStore.shared.mouseFollowsFocus
    }
    
    private var lastUserInitiatedAppPID: pid_t?
    private var lastUserActionTimestamp: TimeInterval = 0
    public var activeDraggedWindowId: WindowId?
    
    private var mouseMonitor: Any?
    private var lastMouseFocusTimestamp: TimeInterval = 0
    public var onFocusFollowsMouseTarget: ((WindowId) -> Void)?
    private var cancellables = Set<AnyCancellable>()
    
    public init() {
        SettingsStore.shared.$focusFollowsMouse
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled {
                    self?.startFocusFollowsMouseMonitoringIfNeeded()
                } else {
                    self?.stopFocusFollowsMouseMonitoring()
                }
            }
            .store(in: &cancellables)
            
        if SettingsStore.shared.focusFollowsMouse {
            startFocusFollowsMouseMonitoringIfNeeded()
        }
    }
    
    public func startFocusFollowsMouseMonitoringIfNeeded() {
        if mouseMonitor == nil && isFocusFollowsMouseEnabled {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleMouseMoved(event)
                }
            }
        }
    }
    
    public func stopFocusFollowsMouseMonitoring() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }
    
    private func handleMouseMoved(_ event: NSEvent) {
        guard isFocusFollowsMouseEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // 120ms hysteresis debounce to avoid focus thrashing
        guard now - lastMouseFocusTimestamp > 0.12 else { return }
        
        let mousePoint = NSEvent.mouseLocation
        guard let primaryScreen = NSScreen.screens.first else { return }
        let cgMousePoint = CGPoint(x: mousePoint.x, y: primaryScreen.frame.height - mousePoint.y)
        
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        
        for entry in windowInfoList {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let winNum = entry[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }
            
            if bounds.contains(cgMousePoint) {
                let winId = WindowId(pid: pid, rawId: UInt64(winNum))
                lastMouseFocusTimestamp = now
                onFocusFollowsMouseTarget?(winId)
                break
            }
        }
    }
    
    /// Records explicit user app launches or shortcut switches so background popups never steal focus.
    public func markUserInitiatedActivation(pid: pid_t) {
        lastUserInitiatedAppPID = pid
        lastUserActionTimestamp = ProcessInfo.processInfo.systemUptime
    }
    
    /// Prevents focus stealing: returns true ONLY if the newly created window belongs to the currently
    /// focused app or an app explicitly launched/switched by the user within the last 2.0 seconds.
    public func shouldFocusNewlyCreatedWindow(appPID: pid_t, currentFocusedPID: pid_t?) -> Bool {
        if let current = currentFocusedPID, appPID == current {
            return true
        }
        if let lastPID = lastUserInitiatedAppPID, appPID == lastPID,
           (ProcessInfo.processInfo.systemUptime - lastUserActionTimestamp) < 10.0 {
            return true
        }
        return false
    }
    
    /// Warps the cursor to the center of the newly focused window when Mouse Follows Focus is enabled.
    public func warpMouseIfNeeded(to windowFrame: CGRect) {
        guard isMouseFollowsFocusEnabled else { return }
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        CGWarpMouseCursorPosition(center)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
    
    /// Evaluates Drag-to-Reorder on mouse-up after a user drags a window titlebar across the strip.
    public func resolveDragReorderDropIndex(
        draggedWindowId: WindowId,
        cursorScreenX: CGFloat,
        columnMidpointsScreenX: [CGFloat]
    ) -> Int? {
        guard isDragToReorderEnabled, !columnMidpointsScreenX.isEmpty else { return nil }
        var bestIndex = 0
        var minDistance = CGFloat.greatestFiniteMagnitude
        for (idx, midX) in columnMidpointsScreenX.enumerated() {
            let dist = abs(cursorScreenX - midX)
            if dist < minDistance {
                minDistance = dist
                bestIndex = idx
            }
        }
        return bestIndex
    }
}
