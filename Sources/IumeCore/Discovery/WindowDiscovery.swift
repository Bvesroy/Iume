import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

/// High-level management disposition determined by the hybrid window classifier.
public enum WindowManagementDisposition: Sendable, Equatable {
    case managedTile(fixedColumnSlot: Int?)
    case smartFloat
    case ignoredSystemElement
}

/// Compatibility classification enum for legacy callers and tests.
public enum WindowClassification: Sendable, Equatable {
    case tile
    case float
    case ignore
}

/// Hybrid CGWindowList + AXUIElement Window Classifier.
/// Uses kCGWindowLayer == 0 to automatically exclude Finder desktop window (layer -2147483623),
/// popups, and HUDs, while deterministically managing borderless terminals (Ghostty, iTerm2, Kitty)
/// and custom Electron windows. Also detects Smart Floating windows like Calculator.
public struct WindowClassifier {
    public static func classify(
        axWindow: AXUIElement,
        pid: pid_t,
        bundleId: String?,
        cgWindowLayer: Int,
        userRules: [AppWindowRule] = [],
        floatSmallWindows: Bool = true,
        smallWindowThreshold: Double = 0.35
    ) -> WindowManagementDisposition {
        // 1. Always float Iume's own settings/onboarding windows
        if let bundleId = bundleId, !bundleId.isEmpty, bundleId == Bundle.main.bundleIdentifier {
            return .smartFloat
        }
        if pid != 0 && pid == ProcessInfo.processInfo.processIdentifier {
            return .smartFloat
        }
        
        // 2. Exclude non-standard CGWindow layers (Finder Desktop sits at -2147483623; overlays/HUDs sit > 0)
        if cgWindowLayer != 0 {
            return .ignoredSystemElement
        }
        
        // 3. Check User Per-App Rules first
        if let bundleId, let rule = userRules.first(where: { $0.bundleIdentifier == bundleId }) {
            switch rule.policy {
            case .alwaysFloat: return .smartFloat
            case .alwaysTile: return .managedTile(fixedColumnSlot: nil)
            case .fixedSlot(let slot): return .managedTile(fixedColumnSlot: slot)
            }
        }
        
        // 4. Inspect AXRole & AXSubrole
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        guard role == (kAXWindowRole as String) else { return .ignoredSystemElement }
        
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = subroleRef as? String ?? ""
        
        if subrole == (kAXDialogSubrole as String) ||
           subrole == (kAXSystemDialogSubrole as String) ||
           subrole == (kAXFloatingWindowSubrole as String) {
            return .smartFloat
        }
        
        if subrole == "AXDesktopWindow" || subrole == "AXScrollArea" || subrole == "AXSystemMenu" {
            return .ignoredSystemElement
        }
        
        // 5. Smart Floating Detection: Check if window size is non-settable or fixed (e.g. Calculator)
        var isSizeSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(axWindow, kAXSizeAttribute as CFString, &isSizeSettable)
        if !isSizeSettable.boolValue {
            return .smartFloat
        }
        
        // Check if minSize == maxSize (Fixed-dimension utility window)
        if let minSize = copyCGSize(axWindow, attribute: "AXMinSize"),
           let maxSize = copyCGSize(axWindow, attribute: "AXMaxSize"),
           abs(maxSize.width - minSize.width) < 2.0 && abs(maxSize.height - minSize.height) < 2.0 {
            return .smartFloat
        }
        
        // 6. Size Heuristic: Float small windows (utility panels/quick inspectors < threshold)
        if let currentSize = copyCGSize(axWindow, attribute: kAXSizeAttribute as String),
           shouldFloatSmallWindow(size: currentSize, threshold: smallWindowThreshold, isEnabled: floatSmallWindows) {
            return .smartFloat
        }
        
        return .managedTile(fixedColumnSlot: nil)
    }
    
    public static func shouldFloatSmallWindow(size: CGSize, threshold: Double, isEnabled: Bool = true) -> Bool {
        guard isEnabled else { return false }
        guard size.width > 0 && size.height > 0 else { return false }
        // Threshold > 1.0 means absolute points (SettingsStore default 500), otherwise ratio (legacy 0.35)
        if threshold > 1.0 {
            let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
            let ratioThreshold: Double = 0.38
            let isSmallRatio = Double(size.width) < Double(screenSize.width) * ratioThreshold
                && Double(size.height) < Double(screenSize.height) * ratioThreshold
            let isSmallAbsolute = size.width <= CGFloat(threshold) && size.height <= CGFloat(threshold)
            let withinCap = size.width <= 520 && size.height <= 480
            return (isSmallRatio || isSmallAbsolute) && withinCap
        } else {
            let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
            return Double(size.width) < Double(screenSize.width) * threshold
                && Double(size.height) < Double(screenSize.height) * threshold
        }
    }

