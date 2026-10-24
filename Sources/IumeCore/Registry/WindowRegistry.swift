import Foundation
import CoreGraphics
import ApplicationServices

/// Thread-safe in-memory store for managed window states.
public final class WindowRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [WindowId: ManagedWindow] = [:]
    private var axElementMap: [WindowId: AXUIElement] = [:]
    private var cgWindowIds: [WindowId: CGWindowID] = [:]
    private var originalPreTilingFrames: [WindowId: CGRect] = [:]
    private var focusedWindowId: WindowId?
    
    public init() {}
    
    // MARK: - Registrations
    
    public func register(window: ManagedWindow, axElement: AXUIElement? = nil) {
        lock.lock()
        defer { lock.unlock() }
        var updated = window
        if let orig = originalPreTilingFrames[window.id] {
            // Unconditionally preserve original pre-tiling frame across all re-arrangements
            updated.initialFrame = orig
        } else if let existing = windows[window.id] {
            updated.initialFrame = existing.initialFrame
            originalPreTilingFrames[window.id] = existing.initialFrame
        } else {
            originalPreTilingFrames[window.id] = window.initialFrame
        }
        windows[window.id] = updated
        if let ax = axElement {
            axElementMap[window.id] = ax
        }
    }
    
    public func unregister(windowId: WindowId) {
        lock.lock()
        defer { lock.unlock() }
        windows.removeValue(forKey: windowId)
        axElementMap.removeValue(forKey: windowId)
        cgWindowIds.removeValue(forKey: windowId)
        originalPreTilingFrames.removeValue(forKey: windowId)
        if focusedWindowId == windowId {
            focusedWindowId = nil
        }
    }
    
    public func update(windowId: WindowId, mutate: (inout ManagedWindow) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if var win = windows[windowId] {
            mutate(&win)
            windows[windowId] = win
        }
    }
    
    // MARK: - Queries
    
    public func get(windowId: WindowId) -> ManagedWindow? {
        lock.lock()
        defer { lock.unlock() }
        return windows[windowId]
    }
    
    public func getAXElement(windowId: WindowId) -> AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        return axElementMap[windowId]
    }
    
    public func getCGWindowID(for windowId: WindowId, ax: AXUIElement) -> CGWindowID {
        lock.lock()
        if let cached = cgWindowIds[windowId] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        
        let wid = IumeCore.getCGWindowID(for: ax) ?? 0
        if wid != 0 {
            lock.lock()
            cgWindowIds[windowId] = wid
            lock.unlock()
        }
        return wid
    }
    
    public func allWindows() -> [ManagedWindow] {
        lock.lock()
        defer { lock.unlock() }
        return Array(windows.values)
    }
    
    public func windowMap() -> [WindowId: ManagedWindow] {
        lock.lock()
        defer { lock.unlock() }
        return windows
    }
    
    public func windows(forPid pid: pid_t) -> [ManagedWindow] {
        lock.lock()
        defer { lock.unlock() }
        return windows.values.filter { $0.pid == pid }
    }
    
    public func findWindowId(matchingAXElement element: AXUIElement) -> WindowId? {
        lock.lock()
        defer { lock.unlock() }
        for (id, ax) in axElementMap {
            if CFEqual(ax, element) {
                return id
            }
        }
        return nil
    }
    
    public var focusedId: WindowId? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return focusedWindowId
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            focusedWindowId = newValue
            for (id, var win) in windows {
                let shouldFocus = (id == newValue)
                if win.isFocused != shouldFocus {
                    win.isFocused = shouldFocus
                    windows[id] = win
                }
            }
        }
    }
    
    public func removeAll(keepOriginalFrames: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        windows.removeAll()
        axElementMap.removeAll()
        cgWindowIds.removeAll()
        focusedWindowId = nil
        if !keepOriginalFrames {
            originalPreTilingFrames.removeAll()
        }
    }
}
