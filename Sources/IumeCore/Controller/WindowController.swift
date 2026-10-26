import Foundation
import CoreGraphics
import ApplicationServices
import AppKit
import QuartzCore

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

// MARK: - AXTransport Test Seam

/// Injectable transport seam for macOS Accessibility APIs to enable deterministic testing
/// of slow, failing, timed-out, and destroyed-window scenarios.
public protocol AXTransport: Sendable {
    func setAttributeValue(_ element: AXUIElement, attribute: CFString, value: CFTypeRef) -> AXError
    func copyAttributeValue(_ element: AXUIElement, attribute: CFString, value: inout AnyObject?) -> AXError
    func setMessagingTimeout(_ element: AXUIElement, timeoutInSeconds: Float) -> AXError
}

/// Default system AXTransport delegating directly to macOS Accessibility C-APIs.
public final class SystemAXTransport: AXTransport, @unchecked Sendable {
    public static let shared = SystemAXTransport()
    public init() {}

    public func setAttributeValue(_ element: AXUIElement, attribute: CFString, value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(element, attribute, value)
    }

    public func copyAttributeValue(_ element: AXUIElement, attribute: CFString, value: inout AnyObject?) -> AXError {
        AXUIElementCopyAttributeValue(element, attribute, &value)
    }

    public func setMessagingTimeout(_ element: AXUIElement, timeoutInSeconds: Float) -> AXError {
        AXUIElementSetMessagingTimeout(element, timeoutInSeconds)
    }
}

// MARK: - Window Frame State Tracking

/// Thread-safe representation of the complete window placement lifecycle.
/// Distinguishes requested, in-flight, verified, observed, and failed states (D05).
public struct WindowFrameState: Sendable, Equatable {
    /// Latest position / frame requested by layout or motion engine.
    public var desiredFrame: CGRect?
    /// Position / frame update currently in-flight on the serial AX queue.
    public var inFlightFrame: CGRect?
    /// Monotonically increasing sequence number to enforce latest-wins ordering.
    public var generation: UInt64
    /// Last successfully acknowledged or verified position / frame.
    public var verifiedFrame: CGRect?
    /// Unverified actual window position / frame observed via read-back or observer.
    public var unverifiedObservedFrame: CGRect?
    /// Result code of the most recent AX operation.
    public var lastWriteResult: AXError?
    /// Number of consecutive write failures; used for bounded retries (cap at 3).
    public var consecutiveFailures: Int

    public init(
        desiredFrame: CGRect? = nil,
        inFlightFrame: CGRect? = nil,
        generation: UInt64 = 0,
        verifiedFrame: CGRect? = nil,
        unverifiedObservedFrame: CGRect? = nil,
        lastWriteResult: AXError? = nil,
        consecutiveFailures: Int = 0
    ) {
        self.desiredFrame = desiredFrame
        self.inFlightFrame = inFlightFrame
        self.generation = generation
        self.verifiedFrame = verifiedFrame
        self.unverifiedObservedFrame = unverifiedObservedFrame
        self.lastWriteResult = lastWriteResult
        self.consecutiveFailures = consecutiveFailures
    }
}

// MARK: - AppAXContext

/// Serial AX execution queue and context per process identifier to isolate slow apps.
public final class AppAXContext: @unchecked Sendable {
    public let pid: pid_t
    public let queue: DispatchQueue
    public let appElement: AXUIElement
    private let transport: AXTransport
    private var didDisableEnhancedUI = false
    private var hasCheckedEnhancedUI = false

    public init(pid: pid_t, transport: AXTransport = SystemAXTransport.shared) {
        self.pid = pid
        self.transport = transport
        self.appElement = AXUIElementCreateApplication(pid)
        self.queue = DispatchQueue(label: "com.iume.ax.\(pid)", qos: .userInteractive)
        _ = transport.setMessagingTimeout(appElement, timeoutInSeconds: 0.04)
        // Never do AX IPC in init: contexts are created on the main thread while
        // applying a frame batch, and a slow app would stall the whole strip.
    }

    /// Rectangle/Amethyst optimization: If an app has AXEnhancedUserInterface = true,
    /// macOS animates programmatic moves and runs slow synchronous tree walks.
    /// Setting it to false eliminates stutter during continuous scrolling.
    ///
    /// Must run on `queue`; it performs synchronous AX IPC.
    public func disableEnhancedUIIfNeeded() {
        guard !hasCheckedEnhancedUI else { return }
        hasCheckedEnhancedUI = true
        var val: AnyObject?
        if transport.copyAttributeValue(appElement, attribute: "AXEnhancedUserInterface" as CFString, value: &val) == .success,
           let boolVal = val as? NSNumber, boolVal.boolValue {
            _ = transport.setAttributeValue(appElement, attribute: "AXEnhancedUserInterface" as CFString, value: kCFBooleanFalse)
            didDisableEnhancedUI = true
        }
    }

    /// Must run on `queue`.
    public func restoreEnhancedUIIfNeeded() {
        guard didDisableEnhancedUI else { return }
        _ = transport.setAttributeValue(appElement, attribute: "AXEnhancedUserInterface" as CFString, value: kCFBooleanTrue)
        didDisableEnhancedUI = false
    }
}

// MARK: - WindowWriter

/// Thread-safe latest-wins window writer that avoids queuing stale coordinate updates,
/// handles AXError returns, detects destroyed windows and timeouts, and performs settle verification.
public final class WindowWriter: @unchecked Sendable {
    public let windowId: WindowId
    public let ctx: AppAXContext
    public let ax: AXUIElement
    public let transport: AXTransport
    private let lock = NSLock()
    private var isInvalidated = false

    // State tracking under lock
    private var _state = WindowFrameState()
    public var state: WindowFrameState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    private enum RequestType {
        case position(CGPoint, size: CGSize?)
        case frame(CGRect)
        case settle(CGRect, visibleFrame: CGRect?)
    }

    private struct WriteRequest {
        let type: RequestType
        let frame: CGRect
        let generation: UInt64
    }

    private var pendingRequest: WriteRequest?
    private var isDraining = false

