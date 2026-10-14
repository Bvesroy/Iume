import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

/// Low-level window manipulation operations using macOS Accessibility APIs.
public final class WindowController {
    
    public init() {}
    
    // MARK: - Frame Manipulation
    
    @discardableResult
    public func setFrame(element: AXUIElement, frame: CGRect) -> Bool {
        // Set size first then position to avoid clamping against screen boundaries
        let sizeSuccess = setSize(element: element, size: frame.size)
        let posSuccess = setPosition(element: element, position: frame.origin)
        return sizeSuccess && posSuccess
    }
    
    @discardableResult
    public func setPosition(element: AXUIElement, position: CGPoint) -> Bool {
        var point = position
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        let err = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        return err == .success
    }
    
    @discardableResult
    public func setSize(element: AXUIElement, size: CGSize) -> Bool {
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