    /// Ratio + absolute variant with explicit display size for callers that already know the target display.
    public static func shouldFloatSmallWindow(
        size: CGSize,
        displaySize: CGSize,
        ratioThreshold: Double = 0.38,
        maxAbsoluteWidth: CGFloat = 520,
        maxAbsoluteHeight: CGFloat = 480,
        isEnabled: Bool = true
    ) -> Bool {
        guard isEnabled, size.width > 0, size.height > 0 else { return false }
        let isSmallRatio = Double(size.width) < Double(displaySize.width) * ratioThreshold
            && Double(size.height) < Double(displaySize.height) * ratioThreshold
        let isSmallAbsolute = size.width <= maxAbsoluteWidth && size.height <= maxAbsoluteHeight
        return isSmallRatio || isSmallAbsolute
    }
    
    public static func copyCGSize(_ element: AXUIElement, attribute: String) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let axVal = ref else { return nil }
        var size = CGSize.zero
        AXValueGetValue(axVal as! AXValue, .cgSize, &size)
        return size
    }
}

/// Discovers and validates accessible windows for running applications.
@MainActor
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
        
        // 0. Wake up lazy accessibility trees in Electron / Chromium / Qt apps without enabling slow animations
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        
        // 1. Standard: kAXWindowsAttribute
        var windowsRef: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let axWindows = windowsRef as? [AXUIElement] {
            for w in axWindows { addCandidate(w) }
        }
        
        // 2. Focused / Main window fallback (critical for Electron, VS Code, Terminal)
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
        var usedWindowNumbers = Set<UInt32>()
        var discovered: [(ManagedWindow, AXUIElement)] = []
        let userRules = SettingsStore.shared.appRules
        
        for (index, windowElement) in rawAxElements.enumerated() {
            AXUIElementSetMessagingTimeout(windowElement, 0.20)
            
            let frame = copyFrame(windowElement) ?? CGRect(x: 100, y: 100, width: 800, height: 600)
            let isMinimized = copyBoolAttribute(windowElement, attribute: kAXMinimizedAttribute as CFString) ?? false
            let isFullscreen = copyBoolAttribute(windowElement, attribute: "AXFullScreen" as CFString) ?? false
            
            // Native macOS fullscreen windows belong on their own dedicated Space, not in desktop strip
            if isFullscreen { continue }
            
            // Resolve layer from CGWindow list (prefer exact CGWindowID match first, then proximity fallback)
            let exactCGId = getCGWindowID(for: windowElement)
            let matchedCandidate = cgCandidates.first { cand in
                if let exactCGId, cand.windowNumber == exactCGId {
                    return true
                }
                return !usedWindowNumbers.contains(cand.windowNumber) &&
                    abs(cand.bounds.minX - frame.minX) < 45 &&
                    abs(cand.bounds.minY - frame.minY) < 45
            }
            let cgLayer = matchedCandidate?.layer ?? 0
            
            let disposition = WindowClassifier.classify(
                axWindow: windowElement,
                pid: pid,
                bundleId: bundleId,
                cgWindowLayer: cgLayer,
                userRules: userRules
            )
            guard disposition != .ignoredSystemElement else { continue }
            
            if let matched = matchedCandidate {
                usedWindowNumbers.insert(matched.windowNumber)
            }
            
            let rawId: UInt64 = {
                if let cgId = exactCGId {
                    return UInt64(cgId)
                }
                if let matched = matchedCandidate {
                    return UInt64(matched.windowNumber)
                }
                let hash = UInt64(CFHash(windowElement))
                return hash != 0 ? hash : UInt64(index + 1)
            }()
            
            let windowId = WindowId(pid: pid, rawId: rawId)
            let title = copyStringAttribute(windowElement, attribute: kAXTitleAttribute as CFString) ?? "\(appName) Window"
            let isFloating = (disposition == .smartFloat)
            
            let managed = ManagedWindow(
                id: windowId,
                pid: pid,
                bundleIdentifier: bundleId,
                appName: appName,
                title: title,
                frame: frame,
                initialFrame: frame,
                isFloating: isFloating,
                isPinned: false,
                isFocused: false,
                isMinimized: isMinimized,
                isFullscreen: isFullscreen
            )
            
            discovered.append((managed, windowElement))
        }
        
        return discovered
    }
    
    public func fetchCGWindowCatalog() -> [pid_t: [(windowNumber: UInt32, bounds: CGRect, layer: Int)]] {
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
    
    // MARK: - Validation & Classification
    
    public func classifyWindow(_ element: AXUIElement, bundleId: String? = nil) -> WindowClassification {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let resolvedBundleId = bundleId ?? (pid != 0 ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier : nil)
        let disposition = WindowClassifier.classify(
            axWindow: element,
            pid: pid,
            bundleId: resolvedBundleId,
            cgWindowLayer: 0,
            userRules: SettingsStore.shared.appRules
        )
        switch disposition {
        case .managedTile: return .tile
        case .smartFloat: return .float
        case .ignoredSystemElement: return .ignore
        }
    }
    
    public func isEligibleWindow(_ element: AXUIElement) -> Bool {
        return classifyWindow(element) != .ignore
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