    public var onWindowDestroyed: (@Sendable (WindowId) -> Void)?
    public var onStateChanged: (@Sendable (WindowId, WindowFrameState) -> Void)?

    public init(
        windowId: WindowId,
        ctx: AppAXContext,
        ax: AXUIElement,
        transport: AXTransport = SystemAXTransport.shared
    ) {
        self.windowId = windowId
        self.ctx = ctx
        self.ax = ax
        self.transport = transport
        _ = transport.setMessagingTimeout(ax, timeoutInSeconds: 0.04)
    }

    public convenience init(ctx: AppAXContext, ax: AXUIElement, transport: AXTransport = SystemAXTransport.shared) {
        self.init(windowId: WindowId(pid: ctx.pid, rawId: 0), ctx: ctx, ax: ax, transport: transport)
    }

    public func initState(_ state: WindowFrameState) {
        lock.lock()
        defer { lock.unlock() }
        _state = state
    }

    public func invalidate() {
        lock.lock()
        isInvalidated = true
        pendingRequest = nil
        _state.inFlightFrame = nil
        lock.unlock()
    }

    public func recordExternalFrame(_ frame: CGRect) {
        lock.lock()
        _state.desiredFrame = frame
        _state.verifiedFrame = frame
        _state.unverifiedObservedFrame = frame
        _state.lastWriteResult = .success
        _state.consecutiveFailures = 0
        pendingRequest = nil
        let st = _state
        lock.unlock()
        onStateChanged?(windowId, st)
    }

    public func setPositionAsync(_ p: CGPoint, size: CGSize? = nil) {
        lock.lock()
        guard !isInvalidated else {
            lock.unlock()
            return
        }

        // Bounded retry check: if 3 consecutive failures, back off during motion
        if _state.consecutiveFailures >= 3 {
            lock.unlock()
            return
        }

        _state.generation += 1
        let gen = _state.generation
        let targetRect = CGRect(origin: p, size: size ?? _state.verifiedFrame?.size ?? .zero)
        _state.desiredFrame = targetRect
        pendingRequest = WriteRequest(type: .position(p, size: size), frame: targetRect, generation: gen)

        let shouldStart = !isDraining
        isDraining = true
        lock.unlock()

        guard shouldStart else { return }
        ctx.queue.async { [weak self] in
            self?.drain()
        }
    }

    public func setFrameAsync(_ frame: CGRect) {
        lock.lock()
        guard !isInvalidated else {
            lock.unlock()
            return
        }

        if _state.consecutiveFailures >= 3 {
            lock.unlock()
            return
        }

        _state.generation += 1
        let gen = _state.generation
        _state.desiredFrame = frame
        pendingRequest = WriteRequest(type: .frame(frame), frame: frame, generation: gen)

        let shouldStart = !isDraining
        isDraining = true
        lock.unlock()

        guard shouldStart else { return }
        ctx.queue.async { [weak self] in
            self?.drain()
        }
    }

    public func settleFrameAsync(_ frame: CGRect, visibleFrame: CGRect? = nil) {
        lock.lock()
        guard !isInvalidated else {
            lock.unlock()
            return
        }

        // Settle is the authoritative write: it executes unconditionally even if
        // consecutive failures reached the motion retry bound.
        _state.generation += 1
        let gen = _state.generation
        _state.desiredFrame = frame
        pendingRequest = WriteRequest(type: .settle(frame, visibleFrame: visibleFrame), frame: frame, generation: gen)

        let shouldStart = !isDraining
        isDraining = true
        lock.unlock()

        guard shouldStart else { return }
        ctx.queue.async { [weak self] in
            self?.drain()
        }
    }

    private func drain() {
        while true {
            lock.lock()
            if isInvalidated {
                isDraining = false
                _state.inFlightFrame = nil
                lock.unlock()
                return
            }

            guard let req = pendingRequest else {
                isDraining = false
                _state.inFlightFrame = nil
                lock.unlock()
                return
            }

            pendingRequest = nil
            _state.inFlightFrame = req.frame
            let currentGen = req.generation
            lock.unlock()

            switch req.type {
            case .position(let pt, _):
                executePosition(pt, req: req)
            case .frame(let frame):
                executeFrame(frame, req: req)
            case .settle(let frame, let visibleFrame):
                executeSettle(frame, visibleFrame: visibleFrame, req: req)
            }

            lock.lock()
            if _state.generation == currentGen {
                _state.inFlightFrame = nil
            }
            lock.unlock()
        }
    }

    private func executePosition(_ pt: CGPoint, req: WriteRequest) {
        var point = CGPoint(x: round(pt.x), y: round(pt.y))
        guard let pv = AXValueCreate(.cgPoint, &point) else {
            recordFailure(.failure, for: req)
            return
        }
        let t0 = CACurrentMediaTime()
        let err = transport.setAttributeValue(ax, attribute: kAXPositionAttribute as CFString, value: pv)
        let durationMs = (CACurrentMediaTime() - t0) * 1000.0
        IumeSignpost.emitAXWrite(pid: windowId.pid, windowId: windowId.rawId, error: err, durationMs: durationMs)
        if err == .success {
            recordSuccess(frame: req.frame, for: req)
        } else {
            recordFailure(err, for: req)
        }
    }

    private func executeFrame(_ frame: CGRect, req: WriteRequest) {
        let t0 = CACurrentMediaTime()
        let err = writeFrameDirect(frame)
        let durationMs = (CACurrentMediaTime() - t0) * 1000.0
        IumeSignpost.emitAXWrite(pid: windowId.pid, windowId: windowId.rawId, error: err, durationMs: durationMs)
        if err == .success {
            recordSuccess(frame: frame, for: req)
        } else {
            recordFailure(err, for: req)
        }
    }

