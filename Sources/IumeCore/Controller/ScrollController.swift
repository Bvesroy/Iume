import Foundation
import CoreGraphics
import QuartzCore
import AppKit
import os

// MARK: - Private MultitouchSupport Bridge for 3/4-Finger 1:1 Trackpad Swipes

public struct MTTouchVector: Sendable { public var x: Float; public var y: Float }
public struct MTTouchReadout: Sendable { public var position: MTTouchVector; public var velocity: MTTouchVector }
public struct MTTouch: Sendable {
    public var frame: Int32
    public var timestamp: Double
    public var identifier: Int32
    public var state: Int32 // 3 = MakeTouch, 4 = Touching, 7 = BreakTouch
    public var fingerId: Int32
    public var handId: Int32
    public var normalizedPosition: MTTouchReadout
    public var size: Float
    public var field9: Int32
    public var angle: Float
    public var majorAxis: Float
    public var minorAxis: Float
    public var absolutePosition: MTTouchReadout
    public var field14: Int32
    public var field15: Int32
    public var density: Float
}

public typealias MTDeviceRef = UnsafeMutableRawPointer
public typealias MTContactCallbackFunction = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
) -> Int32

private typealias MTDeviceCreateListFunc = @convention(c) () -> Unmanaged<CFArray>?
private typealias MTRegisterContactFrameCallbackFunc = @convention(c) (MTDeviceRef, MTContactCallbackFunction) -> Void
private typealias MTDeviceStartFunc = @convention(c) (MTDeviceRef, Int32) -> Void
private typealias MTDeviceStopFunc = @convention(c) (MTDeviceRef) -> Void

private final class DisplayLinkTarget: NSObject, @unchecked Sendable {
    weak var controller: ScrollController?
    init(_ controller: ScrollController) {
        self.controller = controller
    }
    @objc func onTick(_ link: CADisplayLink) {
        let ts = link.targetTimestamp
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                controller?.displayLinkFired(timestamp: ts)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.controller?.displayLinkFired(timestamp: ts)
            }
        }
    }
}

/// Analytical 120Hz harmonic spring physics solver.
/// Unconditionally stable across variable frame rates (80-120Hz ProMotion).
public struct SpringState: Sendable {
    public var position: CGFloat = 0
    public var velocity: CGFloat = 0
    public var target: CGFloat = 0
    public var response: CGFloat = 0.22 // ~220ms perceptual response
    public var dampingRatio: CGFloat = 0.92 // Crisp snap without oscillation
    
    public var isAtRest: Bool {
        abs(target - position) < 0.40 && abs(velocity) < 3.5
    }
    
    public init(position: CGFloat = 0, velocity: CGFloat = 0, target: CGFloat = 0) {
        self.position = position
        self.velocity = velocity
        self.target = target
    }
    
    public mutating func step(dt: CGFloat) {
        let clampedDt = min(max(dt, 0.001), 0.033)
        let omega = (2.0 * .pi) / max(0.05, response)
        let f = 1.0 + 2.0 * clampedDt * dampingRatio * omega
        let oo = omega * omega
        let hoo = clampedDt * oo
        let hhoo = clampedDt * hoo
        let detInv = 1.0 / (f + hhoo)
        let detX = f * position + clampedDt * velocity + hhoo * target
        let detV = velocity + hoo * (target - position)
        position = detX * detInv
        velocity = detV * detInv
        if isAtRest {
            position = target
            velocity = 0
        }
    }
}

/// Backward compatibility critically-damped spring oscillator.
public struct CriticallyDampedSpring: Sendable {
    public private(set) var target: CGFloat
    private var x0: CGFloat = 0.0
    private var v0: CGFloat = 0.0
    private var t0: CFTimeInterval = 0.0
    public var omega: CGFloat = 19.0
    
    public init(at value: CGFloat) {
        self.target = value
        self.x0 = 0.0
        self.v0 = 0.0
        self.t0 = CACurrentMediaTime()
    }
    
    public func sample(_ now: CFTimeInterval) -> (pos: CGFloat, vel: CGFloat) {
        let t = CGFloat(max(0, now - t0))
        let e = exp(-omega * t)
        let b = v0 + omega * x0
        let pos = target + (x0 + b * t) * e
        let vel = (v0 - omega * b * t) * e
        return (pos, vel)
    }
    
    public mutating func retarget(to newTarget: CGFloat, now: CFTimeInterval, extraVelocity: CGFloat = 0) {
        let s = sample(now)
        target = newTarget
        x0 = s.pos - newTarget
        v0 = s.vel + extraVelocity
        t0 = now
    }
    
    public func isSettled(_ now: CFTimeInterval) -> Bool {
        let s = sample(now)
        return abs(s.pos - target) < 0.35 && abs(s.vel) < 3.0
    }
}

/// Gesture ownership state to latch decisions once per gesture and prevent half-consumed events.
public enum GestureOwner: Sendable {
    case undecided
    case strip
    case app
}

/// Why the viewport moved. The HUD uses this to distinguish a genuine scroll gesture from a
/// programmatic layout sync: only the former should reveal the auto-hiding panel.
public enum ScrollActivitySource: Sendable, Equatable {
    case user
    case momentum
    case programmatic
}

/// Controls smooth horizontal viewport scrolling, easing animations, snapping,
/// and intercepts 3/4-finger multitouch and 2-finger continuous trackpad swipe gestures.
/// Driven by macOS CADisplayLink at 80-120Hz ProMotion and an analytical harmonic spring solver.
@MainActor
public final class ScrollController {
    
    // Callbacks
    public var onViewportOffsetChanged: ((CGFloat) -> Void)?
    public var onScrollDeltaReceived: ((CGFloat) -> Void)?
    public var onScrollActivity: ((CGFloat, CGFloat, CGFloat) -> Void)? // offset, maxOffset, velocity
    public var onSettleRequested: ((CGFloat) -> Void)? // projectedOffset
    public var onFrameStep: ((_ currentOffset: CGFloat, _ isInteractive: Bool) -> Void)?
    public var onSwipeSettled: ((_ projectedOffset: CGFloat) -> Void)?
    public var onAnimationCompleted: (() -> Void)?
    public var onQueryMaxOffset: (() -> CGFloat)?
    /// Fired once each time the viewport crosses the seam of the cyclic strip while the
    /// user is driving it, in either direction. Never fires in non-loop mode, and never
    /// on the whole-period re-basing that only happens at rest (that is invisible).
    public var onLoopSeamCrossed: (() -> Void)?
    
