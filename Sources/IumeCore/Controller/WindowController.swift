import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

@_silgen_name("_AXUIElementGetWindow")
public func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("GetProcessForPID") @discardableResult
public func GetProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

public let kCPSUserGenerated: UInt32 = 0x200

/// Safely retrieves the low-level CGWindowID directly from an AXUIElement via system SPI.
public func getCGWindowID(for element: AXUIElement) -> CGWindowID? {
    var wid: CGWindowID = 0
    let err = _AXUIElementGetWindow(element, &wid)
    return err == .success && wid != 0 ? wid : nil
}

/// Serial AX execution queue and context per process identifier to isolate slow apps.
final class AppAXContext: @unchecked Sendable {
    let pid: pid_t
    let queue: DispatchQueue
    let appElement: AXUIElement
    private var didDisableEnhancedUI = false
    
    init(pid: pid_t) {
        self.pid = pid
        self.appElement = AXUIElementCreateApplication(pid)
        self.queue = DispatchQueue(label: "com.iume.ax.\(pid)", qos: .userInteractive)
        AXUIElementSetMessagingTimeout(appElement, 0.04)
        disableEnhancedUIIfNeeded()
    }
    
    /// Rectangle/Amethyst optimization: If an app has AXEnhancedUserInterface = true,
    /// macOS animates programmatic moves and runs slow synchronous tree walks.
    /// Setting it to false eliminates stutter during continuous scrolling.
    func disableEnhancedUIIfNeeded() {
        var val: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, &val) == .success,
           let boolVal = val as? NSNumber, boolVal.boolValue {
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            didDisableEnhancedUI = true
        }
    }
    
    func restoreEnhancedUIIfNeeded() {
        if didDisableEnhancedUI {
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            didDisableEnhancedUI = false
        }
    }
}

/// Thread-safe latest-wins window writer that avoids queuing stale coordinate updates.
final class WindowWriter: @unchecked Sendable {
    private let ctx: AppAXContext
    private let ax: AXUIElement
    private var latestPosition: CGPoint?
    private var isDrainingPosition = false
    private var latestFrame: CGRect?
    private var isDrainingFrame = false
    private let lock = NSLock()
    
    init(ctx: AppAXContext, ax: AXUIElement) {
        self.ctx = ctx
        self.ax = ax
        AXUIElementSetMessagingTimeout(ax, 0.04)
    }
    
    func setPositionAsync(_ p: CGPoint) {
        lock.lock()
        latestPosition = p
        let shouldStart = !isDrainingPosition
        isDrainingPosition = true
        lock.unlock()
        
        guard shouldStart else { return }
        
        ctx.queue.async { [weak self] in
            guard let self = self else { return }
            while true {
                self.lock.lock()
                guard let next = self.latestPosition else {
                    self.isDrainingPosition = false
                    self.lock.unlock()
                    return
                }
                self.latestPosition = nil
                self.lock.unlock()
                
                var pt = next
                if let v = AXValueCreate(.cgPoint, &pt) {
                    AXUIElementSetAttributeValue(self.ax, kAXPositionAttribute as CFString, v)
                }
            }
        }
    }
    
    func setFrameAsync(_ frame: CGRect) {
        lock.lock()
        latestFrame = frame
        let shouldStart = !isDrainingFrame
        isDrainingFrame = true
        lock.unlock()
        
        guard shouldStart else { return }
        
        ctx.queue.async { [weak self] in
            guard let self = self else { return }
            while true {
                self.lock.lock()
                guard let next = self.latestFrame else {
                    self.isDrainingFrame = false
                    self.lock.unlock()
                    return
                }
                self.latestFrame = nil
                self.lock.unlock()
                
                var pt = CGPoint(x: round(next.origin.x), y: round(next.origin.y))
                var sz = CGSize(width: round(next.size.width), height: round(next.size.height))
                
                if let pv = AXValueCreate(.cgPoint, &pt) {
                    AXUIElementSetAttributeValue(self.ax, kAXPositionAttribute as CFString, pv)
                }
                if let sv = AXValueCreate(.cgSize, &sz) {
                    AXUIElementSetAttributeValue(self.ax, kAXSizeAttribute as CFString, sv)
                }
                if let pv = AXValueCreate(.cgPoint, &pt) {
                    AXUIElementSetAttributeValue(self.ax, kAXPositionAttribute as CFString, pv)
                }
            }
        }
    }
}