    private func executeSettle(_ expected: CGRect, visibleFrame: CGRect? = nil, req: WriteRequest) {
        let (settleSignpost, settleState) = IumeSignpost.beginWindowSettle(pid: windowId.pid, windowId: windowId.rawId)

        // 1. Unconditional authoritative write on settle
        let t0 = CACurrentMediaTime()
        let writeErr = writeFrameDirect(expected)
        let writeDurationMs = (CACurrentMediaTime() - t0) * 1000.0
        IumeSignpost.emitAXWrite(pid: windowId.pid, windowId: windowId.rawId, error: writeErr, durationMs: writeDurationMs)

        if writeErr == .invalidUIElement {
            IumeSignpost.endWindowSettle(id: settleSignpost, state: settleState, pid: windowId.pid, windowId: windowId.rawId, success: false)
            recordFailure(writeErr, for: req)
            return
        }

        if hasNewerRequest(than: req.generation) {
            IumeSignpost.endWindowSettle(id: settleSignpost, state: settleState, pid: windowId.pid, windowId: windowId.rawId, success: false)
            return
        }

        // 2. Non-blocking verification pass reading back position and size
        guard let actual = readFrame() else {
            IumeSignpost.endWindowSettle(id: settleSignpost, state: settleState, pid: windowId.pid, windowId: windowId.rawId, success: false)
            recordFailure(writeErr != .success ? writeErr : .cannotComplete, for: req)
            return
        }

        let tolerance: CGFloat = 1.0
        if frameMatches(actual, expected, tolerance: tolerance) {
            IumeSignpost.endWindowSettle(id: settleSignpost, state: settleState, pid: windowId.pid, windowId: windowId.rawId, success: true)
            recordVerified(actual, for: req)
            return
        }

        // Discrepancy > 1.0 pt detected
        let discrepancy = max(
            abs(actual.origin.x - expected.origin.x),
            abs(actual.origin.y - expected.origin.y),
            abs(actual.size.width - expected.size.width),
            abs(actual.size.height - expected.size.height)
        )
        IumeSignpost.emitAXRepair(pid: windowId.pid, windowId: windowId.rawId, discrepancy: discrepancy, expected: expected, actual: actual)

        lock.lock()
        _state.unverifiedObservedFrame = actual
        lock.unlock()

        if hasNewerRequest(than: req.generation) {
            IumeSignpost.endWindowSettle(id: settleSignpost, state: settleState, pid: windowId.pid, windowId: windowId.rawId, success: false)
            return
        }

        // 3. Bounded repair: 1 retry
        let tRepair0 = CACurrentMediaTime()
        let repairErr = writeFrameDirect(expected)
        let repairDurationMs = (CACurrentMediaTime() - tRepair0) * 1000.0
        IumeSignpost.emitAXWrite(pid: windowId.pid, windowId: windowId.rawId, error: repairErr, durationMs: repairDurationMs)

        if repairErr == .invalidUIElement {
            IumeSignpost.endWindowSettle(id: settleSignpost, state: settleState, pid: windowId.pid, windowId: windowId.rawId, success: false)
            recordFailure(repairErr, for: req)
            return
        }

        if hasNewerRequest(than: req.generation) {
            IumeSignpost.endWindowSettle(id: settleSignpost, state: settleState, pid: windowId.pid, windowId: windowId.rawId, success: false)
            return
        }

        if let repaired = readFrame(), frameMatches(repaired, expected, tolerance: tolerance) {
            IumeSignpost.endWindowSettle(id: settleSignpost, state: settleState, pid: windowId.pid, windowId: windowId.rawId, success: true)
            Diagnostics.shared.log(level: "INFO", category: "AXReliability", message: "Window \(windowId) settle discrepancy repaired on retry.")
            recordVerified(repaired, for: req)
            return
        }

        var finalActual = readFrame() ?? actual

        // 4. Special authoritative bounds handling for Terminal.app (character cell constraints)
        let isTerminal = NSRunningApplication(processIdentifier: windowId.pid)?.bundleIdentifier == "com.apple.Terminal"
        if isTerminal && !frameMatches(finalActual, expected, tolerance: tolerance) {
            let okScript = WindowController.applyTerminalBounds(cgWindowId: windowId.rawId, bounds: expected)
            if okScript, let postScriptActual = readFrame() {
                finalActual = postScriptActual
                if frameMatches(postScriptActual, expected, tolerance: tolerance) {
                    IumeSignpost.endWindowSettle(id: settleSignpost, state: settleState, pid: windowId.pid, windowId: windowId.rawId, success: true)
                    Diagnostics.shared.log(level: "INFO", category: "AXReliability", message: "Window \(windowId) settled to exact bounds via Terminal bounds control: \(postScriptActual)")
                    recordVerified(postScriptActual, for: req)
                    return
                }
            }
        }

        // 5. Edge-snapping alignment for discrete character grid or min/max constrained windows
        if let vis = visibleFrame {
            var adjustedOrigin = finalActual.origin
            var didAdjust = false

            // Snap bottom edge flush to visibleFrame.maxY if expected to touch bottom
            if expected.maxY >= vis.maxY - 2.0 && finalActual.height < expected.height {
                adjustedOrigin.y = vis.maxY - finalActual.height
                didAdjust = true
            }
            // Snap right edge flush to visibleFrame.maxX if expected to touch right
            if expected.maxX >= vis.maxX - 2.0 && finalActual.width < expected.width {
                adjustedOrigin.x = vis.maxX - finalActual.width
                didAdjust = true
            }
            // Snap left edge flush to visibleFrame.minX if expected to touch left
            if expected.origin.x <= vis.minX + 2.0 && abs(finalActual.origin.x - vis.minX) > 0.5 {
                adjustedOrigin.x = vis.minX
                didAdjust = true
            }
            // Snap top edge flush to visibleFrame.minY if expected to touch top
            if expected.origin.y <= vis.minY + 2.0 && abs(finalActual.origin.y - vis.minY) > 0.5 {
                adjustedOrigin.y = vis.minY
                didAdjust = true
            }

            if didAdjust {
                var pt = CGPoint(x: round(adjustedOrigin.x), y: round(adjustedOrigin.y))
                if let pv = AXValueCreate(.cgPoint, &pt) {
                    _ = transport.setAttributeValue(ax, attribute: kAXPositionAttribute as CFString, value: pv)
                }
                if let alignedFrame = readFrame() {
                    finalActual = alignedFrame
                }
            }
        }

        // 6. Check if origin is verified but size was constrained by app (e.g. Terminal character cell grid or min/max size)
        let originMatches = abs(finalActual.origin.x - expected.origin.x) <= tolerance + 2.0 &&
                            abs(finalActual.origin.y - expected.origin.y) <= tolerance + 2.0
        let isAppConstrainedSize = originMatches && (repairErr == .success || writeErr == .success || isTerminal)

        if isAppConstrainedSize {
            // App accepted position but constrained size to character grid or minimum window dimensions.
            // This is a verified write of the app's true physical frame, NOT a failure.
            IumeSignpost.endWindowSettle(id: settleSignpost, state: settleState, pid: windowId.pid, windowId: windowId.rawId, success: true)
            Diagnostics.shared.log(level: "INFO", category: "AXReliability", message: "Window \(windowId) settled with app-quantized dimensions: expected=\(expected.size) actual=\(finalActual.size)")
            recordVerified(finalActual, for: req)
            return
        }

        // 7. Record unresolved mismatch (bounded: one retry only)
        IumeSignpost.endWindowSettle(id: settleSignpost, state: settleState, pid: windowId.pid, windowId: windowId.rawId, success: false)
        let currentActual = finalActual
        IumeSignpost.recordPersistentMismatch(pid: windowId.pid, windowId: windowId.rawId, expected: expected, actual: currentActual)
        Diagnostics.shared.log(level: "ERROR", category: "AXReliability", message: "Window \(windowId) settle unresolved mismatch after repair retry.")

        lock.lock()
        _state.lastWriteResult = .failure
        _state.consecutiveFailures += 1
        _state.unverifiedObservedFrame = currentActual
        let st = _state
        lock.unlock()
        onStateChanged?(windowId, st)
    }

