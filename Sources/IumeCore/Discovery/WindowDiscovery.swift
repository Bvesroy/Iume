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
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        
        var rawAxElements: [AXUIElement] = []
        var seenHashes = Set<UInt>()
        
        func addCandidate(_ el: AXUIElement) {
            let hash = CFHash(el)
            if !seenHashes.contains(hash) {
                seenHashes.insert(hash)
                rawAxElements.append(el)
            }
        }
        
        // 1. Standard: kAXWindowsAttribute
        var windowsRef: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let axWindows = windowsRef as? [AXUIElement] {
            for w in axWindows { addCandidate(w) }
        }
        
        // 2. Focused / Main window fallback (critical for Electron, VS Code, Antigravity IDE, Terminal)
        var mainRef: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainRef) == .success,
           let mainWin = mainRef {
            addCandidate(mainWin as! AXUIElement)
        }
        
        var focusedRef: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
           let focWin = focusedRef {
            addCandidate(focWin as! AXUIElement)
        }
        
        // 3. Children fallback if nothing found
        if rawAxElements.isEmpty {
            var childrenRef: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children {
                    var roleRef: AnyObject?
                    if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
                       let role = roleRef as? String, role == (kAXWindowRole as String) {
                        addCandidate(child)
                    }
                }
            }
        }
        
        guard !rawAxElements.isEmpty else { return [] }
        
        let cgCandidates = fetchCGWindowCatalog()[pid] ?? []
        var usedWindowNumbers: Set<UInt32> = []
        var discovered: [(ManagedWindow, AXUIElement)] = []
        
        for (index, windowElement) in rawAxElements.enumerated() {
            AXUIElementSetMessagingTimeout(windowElement, 0.20)
            guard isEligibleWindow(windowElement) else { continue }
            
            let title = copyStringAttribute(windowElement, attribute: kAXTitleAttribute as CFString) ?? "\(appName) Window"
            let frame = copyFrame(windowElement) ?? CGRect(x: 100, y: 100, width: 800, height: 600)
            let isMinimized = copyBoolAttribute(windowElement, attribute: kAXMinimizedAttribute as CFString) ?? false
            let isFullscreen = copyBoolAttribute(windowElement, attribute: "AXFullScreen" as CFString) ?? false
            
            // Native macOS fullscreen windows belong on their own dedicated Space, not in desktop strip
            if isFullscreen { continue }
            
            // Match with public CGWindowListCopyWindowInfo by frame proximity to obtain deterministic CGWindowID
            let rawId: UInt64 = {
                if let matched = cgCandidates.first(where: { cand in
                    !usedWindowNumbers.contains(cand.windowNumber) &&
                    cand.layer == 0 &&
                    abs(cand.bounds.minX - frame.minX) < 35 &&
                    abs(cand.bounds.minY - frame.minY) < 35 &&
                    abs(cand.bounds.width - frame.width) < 35
                }) {
                    usedWindowNumbers.insert(matched.windowNumber)
                    return UInt64(matched.windowNumber)
                }
                let hash = UInt64(CFHash(windowElement))
                return hash != 0 ? hash : UInt64(index + 1)
            }()
            
            let windowId = WindowId(pid: pid, rawId: rawId)
            
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
                isFullscreen: isFullscreen
            )
            
            discovered.append((managed, windowElement))
        }
        
        return discovered
    }
    
    private func fetchCGWindowCatalog() -> [pid_t: [(windowNumber: UInt32, bounds: CGRect, layer: Int)]] {
        let options: CGWindowListOption = [.excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var map: [pid_t: [(windowNumber: UInt32, bounds: CGRect, layer: Int)]] = [:]
        for entry in infoList {
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let winNum = entry[kCGWindowNumber as String] as? UInt32,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }
            map[pid, default: []].append((winNum, bounds, layer))
        }
        return map
    }
    
    // MARK: - Validation
    
    public func isEligibleWindow(_ element: AXUIElement) -> Bool {
        // Must have Window role
        guard let role = copyStringAttribute(element, attribute: kAXRoleAttribute as CFString),
              role == (kAXWindowRole as String) else {
            return false
        }
        
        let subrole = copyStringAttribute(element, attribute: kAXSubroleAttribute as CFString)
        
        // Exclude system sheets, menus, tooltips, dialogs, desktop windows
        if let subrole = subrole {
            if subrole == (kAXDialogSubrole as String) ||
               subrole == (kAXSystemDialogSubrole as String) ||
               subrole == "AXDesktopWindow" ||
               subrole == "AXScrollArea" {
                return false
            }
        }
        
        var closeButton: AnyObject?
        let hasCloseButton = (AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButton) == .success && closeButton != nil)
        
        let title = copyStringAttribute(element, attribute: kAXTitleAttribute as CFString)
        let hasTitle = (title != nil && !title!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        
        // Standard window with controls or non-empty title
        if subrole == (kAXStandardWindowSubrole as String) {
            return hasCloseButton || hasTitle
        }
        
        // Many apps (Electron, new Safari/Chrome tabs, Terminal) temporarily show AXUnknown or empty subrole.
        if hasCloseButton {
            return true
        }
        
        // If it has a non-empty title and reasonable application window size
        if hasTitle {
            if let size = copyFrame(element)?.size, size.width >= 200 && size.height >= 150 {
                return true
            }
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
