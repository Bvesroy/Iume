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
    public var onWindowTitleChanged: ((AXUIElement, pid_t) -> Void)?
    
    /// Set while Iume is programmatically repositioning windows to avoid feedback loops.
    public var isPerformingProgrammaticUpdate: Bool = false
    
    private var expectedFrames: [WindowId: (frame: CGRect, expiresAt: CFAbsoluteTime)] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var observedWindowHashes: Set<UInt64> = []
    private var debounceTimer: Timer?
    private var lastFrameEventTime: CFAbsoluteTime = 0
    
    public init() {}
    
    // MARK: - Programmatic Intent Suppression
    
    public func recordExpectedFrame(_ frame: CGRect, for windowId: WindowId, duration: CFAbsoluteTime = 0.65) {
        let now = CFAbsoluteTimeGetCurrent()
        expectedFrames[windowId] = (frame, now + duration)
        if expectedFrames.count > 64 {
            expectedFrames = expectedFrames.filter { $0.value.expiresAt > now }
        }
    }
    
    public func isSelfOriginatedFrameChange(windowId: WindowId, observedFrame: CGRect) -> Bool {
        guard let expected = expectedFrames[windowId] else {
            // Any offscreen parked window position is self-originated by Iume
            return observedFrame.origin.x < 0
        }
        
        let dx = abs(expected.frame.origin.x - observedFrame.origin.x)
        let dy = abs(expected.frame.origin.y - observedFrame.origin.y)
        let dw = abs(expected.frame.size.width - observedFrame.size.width)
        let dh = abs(expected.frame.size.height - observedFrame.size.height)
        
        // Direct or near programmatic match (accommodate terminal character grid increments & titlebar differences)
        if dx <= 25.0 && dy <= 25.0 && dw <= 40.0 && dh <= 40.0 {
            return true
        }
        
        // Both parked offscreen in negative-X space
        if observedFrame.origin.x < 0 && expected.frame.origin.x < 0 {
            return true
        }
        
        // Within active programmatic suppression window, check if position matches within tolerance
        if CFAbsoluteTimeGetCurrent() <= expected.expiresAt {
            if dx <= 35.0 && dy <= 35.0 {
                return true
            }
        }
        
        return false
    }
    
    public func cleanup() {
        for (_, observer) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
        observedWindowHashes.removeAll()
        debounceTimer?.invalidate()
        debounceTimer = nil
        lastFrameEventTime = 0
    }
    
    // MARK: - App Observer Lifecycle
    
    public func observe(pid: pid_t, attemptsLeft: Int = 4, delayMs: Int = 100) {
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
        guard err == .success, let observer = observerRef else {
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                    self?.observe(pid: pid, attemptsLeft: attemptsLeft - 1, delayMs: delayMs * 2)
                }
            }
            return
        }
        
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        
        let notifications: [CFString] = [
            kAXWindowCreatedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString,
            kAXWindowMovedNotification as CFString,
            kAXWindowResizedNotification as CFString,
            kAXFocusedWindowChangedNotification as CFString,
            kAXMainWindowChangedNotification as CFString
        ]
        
        for notif in notifications {
            AXObserverAddNotification(observer, appElement, notif, selfPtr)
        }
        
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }
    
    public var onWindowMiniaturized: ((AXUIElement, pid_t) -> Void)?
    public var onWindowDeminiaturized: ((AXUIElement, pid_t) -> Void)?
    
    public func observeWindow(element: AXUIElement, pid: pid_t) {
        guard let observer = observers[pid] else { return }
        let hash = UInt64(CFHash(element))
        guard !observedWindowHashes.contains(hash) else { return }
        observedWindowHashes.insert(hash)
        
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let windowNotifs: [CFString] = [
            kAXUIElementDestroyedNotification as CFString,
            kAXWindowMiniaturizedNotification as CFString,
            kAXWindowDeminiaturizedNotification as CFString,
            kAXTitleChangedNotification as CFString
        ]
        for notif in windowNotifs {
            AXObserverAddNotification(observer, element, notif, selfPtr)
        }
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
        
        // Helper process PID normalization (e.g. Chrome / Slack helper renderer processes)
        var resolvedPid = rawPid
        var parentRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXParent" as CFString, &parentRef) == .success,
           let parent = parentRef {
            var parentPid: pid_t = 0
            if AXUIElementGetPid((parent as! AXUIElement), &parentPid) == .success && parentPid != 0 {
                resolvedPid = parentPid
            }
        }
        let capturedPid = resolvedPid
        
        if notification == (kAXWindowCreatedNotification as String) {
            onWindowCreated?(element, capturedPid)
            return
        }
        
        if notification == (kAXUIElementDestroyedNotification as String) {
            let hash = UInt64(CFHash(element))
            observedWindowHashes.remove(hash)
            onWindowDestroyed?(element, capturedPid)
            return
        }
        
        if notification == (kAXWindowMiniaturizedNotification as String) {
            onWindowMiniaturized?(element, capturedPid)
            return
        }
        
        if notification == (kAXWindowDeminiaturizedNotification as String) {
            onWindowDeminiaturized?(element, capturedPid)
            return
        }
        
        if notification == (kAXTitleChangedNotification as String) {
            onWindowTitleChanged?(element, capturedPid)
            return
        }
        
        if notification == (kAXFocusedWindowChangedNotification as String) ||
           notification == (kAXMainWindowChangedNotification as String) {
            guard !isPerformingProgrammaticUpdate else { return }
            onFocusedWindowChanged?(element, capturedPid)
            return
        }
        
        // Suppress programmatic updates from triggering re-layouts
        if isPerformingProgrammaticUpdate {
            return
        }
        
        // Responsive live move/resize tracking with rate-limited dispatch (~40-50 FPS)
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastFrameEventTime
        let capturedBox = elementBox
        let capturedNotification = notification
        
        if elapsed >= 0.025 {
            debounceTimer?.invalidate()
            debounceTimer = nil
            dispatchFrameNotification(notification: capturedNotification, element: capturedBox.element, pid: capturedPid)
        } else {
            debounceTimer?.invalidate()
            debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.025 - elapsed, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.dispatchFrameNotification(notification: capturedNotification, element: capturedBox.element, pid: capturedPid)
                }
            }
        }
    }
    
    private func dispatchFrameNotification(notification: String, element: AXUIElement, pid: pid_t) {
        guard !isPerformingProgrammaticUpdate else { return }
        lastFrameEventTime = CFAbsoluteTimeGetCurrent()
        if notification == (kAXWindowMovedNotification as String) {
            onWindowMoved?(element, pid)
        } else if notification == (kAXWindowResizedNotification as String) {
            onWindowResized?(element, pid)
        }
    }
}