    private func writeFrameDirect(_ frame: CGRect) -> AXError {
        var pt = CGPoint(x: round(frame.origin.x), y: round(frame.origin.y))
        var sz = CGSize(width: round(frame.size.width), height: round(frame.size.height))

        if let pv = AXValueCreate(.cgPoint, &pt) {
            let err = transport.setAttributeValue(ax, attribute: kAXPositionAttribute as CFString, value: pv)
            if err != .success { return err }
        } else {
            return .failure
        }

        if let sv = AXValueCreate(.cgSize, &sz) {
            let err = transport.setAttributeValue(ax, attribute: kAXSizeAttribute as CFString, value: sv)
            if err != .success { return err }
        } else {
            return .failure
        }

        if let pv = AXValueCreate(.cgPoint, &pt) {
            let err = transport.setAttributeValue(ax, attribute: kAXPositionAttribute as CFString, value: pv)
            if err != .success { return err }
        } else {
            return .failure
        }

        return .success
    }

    private func readFrame() -> CGRect? {
        var posRef: AnyObject?
        guard transport.copyAttributeValue(ax, attribute: kAXPositionAttribute as CFString, value: &posRef) == .success,
              let posVal = axValue(from: posRef) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(posVal, .cgPoint, &point) else { return nil }

        var sizeRef: AnyObject?
        guard transport.copyAttributeValue(ax, attribute: kAXSizeAttribute as CFString, value: &sizeRef) == .success,
              let sizeVal = axValue(from: sizeRef) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(sizeVal, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func recordSuccess(frame: CGRect, for req: WriteRequest) {
        lock.lock()
        if req.generation == _state.generation || _state.desiredFrame == frame {
            _state.verifiedFrame = frame
            _state.unverifiedObservedFrame = frame
        }
        _state.lastWriteResult = .success
        _state.consecutiveFailures = 0
        let st = _state
        lock.unlock()
        onStateChanged?(windowId, st)
    }

    private func recordVerified(_ frame: CGRect, for req: WriteRequest) {
        lock.lock()
        _state.verifiedFrame = frame
        _state.unverifiedObservedFrame = frame
        _state.lastWriteResult = .success
        _state.consecutiveFailures = 0
        let st = _state
        lock.unlock()
        onStateChanged?(windowId, st)
    }

    private func recordFailure(_ err: AXError, for req: WriteRequest) {
        Diagnostics.shared.recordFailedOperation()
        lock.lock()
        _state.lastWriteResult = err
        _state.consecutiveFailures += 1
        let isDestroyed = (err == .invalidUIElement)
        if isDestroyed {
            isInvalidated = true
        }
        let failures = _state.consecutiveFailures
        let st = _state
        lock.unlock()

        if isDestroyed {
            Diagnostics.shared.log(level: "INFO", category: "AXReliability", message: "Window \(windowId) destroyed (invalidUIElement); clearing writer state.")
        } else if failures >= 3 {
            Diagnostics.shared.log(level: "WARN", category: "AXReliability", message: "Window \(windowId) reached \(failures) consecutive AX failures (\(err)); backing off motion writes.")
        }

        onStateChanged?(windowId, st)

        if isDestroyed {
            onWindowDestroyed?(windowId)
        }
    }

    private func hasNewerRequest(than gen: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isInvalidated || _state.generation > gen || pendingRequest != nil
    }

    private func frameMatches(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.size.width - rhs.size.width) <= tolerance
            && abs(lhs.size.height - rhs.size.height) <= tolerance
    }
}

// MARK: - WindowController

/// Low-level window manipulation operations using macOS Accessibility APIs.
/// Features per-app isolated serial queues, latest-wins coalescing, AXTransport test seam,
/// bounded retry policies, and settle read-back verification with single-retry repair.
public final class WindowController: @unchecked Sendable {

    public let transport: AXTransport

    public init(transport: AXTransport = SystemAXTransport.shared) {
        self.transport = transport
    }

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

    // Cache of verified applied frames by window ID to eliminate redundant AX IPC overhead
    private var lastAppliedFrames: [WindowId: CGRect] = [:]
    private var windowStates: [WindowId: WindowFrameState] = [:]
    private var appContexts: [pid_t: AppAXContext] = [:]
    private var windowWriters: [WindowId: WindowWriter] = [:]
    private var windowAlphas: [WindowId: Float] = [:]
    private var windowCGIDs: [WindowId: UInt32] = [:]
    private var lastAXTraceTimeByWindow: [WindowId: CFTimeInterval] = [:]
    private let lock = NSLock()