    // Viewport & Physics State
    public private(set) var currentOffset: CGFloat = 0.0
    public private(set) var currentVelocity: CGFloat = 0.0
    public private(set) var smoothTargetOffset: CGFloat = 0.0
    public private(set) var settleVelocity: CGFloat = 0.0
    public var maxOffset: CGFloat = 0.0
    public var isLoopModeEnabled: Bool = false
    public var loopPeriod: CGFloat = 0.0
    
    public var springState: SpringState = SpringState()
    public private(set) var isSwipingInteractively: Bool = false
    public private(set) var isSpringAnimating: Bool = false
    public private(set) var isMomentumCoasting: Bool = false
    /// Source of the most recent `onScrollActivity` emission. Read synchronously by the
    /// callback's owner to decide whether the event was user-driven.
    public private(set) var lastActivitySource: ScrollActivitySource = .programmatic
    private var springSource: ScrollActivitySource = .programmatic
    
    public var isMoving: Bool {
        isActivelyScrolling || isMomentumCoasting || isSpringAnimating || !springState.isAtRest || isSwipingInteractively
    }
    
    private var spring: CriticallyDampedSpring = CriticallyDampedSpring(at: 0.0)
    
    private var lastScrollTime: CFTimeInterval = 0
    private var lastInputTimestamp: CFTimeInterval = 0
    private var lastFrameTimestamp: CFTimeInterval = 0
    private var pendingDelta: CGFloat = 0.0
    private var pendingInteractiveDelta: CGFloat = 0.0
    private var lastPhase: Int64 = 0
    private var lastMomentumPhase: Int64 = 0
    private var hasPendingSettle: Bool = false
    
    private var settleTimer: Timer?
    private var momentumWatchdogTimer: Timer?
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: DisplayLinkTarget?
    private var fallbackTimer: Timer?
    
    public private(set) var isActivelyScrolling: Bool = false
    public private(set) var gestureOwner: GestureOwner = .undecided
    private var lastScrollEventTime: CFTimeInterval = 0
    
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    // Multitouch tracking state
    private static weak var activeController: ScrollController?
    private static let isMultitouchTrackingActive = OSAllocatedUnfairLock(initialState: false)
    private var mtDevices: [MTDeviceRef] = []
    private var lastTouchCentroidX: Double?
    private var lastTouchCentroidY: Double?
    private var lastTouchCount: Int = 0
    private var mtLibHandle: UnsafeMutableRawPointer?
    private var mtStopFunc: MTDeviceStopFunc?
    
    // MARK: - Loop Mode Geometry
    
    /// Maps any loop-mode offset into the canonical cycle `0 ..< period`.
    ///
    /// Loop mode treats the strip as a circle: `offset` and `offset + period` describe
    /// the same visual state. Resting offsets are folded into one cycle so a long
    /// session cannot accumulate magnitudes that lose sub-pixel precision.
    ///
    /// - Returns: The equivalent offset in `0 ..< period`, or `0` when no valid cycle
    ///   exists (`period <= 0`, a non-finite period, or a non-finite input).
    nonisolated public static func normalizedOffset(_ offset: CGFloat, period: CGFloat) -> CGFloat {
        guard offset.isFinite, period.isFinite, period > 0 else { return 0 }
        var normalized = offset.truncatingRemainder(dividingBy: period)
        if normalized < 0 { normalized += period }
        // Adding `period` to a tiny negative remainder can round up to exactly
        // `period`; fold that edge case back onto the start of the cycle.
        guard normalized >= 0, normalized < period else { return 0 }
        // Canonicalise -0.0 so callers never observe a signed zero.
        return normalized == 0 ? 0 : normalized
    }
    
    private var hasUsableLoopPeriod: Bool {
        isLoopModeEnabled && loopPeriod.isFinite && loopPeriod > 0
    }
    
    /// True when an offset movement steps over a lap boundary of the cyclic strip.
    ///
    /// Offsets are compared by lap index rather than by sign, so the check survives a
    /// backwards wrap past zero and a single frame that spans more than one lap. A
    /// non-finite or non-positive period has no seam and never crosses.
    nonisolated public static func crossedLoopSeam(
        from oldOffset: CGFloat,
        to newOffset: CGFloat,
        period: CGFloat
    ) -> Bool {
        guard oldOffset.isFinite, newOffset.isFinite, period.isFinite, period > 0 else { return false }
        return floor(oldOffset / period) != floor(newOffset / period)
    }
    
    /// Announces a completed lap to `onLoopSeamCrossed`, if one happened in this step.
    private func notifyLoopSeamCrossing(from oldOffset: CGFloat, to newOffset: CGFloat) {
        guard hasUsableLoopPeriod else { return }
        guard Self.crossedLoopSeam(from: oldOffset, to: newOffset, period: loopPeriod) else { return }
        onLoopSeamCrossed?()
    }
    
    /// Folds `offset` into the loop cycle, or returns it unchanged when loop mode is
    /// off or has no usable period yet.
    private func loopWrappedOffset(_ offset: CGFloat) -> CGFloat {
        hasUsableLoopPeriod ? Self.normalizedOffset(offset, period: loopPeriod) : offset
    }
    
    /// Re-bases a stationary offset by whole loop periods.
    ///
    /// Only call when motion has stopped: shifting by exactly one period renders
    /// identically in loop layout, so this cannot produce a visible jump. Observers
    /// are notified because callers such as `WorkspaceManager` cache the last
    /// emitted viewport offset.
    @discardableResult
    private func normalizeLoopOffsetAtRest(notify: Bool = true) -> Bool {
        guard hasUsableLoopPeriod else { return false }
        let normalized = Self.normalizedOffset(currentOffset, period: loopPeriod)
        // Shift every related value by the same whole number of periods so a pending
        // glide or spring offset is preserved rather than collapsed on settle.
        let shift = normalized - currentOffset
        guard shift.isFinite, shift != 0 else { return false }
        currentOffset = normalized
        smoothTargetOffset += shift
        springState.position += shift
        springState.target += shift
        if notify { onViewportOffsetChanged?(normalized) }
        return true
    }
    
