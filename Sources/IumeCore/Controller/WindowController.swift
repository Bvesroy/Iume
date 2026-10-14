import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

/// Low-level window manipulation operations using macOS Accessibility APIs.
public final class WindowController {
    
    public init() {}
    
    // Cache of last applied frames by window ID to eliminate redundant AX IPC overhead
    private var lastAppliedFrames: [WindowId: CGRect] = [:]
    
    public func clearFrameCache(for windowId: WindowId? = nil) {
        if let id = windowId {
            lastAppliedFrames.removeValue(forKey: id)
        } else {
            lastAppliedFrames.removeAll()
        }
    }
    
    // MARK: - Frame Manipulation
    
    @discardableResult
    public func setFrame(element: AXUIElement, frame: CGRect, windowId: WindowId? = nil) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.08)
        
        if let id = windowId, let prev = lastAppliedFrames[id] {
            let posDiff = abs(prev.origin.x - frame.origin.x) + abs(prev.origin.y - frame.origin.y)
            let sizeDiff = abs(prev.size.width - frame.size.width) + abs(prev.size.height - frame.size.height)
            
            // If frame hasn't visibly changed (< 0.5 pt), skip entirely (0 IPC calls)
            if posDiff < 0.5 && sizeDiff < 0.5 {
                return true
            }
            
            // If size is unchanged (typical for scrolling across the strip), ONLY set position once!
            if sizeDiff < 0.5 {
                let ok = setPosition(element: element, position: frame.origin)
                lastAppliedFrames[id] = frame
                return ok
            }
            
            // Size changed: set origin, then size, then origin to prevent clipping
            _ = setPosition(element: element, position: frame.origin)
            _ = setSize(element: element, size: frame.size)
            let finalPosOk = setPosition(element: element, position: frame.origin)
            
            lastAppliedFrames[id] = frame
            return finalPosOk
        } else {
            // First time applying frame: origin first, then size, then origin
            _ = setPosition(element: element, position: frame.origin)
            _ = setSize(element: element, size: frame.size)
            let posSuccess = setPosition(element: element, position: frame.origin)
            if let id = windowId {
                lastAppliedFrames[id] = frame
            }
            return posSuccess
        }
    }
    
    @discardableResult
    public func setPosition(element: AXUIElement, position: CGPoint) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.15)
        var point = position
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        let err = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        return err == .success
    }
    
    @discardableResult
    public func setSize(element: AXUIElement, size: CGSize) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.15)
        var sz = size
        guard let value = AXValueCreate(.cgSize, &sz) else { return false }
        let err = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        return err == .success
    }
    
    // MARK: - Window State
    
    public func focus(element: AXUIElement, pid: pid_t) {
        // Raise window and make it main
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        
        // Activate parent application
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
    }
    
    public func close(element: AXUIElement) {
        var closeButtonRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success,
           let btn = closeButtonRef {
            AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
        }
    }
    
    public func zoom(element: AXUIElement) {
        var zoomButtonRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXZoomButtonAttribute as CFString, &zoomButtonRef) == .success,
           let btn = zoomButtonRef {
            AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
        }
    }
    
    public func minimize(element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }
    
    public func restore(element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }
}