    /// Callback invoked when a window's authoritative or app-quantized physical frame has been verified.
    public var onWindowFrameVerified: (@Sendable (WindowId, CGRect) -> Void)?

    /// Authoritatively sets the window frame of a Terminal.app window via AppleScript bounds,
    /// bypassing AppKit accessibility character-cell height and width quantization so it aligns flush to strip edges.
    @discardableResult
    public static func applyTerminalBounds(cgWindowId: UInt64, bounds: CGRect) -> Bool {
        guard cgWindowId > 0 else { return false }
        let minX = Int(round(bounds.minX))
        let minY = Int(round(bounds.minY))
        let maxX = Int(round(bounds.maxX))
        let maxY = Int(round(bounds.maxY))
        let scriptSource = """
        tell application "Terminal"
            repeat with w in windows
                if id of w is \(cgWindowId) then
                    set bounds of w to {\(minX), \(minY), \(maxX), \(maxY)}
                    return true
                end if
            end repeat
            return false
        end tell
        """
        guard let script = NSAppleScript(source: scriptSource) else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil && result.booleanValue
    }

    public func recordAppliedFrame(_ frame: CGRect, for windowId: WindowId) {
        lock.lock()
        var st = windowStates[windowId] ?? WindowFrameState()
        st.desiredFrame = frame
        st.verifiedFrame = frame
        st.unverifiedObservedFrame = frame
        st.lastWriteResult = .success
        st.consecutiveFailures = 0
        windowStates[windowId] = st
        lastAppliedFrames[windowId] = frame
        let writer = windowWriters[windowId]
        lock.unlock()

        writer?.recordExternalFrame(frame)
        onWindowFrameVerified?(windowId, frame)
    }

    public func frameState(for windowId: WindowId) -> WindowFrameState? {
        lock.lock()
        let writer = windowWriters[windowId]
        let st = windowStates[windowId]
        lock.unlock()
        return writer?.state ?? st
    }

    public func lastAppliedFrame(for windowId: WindowId) -> CGRect? {
        lock.lock()
        defer { lock.unlock() }
        return windowStates[windowId]?.verifiedFrame ?? lastAppliedFrames[windowId]
    }

    public func getConsecutiveFailures(for windowId: WindowId) -> Int {
        frameState(for: windowId)?.consecutiveFailures ?? 0
    }