    /// Keeps an animated target within half a period of `currentOffset`, choosing the
    /// nearest equivalent position on the cycle.
    ///
    /// Whole periods are visually identical in loop mode, so dropping them keeps
    /// `springState.target` bounded and stops a snap or shortcut from animating a
    /// pointless full lap around the strip.
    private func loopTarget(near current: CGFloat, target: CGFloat) -> CGFloat {
        guard hasUsableLoopPeriod else { return target }
        guard current.isFinite, target.isFinite else { return current }
        let currentPhase = Self.normalizedOffset(current, period: loopPeriod)
        let targetPhase = Self.normalizedOffset(target, period: loopPeriod)
        var delta = targetPhase - currentPhase
        if delta > loopPeriod / 2 {
            delta -= loopPeriod
        } else if delta < -(loopPeriod / 2) {
            delta += loopPeriod
        }
        return current + delta
    }
    
    /// Position is stationary even if a stale velocity is still stored.
    private var isPositionAtRest: Bool {
        !isSpringAnimating && !isMomentumCoasting && !isActivelyScrolling && !isSwipingInteractively
            && abs(smoothTargetOffset - currentOffset) <= 0.05
    }
    
    public init() {
        setupDisplayLink()
    }
    
    isolated deinit {
        displayLink?.invalidate()
        fallbackTimer?.invalidate()
        settleTimer?.invalidate()
        momentumWatchdogTimer?.invalidate()
        stopMultitouchMonitoring()
    }
    
    // MARK: - Display Link Setup & Pacing (80-120Hz ProMotion)
    
    private func setupDisplayLink() {
        guard displayLink == nil else { return }
        let target = DisplayLinkTarget(self)
        self.displayLinkTarget = target
        if let screen = NSScreen.main {
            let link = screen.displayLink(target: target, selector: #selector(DisplayLinkTarget.onTick(_:)))
            if #available(macOS 14.0, *) {
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            }
            link.add(to: .main, forMode: .common)
            link.isPaused = true
            self.displayLink = link
        }
    }
    