/// Low-level window manipulation operations using macOS Accessibility APIs.
/// Features per-app isolated serial queues, latest-wins coalescing, and non-blocking writes.
public final class WindowController: @unchecked Sendable {
    
    public init() {}
    
    // Configurable edge sliver (default 3pt wide, tucked at bottom corner) preventing WindowServer clamping loops
    public var sliverWidth: CGFloat = 3.0
    public var sliverHeight: CGFloat = 12.0
    
    // CGS Private APIs for Z-ordering
    private typealias CGSDefaultConnectionFunc = @convention(c) () -> UInt32
    private typealias CGSOrderWindowFunc = @convention(c) (UInt32, UInt32, Int32, UInt32) -> Int32
    private typealias CGSSetWindowAlphaFunc = @convention(c) (UInt32, UInt32, Float) -> Int32
    public static let kCGSOrderAbove: Int32 = 1
    public static let kCGSOrderBelow: Int32 = -1
    
    public static let cgsDefaultConnection: (@convention(c) () -> UInt32)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        guard let sym = dlsym(handle, "_CGSDefaultConnection") else { return nil }
        return unsafeBitCast(sym, to: CGSDefaultConnectionFunc.self)
    }()
    
    public static let cgsOrderWindow: (@convention(c) (UInt32, UInt32, Int32, UInt32) -> Int32)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        guard let sym = dlsym(handle, "CGSOrderWindow") else { return nil }
        return unsafeBitCast(sym, to: CGSOrderWindowFunc.self)
    }()
    
    public static let cgsSetWindowAlpha: (@convention(c) (UInt32, UInt32, Float) -> Int32)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        guard let sym = dlsym(handle, "CGSSetWindowAlpha") else { return nil }
        return unsafeBitCast(sym, to: CGSSetWindowAlphaFunc.self)
    }()
    
    private typealias CGSDisableUpdateFunc = @convention(c) (UInt32) -> Int32
    private typealias CGSReenableUpdateFunc = @convention(c) (UInt32) -> Int32

    public static let cgsDisableUpdate: (@convention(c) (UInt32) -> Int32)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        guard let sym = dlsym(handle, "CGSDisableUpdate") ?? dlsym(handle, "SLSDisableUpdate") else { return nil }
        return unsafeBitCast(sym, to: CGSDisableUpdateFunc.self)
    }()
    
    public static let cgsReenableUpdate: (@convention(c) (UInt32) -> Int32)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        guard let sym = dlsym(handle, "CGSReenableUpdate") ?? dlsym(handle, "SLSReenableUpdate") else { return nil }
        return unsafeBitCast(sym, to: CGSReenableUpdateFunc.self)
    }()
    
    private typealias SLPSSetFrontProcessWithOptionsFunc = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError
    private typealias SLPSPostEventRecordToFunc = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    
    public static let slpsSetFrontProcessWithOptions: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        guard let sym = dlsym(handle, "_SLPSSetFrontProcessWithOptions") ?? dlsym(handle, "SLPSSetFrontProcessWithOptions") else { return nil }
        return unsafeBitCast(sym, to: SLPSSetFrontProcessWithOptionsFunc.self)
    }()
    
    public static let slpsPostEventRecordTo: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        guard let sym = dlsym(handle, "SLPSPostEventRecordTo") ?? dlsym(handle, "_SLPSPostEventRecordTo") else { return nil }
        return unsafeBitCast(sym, to: SLPSPostEventRecordToFunc.self)
    }()
    
    // Cache of last applied frames by window ID to eliminate redundant AX IPC overhead
    private var lastAppliedFrames: [WindowId: CGRect] = [:]
    private var appContexts: [pid_t: AppAXContext] = [:]
    private var windowWriters: [WindowId: WindowWriter] = [:]
    private var windowAlphas: [WindowId: Float] = [:]
    private var windowCGIDs: [WindowId: UInt32] = [:]
    private let lock = NSLock()
    
    public func recordAppliedFrame(_ frame: CGRect, for windowId: WindowId) {
        lock.lock()
        defer { lock.unlock() }
        lastAppliedFrames[windowId] = frame
    }
    
    private var pidsWithDisabledEnhancedUI = Set<pid_t>()
    
    public func ensureEnhancedUIDisabled(for pid: pid_t) {
        lock.lock()
        if pidsWithDisabledEnhancedUI.contains(pid) {
            lock.unlock()
            return
        }
        pidsWithDisabledEnhancedUI.insert(pid)
        lock.unlock()
        
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.02)
        var val: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, &val) == .success,
           let boolVal = val as? NSNumber, boolVal.boolValue {
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
    }
    
    /// Executes the provided closure within an atomic WindowServer update lock (CGSDisableUpdate / CGSReenableUpdate)
    /// to guarantee that all window frame mutations composite in the exact same physical display frame.
    @discardableResult
    public func withAtomicScreenUpdates<T>(_ body: () throws -> T) rethrows -> T {
        let cid = WindowController.cgsDefaultConnection?() ?? 0
        if cid != 0, let disable = WindowController.cgsDisableUpdate {
            _ = disable(cid)
        }
        defer {
            if cid != 0, let reenable = WindowController.cgsReenableUpdate {
                _ = reenable(cid)
            }
        }
        return try body()
    }
    
    public func applyStripFrames(
        placements: [WindowPlacement],
        visibleFrame: CGRect,
        focusedWindowId: WindowId?,
        isMoving: Bool,
        resizingWindowId: WindowId? = nil
    ) {
        let cid = WindowController.cgsDefaultConnection?() ?? 0
        var visibleWindowsOrdered: [WindowPlacement] = []
        var parkedWindows: [WindowPlacement] = []
        
        for placement in placements {
            ensureEnhancedUIDisabled(for: placement.windowId.pid)
            let rawRect = placement.targetFrame
            
            // If actively resizing this window with the mouse, avoid touching it
            if let resizingId = resizingWindowId, placement.windowId == resizingId {
                lock.lock()
                lastAppliedFrames[placement.windowId] = rawRect
                lock.unlock()
                continue
            }
            
            // A window is visible if its frame extends meaningfully beyond the edge peek slivers (12pt)
            let isSafelyVisible = rawRect.origin.x < (visibleFrame.maxX - 12.0) &&
                                  rawRect.maxX > (visibleFrame.minX + 12.0)
            if isSafelyVisible {
                visibleWindowsOrdered.append(placement)
            } else {
                parkedWindows.append(placement)
            }
            
            // Ensure window opacity is 1.0 for all managed strip windows
            if cid != 0 && placement.cgWindowID != 0, let alphaFunc = WindowController.cgsSetWindowAlpha {
                lock.lock()
                windowCGIDs[placement.windowId] = placement.cgWindowID
                if windowAlphas[placement.windowId] != 1.0 {
                    _ = alphaFunc(cid, placement.cgWindowID, 1.0)
                    windowAlphas[placement.windowId] = 1.0
                }
                lock.unlock()
            }
        }
        
        // 1. Repositioning for visible windows
        if isMoving {
            // In motion: non-blocking asynchronous position writes via per-app serial queues with latest-wins coalescing
            // DO NOT engage WindowServer atomic update freeze during live motion to prevent compositor stalls!
            for placement in visibleWindowsOrdered {
                let roundedOrigin = CGPoint(x: round(placement.targetFrame.origin.x), y: round(placement.targetFrame.origin.y))
                self.setPositionAsync(element: placement.axElement, position: roundedOrigin, size: placement.targetFrame.size, windowId: placement.windowId)
            }
        } else {
            // Settled pass: apply authoritative frames and synchronize batch updates if multiple windows composite together
            let applyVisibleSettled = {
                for placement in visibleWindowsOrdered {
                    let roundedOrigin = CGPoint(x: round(placement.targetFrame.origin.x), y: round(placement.targetFrame.origin.y))
                    let roundedFrame = CGRect(
                        x: roundedOrigin.x,
                        y: roundedOrigin.y,
                        width: round(placement.targetFrame.size.width),
                        height: round(placement.targetFrame.size.height)
                    )
                    self.lock.lock()
                    let prev = self.lastAppliedFrames[placement.windowId]
                    self.lock.unlock()
                    
                    let sizeDiff = prev.map { abs($0.width - roundedFrame.width) + abs($0.height - roundedFrame.height) } ?? 999
                    let posDiff = prev.map { abs($0.origin.x - roundedOrigin.x) + abs($0.origin.y - roundedOrigin.y) } ?? 999
                    
                    if sizeDiff > 0.5 {
                        self.setFrame(element: placement.axElement, frame: roundedFrame, windowId: placement.windowId)
                    } else if posDiff > 0.5 {
                        self.setPosition(element: placement.axElement, position: roundedOrigin, windowId: placement.windowId)
                    }
                }
            }
            
            if visibleWindowsOrdered.count > 1 {
                withAtomicScreenUpdates {
                    applyVisibleSettled()
                }
            } else {
                applyVisibleSettled()
            }
        }
        
        // 2. Offscreen windows: parked at left or right edge slivers (0 IPC overhead when stationary)
        for placement in parkedWindows {
            let roundedOrigin = CGPoint(x: round(placement.targetFrame.origin.x), y: round(placement.targetFrame.origin.y))
            lock.lock()
            let prev = lastAppliedFrames[placement.windowId]
            lock.unlock()
            
            if let prev = prev, abs(prev.origin.x - roundedOrigin.x) < 1.0 && abs(prev.origin.y - roundedOrigin.y) < 1.0 {
                // Already parked, 0 IPC calls!
            } else {
                setPositionAsync(element: placement.axElement, position: roundedOrigin, size: placement.targetFrame.size, windowId: placement.windowId)
            }
        }
        
        // 3. Enforce Z-order so parked slivers sit cleanly behind visible active windows
        if cid != 0 && (!parkedWindows.isEmpty || !visibleWindowsOrdered.isEmpty) {
            enforceStripZOrder(cid: cid, visible: visibleWindowsOrdered, parked: parkedWindows, focusedId: focusedWindowId)
        }
    }
    
    @inline(__always)
    public func applyStripFrames(
        placements: [WindowPlacement],
        visibleFrame: CGRect,
        focusedWindowId: WindowId?,
        isScrollingOnly: Bool,
        resizingWindowId: WindowId? = nil
    ) {
        applyStripFrames(
            placements: placements,
            visibleFrame: visibleFrame,
            focusedWindowId: focusedWindowId,
            isMoving: isScrollingOnly,
            resizingWindowId: resizingWindowId
        )
    }
    
    private struct ZOrderSignature: Equatable {
        let visibleIds: [WindowId]
        let parkedIds: [WindowId]
        let focusedId: WindowId?
    }
    private var lastZOrderSignature: ZOrderSignature?
    
    @discardableResult
    public func enforceStripZOrder(
        cid: UInt32,
        visible: [WindowPlacement],
        parked: [WindowPlacement],
        focusedId: WindowId?
    ) -> Bool {
        guard cid != 0 else { return false }
        guard !visible.isEmpty else { return false }
        guard let orderFunc = WindowController.cgsOrderWindow else { return false }
        
        let signature = ZOrderSignature(
            visibleIds: visible.map(\.windowId),
            parkedIds: parked.map(\.windowId),
            focusedId: focusedId
        )
        
        lock.lock()
        if lastZOrderSignature == signature {
            lock.unlock()
            return false
        }
        lastZOrderSignature = signature
        lock.unlock()
        
        guard let focused = visible.first(where: { $0.windowId == focusedId }) ?? visible.first else { return false }
        
        // Push non-focused visible strip columns strictly below focused window
        for item in visible where item.windowId != focused.windowId {
            _ = orderFunc(cid, item.cgWindowID, WindowController.kCGSOrderBelow, focused.cgWindowID)
        }
        
        // Push all parked offscreen slivers strictly BELOW the lowest visible column
        if let lowestVisible = visible.first {
            for parkedItem in parked {
                _ = orderFunc(cid, parkedItem.cgWindowID, WindowController.kCGSOrderBelow, lowestVisible.cgWindowID)
            }
        }
        
        return true
    }
    
    public func clearFrameCache(for windowId: WindowId? = nil) {
        lock.lock()
        defer { lock.unlock() }
        lastZOrderSignature = nil
        let cid = WindowController.cgsDefaultConnection?() ?? 0
        if let id = windowId {
            lastAppliedFrames.removeValue(forKey: id)
            windowWriters.removeValue(forKey: id)
            if cid != 0, let alphaFunc = WindowController.cgsSetWindowAlpha, let cgId = windowCGIDs[id] {
                _ = alphaFunc(cid, cgId, 1.0)
            }
            windowAlphas.removeValue(forKey: id)
            windowCGIDs.removeValue(forKey: id)
        } else {
            if cid != 0, let alphaFunc = WindowController.cgsSetWindowAlpha {
                for cgId in windowCGIDs.values {
                    _ = alphaFunc(cid, cgId, 1.0)
                }
            }
            lastAppliedFrames.removeAll()
            windowWriters.removeAll()
            appContexts.removeAll()
            windowAlphas.removeAll()
            windowCGIDs.removeAll()
        }
    }
    
    private func getOrCreateWriter(windowId: WindowId, pid: pid_t, element: AXUIElement) -> WindowWriter {
        lock.lock()
        defer { lock.unlock() }
        if let writer = windowWriters[windowId] {
            return writer
        }
        let ctx = appContexts[pid] ?? {
            let newCtx = AppAXContext(pid: pid)
            appContexts[pid] = newCtx
            return newCtx
        }()
        let writer = WindowWriter(ctx: ctx, ax: element)
        windowWriters[windowId] = writer
        return writer
    }
    
    // MARK: - Asynchronous Non-Blocking Frame Updates (Display-Link VSYNC Paced)
    
    public func setPositionAsync(element: AXUIElement, position: CGPoint, size: CGSize = .zero, windowId: WindowId) {
        let rounded = CGPoint(x: round(position.x), y: round(position.y))
        
        lock.lock()
        if let prev = lastAppliedFrames[windowId],
           abs(prev.origin.x - rounded.x) < 0.5 && abs(prev.origin.y - rounded.y) < 0.5 {
            lock.unlock()
            return
        }
        if var prev = lastAppliedFrames[windowId] {
            prev.origin = rounded
            if size != .zero { prev.size = size }
            lastAppliedFrames[windowId] = prev
        } else {
            lastAppliedFrames[windowId] = CGRect(origin: rounded, size: size)
        }
        lock.unlock()
        
        let writer = getOrCreateWriter(windowId: windowId, pid: windowId.pid, element: element)
        writer.setPositionAsync(rounded)
    }
    
    public func setFrameAsync(element: AXUIElement, frame: CGRect, windowId: WindowId) {
        let rounded = CGRect(
            x: round(frame.origin.x),
            y: round(frame.origin.y),
            width: round(frame.size.width),
            height: round(frame.size.height)
        )
        
        lock.lock()
        if let prev = lastAppliedFrames[windowId],
           abs(prev.origin.x - rounded.origin.x) < 0.5 &&
           abs(prev.origin.y - rounded.origin.y) < 0.5 &&
           abs(prev.size.width - rounded.size.width) < 0.5 &&
           abs(prev.size.height - rounded.size.height) < 0.5 {
            lock.unlock()
            return
        }
        lastAppliedFrames[windowId] = rounded
        lock.unlock()
        
        let writer = getOrCreateWriter(windowId: windowId, pid: windowId.pid, element: element)
        writer.setFrameAsync(rounded)
    }
    
    // MARK: - Synchronous Frame Updates (Settle Passes & Direct Resizing)
    
    @discardableResult
    public func setFrame(element: AXUIElement, frame: CGRect, windowId: WindowId? = nil) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.10)
        
        let roundedFrame = CGRect(
            x: round(frame.origin.x),
            y: round(frame.origin.y),
            width: round(frame.size.width),
            height: round(frame.size.height)
        )
        
        lock.lock()
        let prev = windowId.flatMap { lastAppliedFrames[$0] }
        lock.unlock()
        
        if let prev = prev {
            let posDiff = abs(prev.origin.x - roundedFrame.origin.x) + abs(prev.origin.y - roundedFrame.origin.y)
            let sizeDiff = abs(prev.size.width - roundedFrame.size.width) + abs(prev.size.height - roundedFrame.size.height)
            
            // If frame hasn't visibly changed (< 0.5 pt), skip entirely (0 IPC calls)
            if posDiff < 0.5 && sizeDiff < 0.5 {
                return true
            }
            
            // If size is unchanged (typical for scrolling across the strip), ONLY set position once!
            if sizeDiff < 0.5 {
                let ok = setPosition(element: element, position: roundedFrame.origin)
                if ok {
                    lock.lock()
                    if let id = windowId { lastAppliedFrames[id] = roundedFrame }
                    lock.unlock()
                }
                return ok
            }
            
            // Size changed: set origin, then size, then re-confirm origin
            _ = setPosition(element: element, position: roundedFrame.origin)
            let okSize = setSize(element: element, size: roundedFrame.size)
            
            // Amethyst "Window Peeking": query actual size in case app enforces minimum bounds (e.g. Xcode, Spotify, Terminal)
            var finalSize = roundedFrame.size
            var actualSizeVal: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &actualSizeVal) == .success,
               let val = actualSizeVal {
                var actual = CGSize.zero
                if AXValueGetValue(val as! AXValue, .cgSize, &actual) && actual.width > 0 && actual.height > 0 {
                    finalSize = actual
                }
            }
            
            let okPos = setPosition(element: element, position: roundedFrame.origin)
            if okSize || okPos {
                lock.lock()
                if let id = windowId { lastAppliedFrames[id] = CGRect(origin: roundedFrame.origin, size: finalSize) }
                lock.unlock()
            }
            return okSize && okPos
        } else {
            _ = setPosition(element: element, position: roundedFrame.origin)
            let okSize = setSize(element: element, size: roundedFrame.size)
            
            var finalSize = roundedFrame.size
            var actualSizeVal: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &actualSizeVal) == .success,
               let val = actualSizeVal {
                var actual = CGSize.zero
                if AXValueGetValue(val as! AXValue, .cgSize, &actual) && actual.width > 0 && actual.height > 0 {
                    finalSize = actual
                }
            }
            
            let okPos = setPosition(element: element, position: roundedFrame.origin)
            if okSize || okPos {
                lock.lock()
                if let id = windowId { lastAppliedFrames[id] = CGRect(origin: roundedFrame.origin, size: finalSize) }
                lock.unlock()
            }
            return okSize && okPos
        }
    }
    
    @discardableResult
    public func setPosition(element: AXUIElement, position: CGPoint, windowId: WindowId? = nil) -> Bool {
        let rounded = CGPoint(x: round(position.x), y: round(position.y))
        
        if let id = windowId {
            lock.lock()
            if let prev = lastAppliedFrames[id],
               abs(prev.origin.x - rounded.x) < 0.5 && abs(prev.origin.y - rounded.y) < 0.5 {
                lock.unlock()
                return true
            }
            if var prev = lastAppliedFrames[id] {
                prev.origin = rounded
                lastAppliedFrames[id] = prev
            } else {
                lastAppliedFrames[id] = CGRect(origin: rounded, size: .zero)
            }
            lock.unlock()
        }
        
        AXUIElementSetMessagingTimeout(element, 0.04)
        var point = rounded
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        let err = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        return err == .success
    }
    
    @discardableResult
    public func setSize(element: AXUIElement, size: CGSize) -> Bool {
        var sz = CGSize(width: round(size.width), height: round(size.height))
        guard let value = AXValueCreate(.cgSize, &sz) else { return false }
        let err = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        return err == .success
    }
    
    // MARK: - Window State
    
    @discardableResult
    public func focus(element: AXUIElement, pid: pid_t, cgWindowID: CGWindowID? = nil) -> Bool {
        var wid: UInt32 = UInt32(cgWindowID ?? getCGWindowID(for: element) ?? 0)
        var psn = ProcessSerialNumber()
        var slpsSuccess = false
        
        if wid != 0 && GetProcessForPID(pid, &psn) == noErr {
            if let slpsSetFront = WindowController.slpsSetFrontProcessWithOptions {
                let cgStatus = slpsSetFront(&psn, wid, kCPSUserGenerated)
                if cgStatus == .success, let slpsPost = WindowController.slpsPostEventRecordTo {
                    for byte in [0x01, 0x02] {
                        var bytes = [UInt8](repeating: 0, count: 0xf8)
                        bytes[0x04] = 0xF8
                        bytes[0x08] = UInt8(byte)
                        bytes[0x3a] = 0x10
                        memcpy(&bytes[0x3c], &wid, MemoryLayout<UInt32>.size)
                        memset(&bytes[0x20], 0xFF, 0x10)
                        _ = bytes.withUnsafeMutableBufferPointer { pointer in
                            slpsPost(&psn, pointer.baseAddress!)
                        }
                    }
                    slpsSuccess = true
                }
            }
        }
        
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
        
        return slpsSuccess
    }
    
    public func close(element: AXUIElement) {
        var closeButtonRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success,
           let btn = closeButtonRef {
            let err = AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
            if err == .success { return }
        }
        
        // Fallback: Dispatch Command+W to target application process
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success && pid > 0 {
            let src = CGEventSource(stateID: .hidSystemState)
            // 0x0D is 'W' key
            if let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x0D, keyDown: true) {
                keyDown.flags = .maskCommand
                keyDown.postToPid(pid)
            }
            if let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x0D, keyDown: false) {
                keyUp.flags = .maskCommand
                keyUp.postToPid(pid)
            }
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