    public func getLastWriteResult(for windowId: WindowId) -> AXError? {
        frameState(for: windowId)?.lastWriteResult
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

        let ctx = getOrCreateAppContext(pid: pid)
        ctx.queue.async {
            ctx.disableEnhancedUIIfNeeded()
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

    @discardableResult
    public func applyStripFrames(
        placements: [WindowPlacement],
        visibleFrame: CGRect,
        focusedWindowId: WindowId?,
        isMoving: Bool,
        resizingWindowId: WindowId? = nil
    ) -> [WindowId: CGRect] {
        let cid = WindowController.cgsDefaultConnection?() ?? 0
        var visibleWindowsOrdered: [WindowPlacement] = []
        var parkedWindows: [WindowPlacement] = []
        var writtenFrames: [WindowId: CGRect] = [:]

        for placement in placements {
            ensureEnhancedUIDisabled(for: placement.windowId.pid)
            let rawRect = placement.targetFrame

            // If actively resizing this window with the mouse, avoid touching it
            if let resizingId = resizingWindowId, placement.windowId == resizingId {
                lock.lock()
                var st = windowStates[placement.windowId] ?? WindowFrameState()
                st.desiredFrame = rawRect
                st.verifiedFrame = rawRect
                st.unverifiedObservedFrame = rawRect
                st.consecutiveFailures = 0
                st.lastWriteResult = .success
                windowStates[placement.windowId] = st
                lastAppliedFrames[placement.windowId] = rawRect
                let writer = windowWriters[placement.windowId]
                lock.unlock()
                writer?.recordExternalFrame(rawRect)
                continue
            }

            // A window is actively updated during motion if it is visible or within the immediate strip buffer
            // so entering/exiting windows remain seamlessly attached to their neighbors without jumps or overlap.
            let buffer = isMoving ? visibleFrame.width : 0
            let isSafelyVisible = rawRect.origin.x < (visibleFrame.maxX + buffer) &&
                                  rawRect.maxX > (visibleFrame.minX - buffer)
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
            // In motion: non-blocking asynchronous position writes via per-app serial
            // queues with latest-wins coalescing. Ordinary horizontal motion never
            // sends a size write; a genuine size change still gets a full frame.
            for placement in visibleWindowsOrdered {
                if self.setPositionAsync(
                    element: placement.axElement,
                    position: placement.targetFrame.origin,
                    size: placement.targetFrame.size,
                    windowId: placement.windowId
                ) {
                    writtenFrames[placement.windowId] = placement.targetFrame
                }
            }
        } else {
            // Settled pass: authoritative frames are written asynchronously and
            // verified on each app's own queue. A slow app no longer blocks main or
            // delays the other apps' final frames.
            for placement in visibleWindowsOrdered {
                let roundedOrigin = CGPoint(
                    x: round(placement.targetFrame.origin.x),
                    y: round(placement.targetFrame.origin.y)
                )
                let roundedFrame = CGRect(
                    x: roundedOrigin.x,
                    y: roundedOrigin.y,
                    width: round(placement.targetFrame.size.width),
                    height: round(placement.targetFrame.size.height)
                )
                self.settleFrameAsync(
                    element: placement.axElement,
                    frame: roundedFrame,
                    windowId: placement.windowId,
                    visibleFrame: visibleFrame
                )
                writtenFrames[placement.windowId] = roundedFrame
            }
        }

        // 2. Offscreen windows: parked at left or right edge slivers (0 IPC overhead when stationary)
        for placement in parkedWindows {
            let roundedOrigin = CGPoint(x: round(placement.targetFrame.origin.x), y: round(placement.targetFrame.origin.y))
            let roundedSize = CGSize(width: round(placement.targetFrame.size.width), height: round(placement.targetFrame.size.height))
            let parkedFrame = CGRect(origin: roundedOrigin, size: roundedSize)

            lock.lock()
            let st = windowStates[placement.windowId]
            let prev = st?.verifiedFrame ?? lastAppliedFrames[placement.windowId]
            let isVerified = (st?.consecutiveFailures ?? 0) == 0 && st?.lastWriteResult == .success
            lock.unlock()

            let positionUnchanged = prev.map {
                abs($0.origin.x - roundedOrigin.x) < 1.0 && abs($0.origin.y - roundedOrigin.y) < 1.0
            } ?? false
            let sizeUnchanged = prev.map {
                abs($0.width - roundedSize.width) < 1.0 && abs($0.height - roundedSize.height) < 1.0
            } ?? false

            if positionUnchanged && sizeUnchanged && isVerified {
                // Already parked and verified, 0 IPC calls.
            } else {
                if isMoving {
                    if setPositionAsync(
                        element: placement.axElement,
                        position: roundedOrigin,
                        size: roundedSize,
                        windowId: placement.windowId
                    ) {
                        writtenFrames[placement.windowId] = CGRect(origin: roundedOrigin, size: roundedSize)
                    }
                } else {
                    // Settle pass: authoritative placement & verification for parked offscreen window
                    settleFrameAsync(
                        element: placement.axElement,
                        frame: parkedFrame,
                        windowId: placement.windowId
                    )
                    writtenFrames[placement.windowId] = parkedFrame
                }
            }
        }

        // 3. Enforce Z-order so parked slivers sit cleanly behind visible active windows
        if cid != 0 && (!parkedWindows.isEmpty || !visibleWindowsOrdered.isEmpty) {
            enforceStripZOrder(cid: cid, visible: visibleWindowsOrdered, parked: parkedWindows, focusedId: focusedWindowId)
        }

        return writtenFrames
    }

    @inline(__always)
    @discardableResult
    public func applyStripFrames(
        placements: [WindowPlacement],
        visibleFrame: CGRect,
        focusedWindowId: WindowId?,
        isScrollingOnly: Bool,
        resizingWindowId: WindowId? = nil
    ) -> [WindowId: CGRect] {
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
        lastZOrderSignature = nil
        let cid = WindowController.cgsDefaultConnection?() ?? 0
        var writersToInvalidate: [WindowWriter] = []

        if let id = windowId {
            lastAppliedFrames.removeValue(forKey: id)
            if let writer = windowWriters.removeValue(forKey: id) {
                writersToInvalidate.append(writer)
            }
            windowStates.removeValue(forKey: id)
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
            writersToInvalidate.append(contentsOf: windowWriters.values)
            windowWriters.removeAll()
            windowStates.removeAll()
            appContexts.removeAll()
            windowAlphas.removeAll()
            windowCGIDs.removeAll()
        }
        lock.unlock()

        for writer in writersToInvalidate {
            writer.invalidate()
        }
    }

    private func getOrCreateAppContext(pid: pid_t) -> AppAXContext {
        lock.lock()
        defer { lock.unlock() }
        if let ctx = appContexts[pid] { return ctx }
        let ctx = AppAXContext(pid: pid, transport: transport)
        appContexts[pid] = ctx
        return ctx
    }

    /// Synchronizes with the serial AX execution queue for the given process ID.
    /// Useful for testing and ensuring all pending AX IPC operations have completed.
    public func syncQueue(for pid: pid_t) {
        let q: DispatchQueue? = {
            lock.lock()
            defer { lock.unlock() }
            return appContexts[pid]?.queue
        }()
        q?.sync {}
    }

    /// Synchronizes with all active per-app serial AX queues.
    public func syncAllQueues() {
        let queues: [DispatchQueue] = {
            lock.lock()
            defer { lock.unlock() }
            return Array(appContexts.values.map(\.queue))
        }()
        for q in queues {
            q.sync {}
        }
    }

    private func getOrCreateWriter(windowId: WindowId, pid: pid_t, element: AXUIElement) -> WindowWriter {
        lock.lock()
        defer { lock.unlock() }
        if let writer = windowWriters[windowId] {
            return writer
        }
        let ctx = appContexts[pid] ?? {
            let newCtx = AppAXContext(pid: pid, transport: transport)
            appContexts[pid] = newCtx
            return newCtx
        }()
        let writer = WindowWriter(windowId: windowId, ctx: ctx, ax: element, transport: transport)
        if let existing = windowStates[windowId] {
            writer.initState(existing)
        }
        writer.onWindowDestroyed = { [weak self] deadId in
            self?.clearFrameCache(for: deadId)
        }
        writer.onStateChanged = { [weak self] winId, state in
            self?.handleWriterStateChanged(windowId: winId, state: state)
        }
        windowWriters[windowId] = writer
        return writer
    }

    private func handleWriterStateChanged(windowId: WindowId, state: WindowFrameState) {
        var shouldTraceSuccess = false
        var verifiedFrameToReport: CGRect? = nil
        lock.lock()
        windowStates[windowId] = state
        if state.lastWriteResult == .success, let verified = state.verifiedFrame {
            lastAppliedFrames[windowId] = verified
            verifiedFrameToReport = verified
            if UserDefaults.standard.bool(forKey: "iume.gestureDiagnostics") {
                let now = CACurrentMediaTime()
                let previous = lastAXTraceTimeByWindow[windowId] ?? 0
                if now - previous >= 0.10 {
                    lastAXTraceTimeByWindow[windowId] = now
                    shouldTraceSuccess = true
                }
            }
        } else if state.lastWriteResult != nil && state.lastWriteResult != .success {
            // On non-.success return, immediately clear lastAppliedFrames[windowId] so future frames or settle retries re-attempt.
            lastAppliedFrames.removeValue(forKey: windowId)
        }
        lock.unlock()

        if let verified = verifiedFrameToReport {
            onWindowFrameVerified?(windowId, verified)
        }

        if let result = state.lastWriteResult, result != .success {
            Diagnostics.shared.log(level: "ERROR", category: "AXWrite", message: "window=\(windowId) result=\(result) desired=\(String(describing: state.desiredFrame)) verified=\(String(describing: state.verifiedFrame)) failures=\(state.consecutiveFailures)")
        } else if shouldTraceSuccess {
            Diagnostics.shared.log(category: "AXWrite", message: "window=\(windowId) success desired=\(String(describing: state.desiredFrame)) verified=\(String(describing: state.verifiedFrame))")
        }
    }

    // MARK: - Asynchronous Non-Blocking Frame Updates (Display-Link VSYNC Paced)

    @discardableResult
    public func setPositionAsync(element: AXUIElement, position: CGPoint, size: CGSize = .zero, windowId: WindowId) -> Bool {
        let rounded = CGPoint(x: round(position.x), y: round(position.y))
        let requestedSize: CGSize? = size == .zero ? nil : CGSize(
            width: round(size.width),
            height: round(size.height)
        )

        lock.lock()
        let st = windowStates[windowId]
        let prev = st?.verifiedFrame ?? lastAppliedFrames[windowId]
        let failures = st?.consecutiveFailures ?? 0

        // Bounded retry check: if 3 consecutive failures, back off during motion
        if failures >= 3 {
            lock.unlock()
            return false
        }

        let positionUnchanged = prev.map {
            abs($0.origin.x - rounded.x) < 0.5 && abs($0.origin.y - rounded.y) < 0.5
        } ?? false
        let sizeChanged = requestedSize.map { requested in
            guard let prev = prev else { return true }
            let widthDiff = abs(prev.size.width - requested.width)
            let heightDiff = abs(prev.size.height - requested.height)
            if widthDiff < 1.0 && heightDiff <= 30.0 {
                return false
            }
            return widthDiff >= 0.5 || heightDiff >= 0.5
        } ?? false

        // Skip redundant IPC if position is unchanged, size is unchanged, and last write was successful
        if positionUnchanged && !sizeChanged && st?.lastWriteResult == .success {
            lock.unlock()
            return false
        }

        // Update desired frame without falsely marking it applied/verified
        var updatedSt = st ?? WindowFrameState()
        let targetRect = CGRect(origin: rounded, size: requestedSize ?? prev?.size ?? .zero)
        updatedSt.desiredFrame = targetRect
        windowStates[windowId] = updatedSt
        lock.unlock()

        let writer = getOrCreateWriter(windowId: windowId, pid: windowId.pid, element: element)
        if sizeChanged, let requestedSize = requestedSize {
            writer.setFrameAsync(CGRect(origin: rounded, size: requestedSize))
        } else {
            writer.setPositionAsync(rounded, size: requestedSize ?? prev?.size)
        }
        return true
    }

    public func settleFrameAsync(element: AXUIElement, frame: CGRect, windowId: WindowId, visibleFrame: CGRect? = nil) {
        let rounded = CGRect(
            x: round(frame.origin.x),
            y: round(frame.origin.y),
            width: round(frame.size.width),
            height: round(frame.size.height)
        )

        lock.lock()
        var st = windowStates[windowId] ?? WindowFrameState()
        st.desiredFrame = rounded
        // Settle is unconditional
        windowStates[windowId] = st
        lock.unlock()

        let writer = getOrCreateWriter(windowId: windowId, pid: windowId.pid, element: element)
        writer.settleFrameAsync(rounded, visibleFrame: visibleFrame)
    }

    public func setFrameAsync(element: AXUIElement, frame: CGRect, windowId: WindowId) {
        let rounded = CGRect(
            x: round(frame.origin.x),
            y: round(frame.origin.y),
            width: round(frame.size.width),
            height: round(frame.size.height)
        )

        lock.lock()
        let st = windowStates[windowId]
        let prev = st?.verifiedFrame ?? lastAppliedFrames[windowId]
        let failures = st?.consecutiveFailures ?? 0

        if failures >= 3 {
            lock.unlock()
            return
        }

        if let prev = prev,
           st?.lastWriteResult == .success,
           abs(prev.origin.x - rounded.origin.x) < 0.5 &&
           abs(prev.origin.y - rounded.origin.y) < 0.5 &&
           abs(prev.size.width - rounded.size.width) < 0.5 &&
           abs(prev.size.height - rounded.size.height) < 0.5 {
            lock.unlock()
            return
        }

        var updatedSt = st ?? WindowFrameState()
        updatedSt.desiredFrame = rounded
        windowStates[windowId] = updatedSt
        lock.unlock()

        let writer = getOrCreateWriter(windowId: windowId, pid: windowId.pid, element: element)
        writer.setFrameAsync(rounded)
    }

    // MARK: - Synchronous Frame Updates (Settle Passes & Direct Resizing)

    @discardableResult
    public func setFrame(element: AXUIElement, frame: CGRect, windowId: WindowId? = nil) -> Bool {
        _ = transport.setMessagingTimeout(element, timeoutInSeconds: 0.10)

        let roundedFrame = CGRect(
            x: round(frame.origin.x),
            y: round(frame.origin.y),
            width: round(frame.size.width),
            height: round(frame.size.height)
        )

        lock.lock()
        let prev = windowId.flatMap { windowStates[$0]?.verifiedFrame ?? lastAppliedFrames[$0] }
        let failures = windowId.flatMap { windowStates[$0]?.consecutiveFailures } ?? 0
        let lastRes = windowId.flatMap { windowStates[$0]?.lastWriteResult }
        lock.unlock()

        if let prev = prev, failures == 0, lastRes == .success {
            let posDiff = abs(prev.origin.x - roundedFrame.origin.x) + abs(prev.origin.y - roundedFrame.origin.y)
            let sizeDiff = abs(prev.size.width - roundedFrame.size.width) + abs(prev.size.height - roundedFrame.size.height)

            // If frame hasn't visibly changed (< 0.5 pt), skip entirely (0 IPC calls)
            if posDiff < 0.5 && sizeDiff < 0.5 {
                return true
            }

            // If size is unchanged (typical for scrolling across the strip), ONLY set position once!
            if sizeDiff < 0.5 {
                let ok = setPosition(element: element, position: roundedFrame.origin, windowId: windowId)
                return ok
            }
        }

        // Size changed or unverified: set origin, then size, then re-confirm origin
        _ = setPosition(element: element, position: roundedFrame.origin, windowId: windowId)
        let okSize = setSize(element: element, size: roundedFrame.size)

        // Amethyst "Window Peeking": query actual size in case app enforces minimum bounds (e.g. Xcode, Spotify, Terminal)
        var finalSize = roundedFrame.size
        var actualSizeVal: AnyObject?
        if transport.copyAttributeValue(element, attribute: kAXSizeAttribute as CFString, value: &actualSizeVal) == .success,
           let val = axValue(from: actualSizeVal) {
            var actual = CGSize.zero
            if AXValueGetValue(val, .cgSize, &actual) && actual.width > 0 && actual.height > 0 {
                finalSize = actual
            }
        }

        // If Terminal clamped size, force exact bounds via AppleScript
        if let id = windowId, id.pid > 0,
           (abs(finalSize.width - roundedFrame.size.width) > 0.5 || abs(finalSize.height - roundedFrame.size.height) > 0.5) {
            if NSRunningApplication(processIdentifier: id.pid)?.bundleIdentifier == "com.apple.Terminal" {
                if WindowController.applyTerminalBounds(cgWindowId: id.rawId, bounds: roundedFrame) {
                    var scriptSizeVal: AnyObject?
                    if transport.copyAttributeValue(element, attribute: kAXSizeAttribute as CFString, value: &scriptSizeVal) == .success,
                       let val = axValue(from: scriptSizeVal) {
                        var actual = CGSize.zero
                        if AXValueGetValue(val, .cgSize, &actual) && actual.width > 0 && actual.height > 0 {
                            finalSize = actual
                        }
                    }
                }
            }
        }

        let okPos = setPosition(element: element, position: roundedFrame.origin, windowId: windowId)
        let finalOk = okSize && okPos

        if let id = windowId {
            lock.lock()
            var st = windowStates[id] ?? WindowFrameState()
            if finalOk {
                let confirmed = CGRect(origin: roundedFrame.origin, size: finalSize)
                st.verifiedFrame = confirmed
                st.desiredFrame = confirmed
                st.unverifiedObservedFrame = confirmed
                st.lastWriteResult = .success
                st.consecutiveFailures = 0
                lastAppliedFrames[id] = confirmed
            } else {
                st.consecutiveFailures += 1
                st.lastWriteResult = .failure
                lastAppliedFrames.removeValue(forKey: id)
            }
            windowStates[id] = st
            let writer = windowWriters[id]
            lock.unlock()

            if finalOk {
                let confirmed = CGRect(origin: roundedFrame.origin, size: finalSize)
                writer?.recordExternalFrame(confirmed)
                onWindowFrameVerified?(id, confirmed)
            }
        }
        return finalOk
    }

    @discardableResult
    public func setPosition(element: AXUIElement, position: CGPoint, windowId: WindowId? = nil) -> Bool {
        let rounded = CGPoint(x: round(position.x), y: round(position.y))

        if let id = windowId {
            lock.lock()
            let st = windowStates[id]
            let prev = st?.verifiedFrame ?? lastAppliedFrames[id]
            let failures = st?.consecutiveFailures ?? 0
            let lastRes = st?.lastWriteResult
            if let prev = prev,
               failures == 0,
               lastRes == .success,
               abs(prev.origin.x - rounded.x) < 0.5 && abs(prev.origin.y - rounded.y) < 0.5 {
                lock.unlock()
                return true
            }
            lock.unlock()
        }

        _ = transport.setMessagingTimeout(element, timeoutInSeconds: 0.04)
        var point = rounded
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        let err = transport.setAttributeValue(element, attribute: kAXPositionAttribute as CFString, value: value)
        let ok = (err == .success)

        if let id = windowId {
            lock.lock()
            var st = windowStates[id] ?? WindowFrameState()
            st.lastWriteResult = err
            if ok {
                st.consecutiveFailures = 0
                let prevSize = st.verifiedFrame?.size ?? lastAppliedFrames[id]?.size ?? .zero
                let updated = CGRect(origin: rounded, size: prevSize)
                st.verifiedFrame = updated
                st.desiredFrame = updated
                st.unverifiedObservedFrame = updated
                lastAppliedFrames[id] = updated
            } else {
                st.consecutiveFailures += 1
                lastAppliedFrames.removeValue(forKey: id)
                if err == .invalidUIElement {
                    lock.unlock()
                    clearFrameCache(for: id)
                    return false
                }
            }
            windowStates[id] = st
            let writer = windowWriters[id]
            lock.unlock()

            if ok {
                let prevSize = st.verifiedFrame?.size ?? .zero
                writer?.recordExternalFrame(CGRect(origin: rounded, size: prevSize))
            }
        }

        return ok
    }

    @discardableResult
    public func setSize(element: AXUIElement, size: CGSize) -> Bool {
        var sz = CGSize(width: round(size.width), height: round(size.height))
        guard let value = AXValueCreate(.cgSize, &sz) else { return false }
        let err = transport.setAttributeValue(element, attribute: kAXSizeAttribute as CFString, value: value)
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

        _ = transport.setAttributeValue(element, attribute: kAXMainAttribute as CFString, value: kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)

        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }

        return slpsSuccess
    }

    public func close(element: AXUIElement) {
        var closeButtonRef: AnyObject?
        if transport.copyAttributeValue(element, attribute: kAXCloseButtonAttribute as CFString, value: &closeButtonRef) == .success,
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
        if transport.copyAttributeValue(element, attribute: kAXZoomButtonAttribute as CFString, value: &zoomButtonRef) == .success,
           let btn = zoomButtonRef {
            AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
        }
    }

    public func minimize(element: AXUIElement) {
        _ = transport.setAttributeValue(element, attribute: kAXMinimizedAttribute as CFString, value: kCFBooleanTrue)
    }

    public func restore(element: AXUIElement) {
        _ = transport.setAttributeValue(element, attribute: kAXMinimizedAttribute as CFString, value: kCFBooleanFalse)
    }
}

// MARK: - Helper

private func axValue(from ref: AnyObject?) -> AXValue? {
    guard let ref = ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
    return (ref as! AXValue)
}