    public func attachDisplayLink(to screen: NSScreen) {
        displayLink?.invalidate()
        let target = DisplayLinkTarget(self)
        self.displayLinkTarget = target
        let link = screen.displayLink(target: target, selector: #selector(DisplayLinkTarget.onTick(_:)))
        if #available(macOS 14.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        }
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        self.displayLink = link
    }
    
    private func resumeDisplayLink() {
        lastInputTimestamp = CACurrentMediaTime()
        if let link = displayLink {
            link.isPaused = false
        } else if NSScreen.main != nil {
            setupDisplayLink()
            displayLink?.isPaused = false
        } else {
            // Headless / test fallback timer (120Hz)
            if fallbackTimer == nil {
                let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.displayLinkFired()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.fallbackTimer = timer
            }
        }
    }
    
    private func pauseDisplayLink() {
        displayLink?.isPaused = true
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        lastFrameTimestamp = 0
    }
    
    // MARK: - Hardware VSYNC Tick (120Hz ProMotion)
    
    public func displayLinkFired(timestamp: CFTimeInterval? = nil) {
        let now = timestamp ?? CACurrentMediaTime()
        let dt = lastFrameTimestamp == 0 ? (1.0 / 120.0) : CGFloat(now - lastFrameTimestamp)
        lastFrameTimestamp = now
        // Seam detection needs the position before this frame touched it, since a lap can
        // complete inside any one of the motion branches below.
        let offsetAtFrameStart = currentOffset
        
        var didWork = false
        
        // 1. Direct manipulation 3/4 finger multitouch swipes (paced at 120Hz VSYNC)
        if isSwipingInteractively {
            if abs(pendingInteractiveDelta) > 0.0001 {
                didWork = true
                let deltaX = pendingInteractiveDelta
                pendingInteractiveDelta = 0.0
                
                let dtSwipe = max(0.004, CGFloat(now - lastInputTimestamp))
                lastInputTimestamp = now
                
                var nextOffset = springState.position + deltaX
                if !isLoopModeEnabled {
                    let rubberLimit: CGFloat = 180.0
                    if nextOffset < 0 {
                        let overshoot = -nextOffset
                        let resistance = max(0.12, 1.0 - (overshoot / rubberLimit))
                        nextOffset = springState.position + (deltaX * resistance)
                    } else if nextOffset > self.maxOffset {
                        let overshoot = nextOffset - self.maxOffset
                        let resistance = max(0.12, 1.0 - (overshoot / rubberLimit))
                        nextOffset = springState.position + (deltaX * resistance)
                    }
                }
                
                let instantVelocity = (nextOffset - springState.position) / dtSwipe
                springState.velocity = (0.65 * springState.velocity) + (0.35 * instantVelocity)
                springState.position = nextOffset
                springState.target = nextOffset
                currentOffset = nextOffset
                currentVelocity = springState.velocity
                notifyLoopSeamCrossing(from: offsetAtFrameStart, to: currentOffset)
                
                onViewportOffsetChanged?(currentOffset)
                onFrameStep?(currentOffset, true)
                emitScrollActivity(
                    offset: currentOffset,
                    maxOffset: self.maxOffset,
                    velocity: currentVelocity,
                    source: .user
                )
            }
            
            if (now - lastInputTimestamp) > 0.11 {
                endInteractiveSwipe(maxOffset: maxOffset)
            }
            return
        }
        
        // 2. Process continuous trackpad gesture deltas with frame-rate independent direct tracking & momentum
        let hasPendingDelta = abs(pendingDelta) > 0.001
        let isDirectTouch = (lastPhase == 1 || lastPhase == 2) && lastMomentumPhase == 0 && (now - lastInputTimestamp) <= 0.12
        let isGlidingToTarget = isActivelyScrolling && abs(smoothTargetOffset - currentOffset) > 0.05
        
        if hasPendingDelta || isGlidingToTarget || isMomentumCoasting {
            didWork = true
            
            if hasPendingDelta {
                let effectiveDelta = pendingDelta
                pendingDelta = 0.0
                
                lastInputTimestamp = now
                let dtScroll: CGFloat = (lastScrollTime == 0) ? (1.0 / 120.0) : min(max(0.004, CGFloat(now - lastScrollTime)), 0.05)
                lastScrollTime = now
                
                let instVelocity = effectiveDelta / dtScroll
                let alpha: CGFloat = 0.65
                currentVelocity = (currentVelocity == 0) ? instVelocity : (currentVelocity * alpha + instVelocity * (1.0 - alpha))
                
                // Continuous rubber-banded resistance past boundaries applied to smoothTargetOffset
                var nextTarget = smoothTargetOffset + effectiveDelta
                if !isLoopModeEnabled {
                    if SettingsStore.shared.freezeOnRelease {
                        nextTarget = min(max(0, nextTarget), maxOffset)
                    } else {
                        let rubberLimit: CGFloat = 200.0
                        if nextTarget < 0 {
                            let overshoot = -nextTarget
                            let resistance = max(0.10, 1.0 - (overshoot / rubberLimit))
                            nextTarget = smoothTargetOffset + (effectiveDelta * resistance)
                        } else if nextTarget > maxOffset {
                            let overshoot = nextTarget - maxOffset
                            let resistance = max(0.10, 1.0 - (overshoot / rubberLimit))
                            nextTarget = smoothTargetOffset + (effectiveDelta * resistance)
                        }
                    }
                }
                smoothTargetOffset = nextTarget
            }
            
            let isMacOSMomentum = (lastMomentumPhase == 1 || lastMomentumPhase == 2)
            
            if isDirectTouch || isMacOSMomentum {
                // Direct 1:1 manipulation during physical touch or native macOS momentum stream!
                // Zero input lag, instant response, perfectly synchronized!
                currentOffset = smoothTargetOffset
                springState.position = currentOffset
                springState.target = currentOffset
                springState.velocity = currentVelocity
                notifyLoopSeamCrossing(from: offsetAtFrameStart, to: currentOffset)
            } else if isMomentumCoasting {
                // Inertial momentum coasting (continues like web scrolling in Safari / Chrome)
                let friction: CGFloat = 0.965
                let decay = pow(friction, dt * 60.0)
                currentVelocity *= decay
                smoothTargetOffset += currentVelocity * dt
                currentOffset = smoothTargetOffset
                springState.position = currentOffset
                springState.target = currentOffset
                springState.velocity = currentVelocity
                // Announced here rather than at the end of the frame: either early return
                // below can stop the coast, and the lap is already complete.
                notifyLoopSeamCrossing(from: offsetAtFrameStart, to: currentOffset)
                
                // Overshoot resistance during momentum coasting
                if !isLoopModeEnabled && (currentOffset < 0 || currentOffset > maxOffset) {
                    currentVelocity *= pow(0.85, dt * 60.0)
                    if abs(currentVelocity) < 35.0 {
                        isMomentumCoasting = false
                        settle()
                        return
                    }
                }
                
                if abs(currentVelocity) < 20.0 {
                    isMomentumCoasting = false
                    settle()
                    return
                }
            } else {
                let smoothness = SettingsStore.shared.scrollSmoothness
                let offsetDiff = smoothTargetOffset - currentOffset
                
                if smoothness <= 0.05 {
                    // Smoothness at minimum: track exactly with zero lag.
                    currentOffset = smoothTargetOffset
                    springState.position = currentOffset
                    springState.target = currentOffset
                    springState.velocity = currentVelocity
                } else {
                    // Trackpad contact, native momentum, notched wheels and the post-gesture
                    // coasting all run through the same filter. Trackpad events arrive in
                    // irregular bursts (0, 1 or 2 per 120 Hz frame), so tracking them raw makes
                    // the window motion stutter; the filter turns that into continuous motion.
                    // The time constant is the Smoothness control, and 0.05 bypasses the filter
                    // entirely for an exact 1:1 feel.
                    let lambda = max(28.0, 35.0 + CGFloat(1.0 - smoothness) * 80.0)
                    let factor = 1.0 - exp(-lambda * dt)
                    let step = offsetDiff * factor
                    
                    currentOffset += step
                    let frameVelocity = step / max(0.001, dt)
                    let alpha: CGFloat = min(0.85, max(0.40, 0.45 + CGFloat(smoothness) * 0.35))
                    currentVelocity = (currentVelocity == 0) ? frameVelocity : (currentVelocity * alpha + frameVelocity * (1.0 - alpha))
                    
                    if abs(smoothTargetOffset - currentOffset) < 0.05 {
                        currentOffset = smoothTargetOffset
                    }
                    springState.position = currentOffset
                    springState.target = smoothTargetOffset
                    springState.velocity = currentVelocity
                }
                
                notifyLoopSeamCrossing(from: offsetAtFrameStart, to: currentOffset)
            }
            
            onViewportOffsetChanged?(currentOffset)
            onFrameStep?(currentOffset, true)
            emitScrollActivity(
                offset: currentOffset,
                maxOffset: maxOffset,
                velocity: currentVelocity,
                source: isMomentumCoasting ? .momentum : .user
            )
        }
        
        // 3. Gesture completion / settle trigger
        if hasPendingSettle {
            let settings = SettingsStore.shared
            if !settings.snapToColumn && abs(smoothTargetOffset - currentOffset) > 0.2 {
                // If snap is disabled, allow the remaining glide to complete smoothly before settling
            } else {
                hasPendingSettle = false
                settle()
                return
            }
        }
        
        // 4. Spring physics interpolation (harmonic oscillator)
        if isSpringAnimating {
            didWork = true
            springState.step(dt: dt)
            currentOffset = isLoopModeEnabled ? springState.position : min(max(0, springState.position), maxOffset)
            currentVelocity = springState.velocity
            // User-aimed springs (flick settle, keyboard scroll) can finish a lap too.
            // Programmatic springs are layout syncs and stay silent.
            if springSource != .programmatic {
                notifyLoopSeamCrossing(from: offsetAtFrameStart, to: currentOffset)
            }
            
            onViewportOffsetChanged?(currentOffset)
            onFrameStep?(currentOffset, false)
            emitScrollActivity(
                offset: currentOffset,
                maxOffset: maxOffset,
                velocity: currentVelocity,
                source: springSource
            )
            
            if springState.isAtRest {
                currentOffset = springState.target
                // The spring has stopped, so a whole-period shift is invisible.
                normalizeLoopOffsetAtRest(notify: false)
                smoothTargetOffset = currentOffset
                currentVelocity = 0.0
                isSpringAnimating = false
                onViewportOffsetChanged?(currentOffset)
                onFrameStep?(currentOffset, false)
                emitScrollActivity(
                    offset: currentOffset,
                    maxOffset: maxOffset,
                    velocity: 0.0,
                    source: springSource
                )
                onAnimationCompleted?()
            }
        }
        
        // Keep display link active for 0.5s following last input to prevent ProMotion downclocking
        if !didWork && !isActivelyScrolling && !isSpringAnimating && springState.isAtRest && !isSwipingInteractively && abs(smoothTargetOffset - currentOffset) <= 0.05 {
            if (CACurrentMediaTime() - lastInputTimestamp) > 0.5 {
                // Last safe idle point: fold any stray unbounded offset (for example
                // from a client that drives the controller without a settle callback)
                // back into one cycle before the display link stops.
                normalizeLoopOffsetAtRest()
                pauseDisplayLink()
            }
        }
    }
    
    /// Tags every activity emission with who caused it. The HUD reads `lastActivitySource`
    /// inside the callback to keep programmatic layout syncs from revealing the panel.
    private func emitScrollActivity(
        offset: CGFloat,
        maxOffset: CGFloat,
        velocity: CGFloat,
        source: ScrollActivitySource
    ) {
        lastActivitySource = source
        onScrollActivity?(offset, maxOffset, velocity)
    }

    // MARK: - Direct Offset Update
    
    public func setOffset(_ offset: CGFloat, maxOffset: CGFloat) {
        cancelAnimation()
        self.maxOffset = max(0, maxOffset)
        currentOffset = isLoopModeEnabled ? loopWrappedOffset(offset) : min(max(0, offset), self.maxOffset)
        smoothTargetOffset = currentOffset
        currentVelocity = 0.0
        springState.position = currentOffset
        springState.target = currentOffset
        springState.velocity = 0.0
        onViewportOffsetChanged?(currentOffset)
        onFrameStep?(currentOffset, false)
        emitScrollActivity(
            offset: currentOffset,
            maxOffset: self.maxOffset,
            velocity: 0.0,
            source: .programmatic
        )
    }
    
    // MARK: - Animated Scroll (Harmonic Spring Solver)
    
    public func scrollTo(
        target: CGFloat,
        maxOffset: CGFloat,
        duration: Double = 0.18,
        initialVelocity: CGFloat = 0.0,
        source: ScrollActivitySource = .programmatic
    ) {
        springSource = source
        self.maxOffset = max(0, maxOffset)
        // An idle call is a safe place to fold the current position into one cycle.
        // Do not notify here: every path below emits the resolved offset itself.
        if isPositionAtRest {
            normalizeLoopOffsetAtRest(notify: false)
        }
        let clampedTarget: CGFloat
        if isLoopModeEnabled {
            clampedTarget = loopTarget(near: currentOffset, target: target)
        } else {
            clampedTarget = min(max(0, target), self.maxOffset)
        }
        smoothTargetOffset = clampedTarget
        guard abs(currentOffset - clampedTarget) > 0.5 else {
            currentOffset = clampedTarget
            springState.position = clampedTarget
            springState.target = clampedTarget
            springState.velocity = 0
            isSpringAnimating = false
            onViewportOffsetChanged?(currentOffset)
            onFrameStep?(currentOffset, false)
            emitScrollActivity(
                offset: currentOffset,
                maxOffset: self.maxOffset,
                velocity: 0.0,
                source: source
            )
            onAnimationCompleted?()
            return
        }
        
        let initVel: CGFloat
        if initialVelocity != 0.0 {
            initVel = initialVelocity
            settleVelocity = 0.0
        } else if settleVelocity != 0.0 {
            initVel = settleVelocity
            settleVelocity = 0.0
        } else {
            initVel = 0.0
        }
        
        cancelAnimation()
        
        let now = CACurrentMediaTime()
        lastInputTimestamp = now
        lastFrameTimestamp = now
        
        let smoothness = SettingsStore.shared.scrollSmoothness
        springState.target = clampedTarget
        springState.position = currentOffset
        springState.velocity = initVel
        let baseResp = duration > 0 ? CGFloat(duration) : 0.18
        springState.response = max(0.08, baseResp * (0.70 + CGFloat(smoothness) * 0.40))
        springState.dampingRatio = max(0.88, 0.98 - CGFloat(smoothness) * 0.10)
        self.isSpringAnimating = true
        
        // Frame 0 execution: immediate visual response to user action (0ms latency)
        springState.step(dt: 1.0 / 120.0)
        currentOffset = isLoopModeEnabled ? springState.position : min(max(0, springState.position), self.maxOffset)
        currentVelocity = springState.velocity
        onViewportOffsetChanged?(currentOffset)
        onFrameStep?(currentOffset, false)
        emitScrollActivity(
            offset: currentOffset,
            maxOffset: self.maxOffset,
            velocity: currentVelocity,
            source: source
        )
        
        resumeDisplayLink()
    }
    
    public func animateToOffset(_ targetOffset: CGFloat) {
        scrollTo(target: targetOffset, maxOffset: maxOffset)
    }
    
    // MARK: - Incremental Scroll (Discrete / Shortcut Step)
    
    public func scrollBy(deltaX: CGFloat, maxOffset: CGFloat) {
        cancelAnimation()
        self.maxOffset = max(0, maxOffset)
        let proposedOffset = currentOffset + deltaX
        let newOffset = isLoopModeEnabled ? loopWrappedOffset(proposedOffset) : min(max(0, proposedOffset), self.maxOffset)
        guard newOffset != currentOffset else { return }
        let previousOffset = currentOffset
        currentOffset = newOffset
        // `newOffset` is already folded into the cycle, so the lap boundary is judged
        // against the unwrapped proposal instead.
        notifyLoopSeamCrossing(from: previousOffset, to: proposedOffset)
        smoothTargetOffset = currentOffset
        currentVelocity = 0.0
        springState.position = currentOffset
        springState.target = currentOffset
        springState.velocity = 0.0
        onViewportOffsetChanged?(currentOffset)
        onFrameStep?(currentOffset, false)
        emitScrollActivity(
            offset: currentOffset,
            maxOffset: self.maxOffset,
            velocity: 0.0,
            source: .user
        )
    }
    
    public func cancelAnimation() {
        isSpringAnimating = false
        isMomentumCoasting = false
        hasPendingSettle = false
        lastScrollTime = 0
        smoothTargetOffset = currentOffset
        settleVelocity = 0.0
        settleTimer?.invalidate()
        settleTimer = nil
        momentumWatchdogTimer?.invalidate()
        momentumWatchdogTimer = nil
        springState.position = currentOffset
        springState.target = currentOffset
        springState.velocity = 0.0
    }
    
    public func freezeAtCurrentOffset() {
        cancelAnimation()
        isActivelyScrolling = false
        isSwipingInteractively = false
        currentVelocity = 0.0
        pendingDelta = 0.0
        pendingInteractiveDelta = 0.0
    }

    // MARK: - Interactive Direct Manipulation (3/4 Finger Swipes)
    
    public func applyInteractiveDelta(_ deltaX: CGFloat, maxOffset: CGFloat, timestamp: CFTimeInterval) {
        lastInputTimestamp = timestamp
        isSwipingInteractively = true
        isActivelyScrolling = true
        cancelAnimation()
        
        self.maxOffset = max(0, maxOffset)
        pendingInteractiveDelta += deltaX
        resumeDisplayLink()
    }
    
    public func endInteractiveSwipe(maxOffset: CGFloat) {
        guard isSwipingInteractively else { return }
        isSwipingInteractively = false
        isActivelyScrolling = false
        self.maxOffset = max(0, maxOffset)
        if SettingsStore.shared.freezeOnRelease {
            freezeAtCurrentOffset()
            onSwipeSettled?(currentOffset)
            onSettleRequested?(currentOffset)
            return
        }
        // The finger has lifted: the strip is stationary, so fold the unbounded
        // gesture offset into one cycle before projecting momentum and snapping.
        // The spring velocity is left untouched so the projection is unchanged.
        normalizeLoopOffsetAtRest()
        let projected = isLoopModeEnabled ? (springState.position + (springState.velocity * 0.16)) : min(max(0, springState.position + (springState.velocity * 0.16)), self.maxOffset)
        onSwipeSettled?(projected)
        onSettleRequested?(projected)
    }
    
    // MARK: - Continuous 2-Finger Trackpad Gesture Queueing (High-Speed & Non-Blocking)
    
    public func enqueueScroll(
        dx: CGFloat,
        dy: CGFloat,
        phase: Int64,
        momentumPhase: Int64,
        flags: CGEventFlags
    ) {
        let settings = SettingsStore.shared
        let naturalMultiplier: CGFloat = settings.trackpadNaturalScroll ? -1.0 : 1.0
        let sensitivity = CGFloat(settings.scrollSensitivity)
        
        let hasModifier = flags.contains(.maskAlternate) || flags.contains(.maskControl)
        let primaryDelta: CGFloat
        if abs(dx) >= abs(dy) {
            primaryDelta = dx
        } else if hasModifier || settings.scrollTriggerMode != .seamlessHorizontal {
            primaryDelta = dy
        } else {
            primaryDelta = dx
        }
        let effectiveDelta = primaryDelta * naturalMultiplier * sensitivity
        
        lastPhase = phase
        lastMomentumPhase = momentumPhase
        
        // Handle freezeOnRelease or disabled momentum
        if momentumPhase != 0 {
            if settings.freezeOnRelease || !settings.momentumScrolling {
                if momentumPhase == 4 {
                    isActivelyScrolling = false
                    momentumWatchdogTimer?.invalidate()
                    momentumWatchdogTimer = nil
                    hasPendingSettle = true
                    resumeDisplayLink()
                }
                return
            }
        }
        
        if settings.freezeOnRelease && (phase == 4 || phase == 8) {
            freezeAtCurrentOffset()
            if momentumPhase == 4 {
                hasPendingSettle = true
                resumeDisplayLink()
            } else {
                momentumWatchdogTimer?.invalidate()
                momentumWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        if self.lastMomentumPhase == 0 {
                            self.settle()
                        }
                    }
                }
            }
            return
        }
        
