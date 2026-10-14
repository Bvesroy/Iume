import Foundation
import CoreGraphics
@preconcurrency import ApplicationServices
import AppKit

/// A thread-safe box for AXUIElement references.
public struct AXElementBox: @unchecked Sendable {
    public let element: AXUIElement
    public init(_ element: AXUIElement) {
        self.element = element
    }
}

/// Event listener for accessibility window updates with debounce and loop-prevention.
@MainActor
public final class WindowObserver {
    
    public var onWindowCreated: ((AXUIElement, pid_t) -> Void)?
    public var onWindowDestroyed: ((AXUIElement, pid_t) -> Void)?
    public var onWindowMoved: ((AXUIElement, pid_t) -> Void)?
    public var onWindowResized: ((AXUIElement, pid_t) -> Void)?
    public var onFocusedWindowChanged: ((AXUIElement, pid_t) -> Void)?
    
    /// Set while Iume is programmatically repositioning windows to avoid feedback loops.
    public var isPerformingProgrammaticUpdate: Bool = false
    
    private var expectedFrames: [WindowId: (frame: CGRect, expiresAt: CFAbsoluteTime)] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var debounceTimer: Timer?
    
    public init() {}
    
    // MARK: - Programmatic Intent Suppression
    
    public func recordExpectedFrame(_ frame: CGRect, for windowId: WindowId, duration: CFAbsoluteTime = 0.35) {
        expectedFrames[windowId] = (frame, CFAbsoluteTimeGetCurrent() + duration)
    }
    
    public func isSelfOriginatedFrameChange(windowId: WindowId, observedFrame: CGRect) -> Bool {
        guard let expected = expectedFrames[windowId] else { return false }
        guard CFAbsoluteTimeGetCurrent() <= expected.expiresAt else { return false }
        let dx = abs(expected.frame.origin.x - observedFrame.origin.x)
        let dy = abs(expected.frame.origin.y - observedFrame.origin.y)
        let dw = abs(expected.frame.size.width - observedFrame.size.width)
        let dh = abs(expected.frame.size.height - observedFrame.size.height)
        return dx <= 5.0 && dy <= 5.0 && dw <= 5.0 && dh <= 5.0
    }
    
    public func cleanup() {
        for (_, observer) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
        debounceTimer?.invalidate()
        debounceTimer = nil
    }
    
    // MARK: - App Observer Lifecycle
    
    public func observe(pid: pid_t) {
        guard observers[pid] == nil else { return }
        
        var observerRef: AXObserver?
        let callback: AXObserverCallback = { observer, element, notification, refcon in
            guard let refcon = refcon else { return }
            let selfPtr = Unmanaged<WindowObserver>.fromOpaque(refcon).takeUnretainedValue()
            let notifString = notification as String
            let elementBox = AXElementBox(element)
            
            DispatchQueue.main.async {
                selfPtr.handleNotification(notifString, elementBox: elementBox)
            }
        }
        
        let err = AXObserverCreate(pid, callback, &observerRef)
        guard err == .success, let observer = observerRef else { return }
        
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)
        
        let notifications: [CFString] = [
            kAXWindowCreatedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString,
            kAXWindowMovedNotification as CFString,
            kAXWindowResizedNotification as CFString,
            kAXFocusedWindowChangedNotification as CFString
        ]
        
        for notif in notifications {
            AXObserverAddNotification(observer, appElement, notif, selfPtr)
        }
        
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }
    
    public func unobserve(pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
    
    // MARK: - Notification Handling
    
    private func handleNotification(_ notification: String, elementBox: AXElementBox) {
        let element = elementBox.element
        var rawPid: pid_t = 0
        AXUIElementGetPid(element, &rawPid)
        let capturedPid = rawPid
        
        if notification == (kAXWindowCreatedNotification as String) {
            onWindowCreated?(element, capturedPid)
            return
        }
        
        if notification == (kAXUIElementDestroyedNotification as String) {
            onWindowDestroyed?(element, capturedPid)
            return
        }
        
        if notification == (kAXFocusedWindowChangedNotification as String) {
            onFocusedWindowChanged?(element, capturedPid)
            return
        }
        
        // Suppress programmatic updates from triggering re-layouts
        if isPerformingProgrammaticUpdate {
            return
        }
        
        // Debounce move/resize events
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, !self.isPerformingProgrammaticUpdate else { return }
                if notification == (kAXWindowMovedNotification as String) {
                    self.onWindowMoved?(elementBox.element, capturedPid)
                } else if notification == (kAXWindowResizedNotification as String) {
                    self.onWindowResized?(elementBox.element, capturedPid)
                }
            }
        }
    }
}
