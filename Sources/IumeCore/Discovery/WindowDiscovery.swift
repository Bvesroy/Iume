import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

/// Discovers and validates accessible windows for running applications.
public final class WindowDiscovery {
    
    public init() {}
    
    // MARK: - Discovery
    
    /// Enumerates all eligible standard windows for a running application.
    public func discoverWindows(for pid: pid_t, bundleId: String, appName: String) -> [(ManagedWindow, AXUIElement)] {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        
        guard result == .success, let axWindows = windowsRef as? [AXUIElement] else {
            return []
        }
        
        var discovered: [(ManagedWindow, AXUIElement)] = []
        
        for (index, windowElement) in axWindows.enumerated() {
            guard isEligibleWindow(windowElement) else { continue }
            
            let title = copyStringAttribute(windowElement, attribute: kAXTitleAttribute as CFString) ?? "\(appName) Window"
            let frame = copyFrame(windowElement) ?? CGRect(x: 100, y: 100, width: 800, height: 600)
            let isMinimized = copyBoolAttribute(windowElement, attribute: kAXMinimizedAttribute as CFString) ?? false
            
            // Unique ID from PID + AXUIElement hash / index
            let rawId = UInt64(CFHash(windowElement))
            let windowId = WindowId(pid: pid, rawId: rawId != 0 ? rawId : UInt64(index + 1))
            
            let managed = ManagedWindow(
                id: windowId,
                pid: pid,
                bundleIdentifier: bundleId,
                appName: appName,
                title: title,
                frame: frame,
                isFloating: false,
                isPinned: false,
                isFocused: false,
                isMinimized: isMinimized,
                isFullscreen: false
            )
            
            discovered.append((managed, windowElement))
        }
        
        return discovered
    }
    
    // MARK: - Validation
    
    public func isEligibleWindow(_ element: AXUIElement) -> Bool {
        // Must have Window role
        guard let role = copyStringAttribute(element, attribute: kAXRoleAttribute as CFString),
              role == (kAXWindowRole as String) else {
            return false
        }
        
        // Exclude system sheets, menus, tooltips
        if let subrole = copyStringAttribute(element, attribute: kAXSubroleAttribute as CFString) {
            // Standard windows are the primary managed candidates
            if subrole == (kAXStandardWindowSubrole as String) {
                return true
            }
            // Dialogs, sheets, and system drawers should not be placed into strip columns
            if subrole == (kAXDialogSubrole as String) ||
               subrole == (kAXSystemDialogSubrole as String) ||
               subrole == "AXUnknown" {
                return false
            }
        }
        
        // If no subrole specified, check if it has a title or standard size
        if let size = copyFrame(element)?.size, size.width > 150 && size.height > 100 {
            return true
        }
        
        return false
    }
    
    // MARK: - AX Attribute Extraction Helpers
    
    public func copyStringAttribute(_ element: AXUIElement, attribute: CFString) -> String? {
        var valueRef: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard err == .success, let str = valueRef as? String else { return nil }
        return str
    }
    
    public func copyBoolAttribute(_ element: AXUIElement, attribute: CFString) -> Bool? {
        var valueRef: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard err == .success, let num = valueRef as? NSNumber else { return nil }
        return num.boolValue
    }
    
    public func copyFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: AnyObject?
        var sizeRef: AnyObject?
        
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef,
              let sizeVal = sizeRef else {
            return nil
        }
        
        var point = CGPoint.zero
        var size = CGSize.zero
        
        if CFGetTypeID(posVal) == AXValueGetTypeID() {
            AXValueGetValue(posVal as! AXValue, .cgPoint, &point)
        }
        if CFGetTypeID(sizeVal) == AXValueGetTypeID() {
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        }
        
        return CGRect(origin: point, size: size)
    }
}