        // Active scroll or momentum: cancel running springs and watchdogs
        if phase == 1 {
            cancelAnimation()
            isActivelyScrolling = true
            currentVelocity = 0.0
            lastScrollTime = 0
            smoothTargetOffset = currentOffset
            if let queryMax = onQueryMaxOffset?() {
                self.maxOffset = queryMax
            }
        } else if phase == 2 || momentumPhase == 1 || momentumPhase == 2 {
            cancelAnimation()
            isActivelyScrolling = true
        } else if phase == 0 && momentumPhase == 0 && !isActivelyScrolling {
            if let queryMax = onQueryMaxOffset?() {
                self.maxOffset = queryMax
            }
        }
        
        pendingDelta += effectiveDelta
        
        resumeDisplayLink()
        
        // 1. Physical finger lift (phase 4 = Ended)
        if phase == 4 {
            if momentumPhase == 0 {
                if abs(currentVelocity) > 25 && settings.momentumScrolling {
                    momentumWatchdogTimer?.invalidate()
                    momentumWatchdogTimer = nil
                    isMomentumCoasting = true
                    resumeDisplayLink()
                } else if settings.momentumScrolling {
                    // Adaptive grace period (90ms) for macOS trackpad momentum stream to kick in before settling
                    momentumWatchdogTimer?.invalidate()
                    momentumWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.090, repeats: false) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            if self.lastMomentumPhase == 0 && !self.isMomentumCoasting {
                                if abs(self.currentVelocity) > 30.0 {
                                    self.isMomentumCoasting = true
                                    self.resumeDisplayLink()
                                } else {
                                    self.hasPendingSettle = true
                                }
                            }
                        }
                    }
                } else {
                    momentumWatchdogTimer?.invalidate()
                    momentumWatchdogTimer = nil
                    hasPendingSettle = true
                }
            } else if momentumPhase == 4 {
                momentumWatchdogTimer?.invalidate()
                momentumWatchdogTimer = nil
                hasPendingSettle = true
            }
        } else if phase == 8 {
            // Cancelled
            momentumWatchdogTimer?.invalidate()
            momentumWatchdogTimer = nil
            hasPendingSettle = true
        } else if momentumPhase == 4 {
            // macOS Momentum ended
            momentumWatchdogTimer?.invalidate()
            momentumWatchdogTimer = nil
            hasPendingSettle = true
        }
        
        // 2. Discrete mouse wheel debounce
        if phase == 0 && momentumPhase == 0 {
            if !isActivelyScrolling {
                smoothTargetOffset = currentOffset
            }
            isActivelyScrolling = true
            settleTimer?.invalidate()
            let smoothness = SettingsStore.shared.scrollSmoothness
            let settleDelay = 0.10 + (smoothness * 0.08)
            settleTimer = Timer.scheduledTimer(withTimeInterval: settleDelay, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.settle()
                }
            }
        }
    }
    
    public func accumulateScroll(dx: CGFloat, dy: CGFloat, phase: Int64, momentumPhase: Int64, flags: CGEventFlags) {
        enqueueScroll(
            dx: dx,
            dy: dy,
            phase: phase,
            momentumPhase: momentumPhase,
            flags: flags
        )
    }
    
    public func handleContinuousScrollDelta(
        dx: CGFloat,
        dy: CGFloat,
        phase: Int64,
        momentumPhase: Int64,
        flags: CGEventFlags
    ) {
        enqueueScroll(
            dx: dx,
            dy: dy,
            phase: phase,
            momentumPhase: momentumPhase,
            flags: flags
        )
    }
    
    // MARK: - Settle / Snapping
    
    public func settle() {
        settleTimer?.invalidate()
        settleTimer = nil
        momentumWatchdogTimer?.invalidate()
        momentumWatchdogTimer = nil
        lastScrollTime = 0
        isActivelyScrolling = false
        isMomentumCoasting = false
        gestureOwner = .undecided
        pendingDelta = 0.0
        
        if let queryMax = onQueryMaxOffset?() {
            self.maxOffset = queryMax
        }
        
        // Motion has stopped. Fold the accumulated offset into one cycle before the
        // projection/snap math below, so neither the snap target nor the spring can
        // carry an unbounded magnitude into a long session.
        normalizeLoopOffsetAtRest()
        
        let settings = SettingsStore.shared
        
        if settings.freezeOnRelease {
            smoothTargetOffset = currentOffset
            currentVelocity = 0.0
            settleVelocity = 0.0
            onSettleRequested?(currentOffset)
            onSwipeSettled?(currentOffset)
            onAnimationCompleted?()
            return
        }
        
        // Overshot boundaries: spring back smoothly (linear strip only)
        if !isLoopModeEnabled {
            if currentOffset < 0 {
                scrollTo(target: 0, maxOffset: maxOffset, duration: settings.animationDuration, initialVelocity: currentVelocity, source: .user)
                return
            }
            if currentOffset > maxOffset {
                scrollTo(target: maxOffset, maxOffset: maxOffset, duration: settings.animationDuration, initialVelocity: currentVelocity, source: .user)
                return
            }
        }
        
        if settings.snapToColumn {
            let base = abs(smoothTargetOffset - currentOffset) > 0.5 ? smoothTargetOffset : currentOffset
            let projection = base + currentVelocity * 0.18
            let preservedVelocity = currentVelocity
            settleVelocity = preservedVelocity
            currentVelocity = 0.0
            onSettleRequested?(projection)
            onSwipeSettled?(projection)
        } else {
            smoothTargetOffset = currentOffset
            currentVelocity = 0.0
            onAnimationCompleted?()
        }
    }
    
    // MARK: - Trackpad & Wheel Interception Tap
    
    public func shouldInterceptScroll(
        dx: CGFloat,
        dy: CGFloat,
        flags: CGEventFlags,
        phase: Int64 = 0,
        momentumPhase: Int64 = 0
    ) -> Bool {
        let settings = SettingsStore.shared
        let hasOption = flags.contains(.maskAlternate)
        let hasControl = flags.contains(.maskControl)
        
        let now = CACurrentMediaTime()
        // Watchdog: If 150ms elapsed without scroll events, reset stale gesture owner so scroll never locks out
        if lastScrollEventTime > 0 && (now - lastScrollEventTime) > 0.15 {
            gestureOwner = .undecided
            isActivelyScrolling = false
        }
        lastScrollEventTime = now
        
        // Touch began / touch may begin resets gesture ownership decision
        if phase == 1 || phase == 32 {
            gestureOwner = .undecided
        }
        
        // Explicit modifier shortcuts always override app ownership
        if hasOption || hasControl {
            gestureOwner = .strip
            return true
        }
        
        // If already latched to an owner for this gesture, check completion
        if gestureOwner == .strip {
            if phase == 4 || phase == 8 {
                // Finger lifted: only unlatch if no momentum stream will follow
                if momentumPhase == 4 || (momentumPhase == 0 && (!settings.momentumScrolling || abs(currentVelocity) <= 30)) {
                    gestureOwner = .undecided
                    isActivelyScrolling = false
                }
            } else if momentumPhase == 4 {
                gestureOwner = .undecided
                isActivelyScrolling = false
            }
            return true
        } else if gestureOwner == .app {
            if phase == 4 || phase == 8 || momentumPhase == 4 {
                gestureOwner = .undecided
            }
            // Allow breaking out of .app if the user switches decisively to horizontal scrolling
            let absX = abs(dx)
            let absY = abs(dy)
            if absX > 2.0 && absX > absY * 2.5 {
                gestureOwner = .strip
                return true
            }
            return false
        }
        
        let shouldStart: Bool
        switch settings.scrollTriggerMode {
        case .seamlessHorizontal:
            let absX = abs(dx)
            let absY = abs(dy)
            if isActivelyScrolling && gestureOwner == .strip {
                shouldStart = true
            } else {
                // Natural trackpad gesture detection: recognize natural start (> 0.2 pt)
                // while strictly rejecting vertical scrolling (absY > absX)
                shouldStart = (absX > absY * 1.15 && absX >= 0.20) || (absX >= 0.60 && absY < 0.40)
            }
            
        case .withOption:
            shouldStart = hasOption
            
        case .withControl:
            shouldStart = hasControl
            
        case .always:
            shouldStart = true
        }
        
        // Latch ownership once directional intent is clear
        if phase == 1 || phase == 2 || momentumPhase == 1 || momentumPhase == 2 {
            if shouldStart {
                gestureOwner = .strip
            } else if abs(dy) > 1.2 && abs(dy) > abs(dx) * 1.2 {
                gestureOwner = .app
            }
        }
        
        return shouldStart
    }
    
    public func shouldInterceptScroll(dx: CGFloat, dy: CGFloat, flags: CGEventFlags, phase: Int64 = 0) -> Bool {
        return shouldInterceptScroll(dx: dx, dy: dy, flags: flags, phase: phase, momentumPhase: 0)
    }
    
    public func startEventTap() {
        guard eventTap == nil else { return }
        let mask = (1 << CGEventType.scrollWheel.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<ScrollController>.fromOpaque(userInfo).takeUnretainedValue()
            
            // Self-healing watchdog: auto re-enable if macOS timed out tap
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = controller.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }
            
            var dx = CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))
            var dy = CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
            
            if dx == 0 && dy == 0 {
                dx = CGFloat(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) * 14.0
                dy = CGFloat(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * 14.0
            }
            
            let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            let flags = event.flags
            
            if controller.shouldInterceptScroll(dx: dx, dy: dy, flags: flags, phase: phase, momentumPhase: momentumPhase) {
                if Thread.isMainThread {
                    controller.enqueueScroll(
                        dx: dx,
                        dy: dy,
                        phase: phase,
                        momentumPhase: momentumPhase,
                        flags: flags
                    )
                } else {
                    DispatchQueue.main.async {
                        controller.enqueueScroll(
                            dx: dx,
                            dy: dy,
                            phase: phase,
                            momentumPhase: momentumPhase,
                            flags: flags
                        )
                    }
                }
                return nil // Consume event immediately (< 5 microseconds), non-blocking
            }
            
            return Unmanaged.passUnretained(event)
        }
        
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: selfPtr
        ) {
            self.eventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        
        startMultitouchMonitoring()
    }
    
    public func stopEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.runLoopSource = nil
        }
        stopMultitouchMonitoring()
        cancelAnimation()
    }
    
    // MARK: - MultitouchSupport Dynamic Integration (3 & 4 Finger 1:1 Swipes)
    
    public func startMultitouchMonitoring() {
        ScrollController.activeController = self
        guard mtDevices.isEmpty else { return }
        
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY) else {
            return
        }
        self.mtLibHandle = handle
        
        guard let symList = dlsym(handle, "MTDeviceCreateList"),
              let symRegister = dlsym(handle, "MTRegisterContactFrameCallback"),
              let symStart = dlsym(handle, "MTDeviceStart"),
              let symStop = dlsym(handle, "MTDeviceStop") else {
            return
        }
        
        let createList = unsafeBitCast(symList, to: MTDeviceCreateListFunc.self)
        let registerCallback = unsafeBitCast(symRegister, to: MTRegisterContactFrameCallbackFunc.self)
        let deviceStart = unsafeBitCast(symStart, to: MTDeviceStartFunc.self)
        self.mtStopFunc = unsafeBitCast(symStop, to: MTDeviceStopFunc.self)
        
        guard let deviceArrayRef = createList()?.takeRetainedValue(),
              let deviceList = deviceArrayRef as? [MTDeviceRef] else {
            return
        }
        
        let contactCallback: MTContactCallbackFunction = { _, touchesPtr, numTouches, timestamp, _ in
            guard let rawTouches = touchesPtr, numTouches > 0 else {
                let shouldEnd = ScrollController.isMultitouchTrackingActive.withLock { isTracking in
                    let wasTracking = isTracking
                    isTracking = false
                    return wasTracking
                }
                if shouldEnd {
                    DispatchQueue.main.async {
                        ScrollController.activeController?.handleMultitouchEnd(timestamp: timestamp)
                    }
                }
                return 0
            }
            
            let ptr = rawTouches.assumingMemoryBound(to: MTTouch.self)
            let buffer = UnsafeBufferPointer(start: ptr, count: Int(numTouches))
            var activeTouches: [MTTouch] = []
            for t in buffer {
                if t.state == 3 || t.state == 4 {
                    activeTouches.append(t)
                }
            }
            
            let count = activeTouches.count
            if count == 3 || count == 4 {
                ScrollController.isMultitouchTrackingActive.withLock { isTracking in
                    isTracking = true
                }
                let avgX = activeTouches.reduce(0.0) { $0 + Double($1.normalizedPosition.position.x) } / Double(count)
                let avgY = activeTouches.reduce(0.0) { $0 + Double($1.normalizedPosition.position.y) } / Double(count)
                DispatchQueue.main.async {
                    ScrollController.activeController?.handleMultitouchContact(avgX: avgX, avgY: avgY, count: count, timestamp: timestamp)
                }
            } else {
                let shouldEnd = ScrollController.isMultitouchTrackingActive.withLock { isTracking in
                    let wasTracking = isTracking
                    isTracking = false
                    return wasTracking
                }
                if shouldEnd {
                    DispatchQueue.main.async {
                        ScrollController.activeController?.handleMultitouchEnd(timestamp: timestamp)
                    }
                }
            }
            return 0
        }
        
        for dev in deviceList {
            registerCallback(dev, contactCallback)
            deviceStart(dev, 0)
            mtDevices.append(dev)
        }
    }
    
    public func stopMultitouchMonitoring() {
        if let stopFunc = mtStopFunc {
            for dev in mtDevices {
                stopFunc(dev)
            }
        }
        mtDevices.removeAll()
        if let handle = mtLibHandle {
            dlclose(handle)
            mtLibHandle = nil
        }
        lastTouchCentroidX = nil
        lastTouchCentroidY = nil
        lastTouchCount = 0
        ScrollController.isMultitouchTrackingActive.withLock { isTracking in
            isTracking = false
        }
        if ScrollController.activeController === self {
            ScrollController.activeController = nil
        }
    }
    
    private func handleMultitouchContact(avgX: Double, avgY: Double, count: Int, timestamp: Double) {
        // Prevent 200-400px centroid jump when finger count changes between 3 and 4
        guard count == lastTouchCount else {
            lastTouchCount = count
            lastTouchCentroidX = avgX
            lastTouchCentroidY = avgY
            return
        }
        if let lastX = lastTouchCentroidX, let lastY = lastTouchCentroidY {
            let deltaFractionX = CGFloat(avgX - lastX)
            let deltaFractionY = CGFloat(avgY - lastY)
            // Ignore vertical 3/4-finger swipes (Mission Control / App Exposé)
            if abs(deltaFractionX) > abs(deltaFractionY) * 1.15 && abs(deltaFractionX) > 0.0005 {
                let naturalMultiplier: CGFloat = SettingsStore.shared.trackpadNaturalScroll ? -1.0 : 1.0
                let sensitivity: CGFloat = CGFloat(SettingsStore.shared.scrollSensitivity) * 1400.0
                let deltaX = deltaFractionX * naturalMultiplier * sensitivity
                
                applyInteractiveDelta(deltaX, maxOffset: maxOffset, timestamp: timestamp)
            }
        }
        lastTouchCentroidX = avgX
        lastTouchCentroidY = avgY
    }
    
    private func handleMultitouchEnd(timestamp: Double) {
        if lastTouchCentroidX != nil {
            lastTouchCentroidX = nil
            lastTouchCentroidY = nil
            lastTouchCount = 0
            endInteractiveSwipe(maxOffset: maxOffset)
        }
    }
}
