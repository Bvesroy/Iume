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

/// Gesture ownership state to latch decisions once per gesture and prevent half-consumed events.
public enum GestureOwner: Sendable, Equatable {
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
    
    // MARK: - Single Motion Owner

    /// The one state machine that decides which code path may move the viewport this
    /// frame. Every public "is animating" flag below is derived from this value, so two
    /// paths can never drive the offset at once.
    private enum MotionPhase: Sendable {
        case idle
        case interactive   // 3/4-finger direct manipulation
        case tracking      // 2-finger / wheel input following `smoothTargetOffset`
        case decelerating  // inertial coast after the fingers lift
        case springing     // analytic spring toward `springState.target`
    }
    private var phase: MotionPhase = .idle

    /// Bounded temporal reservoir for two-finger direct-touch input.
    ///
    /// Deltas are accepted at event time: the authoritative target
    /// (`smoothTargetOffset`) advances immediately, so the raw input integral is
    /// never lost. The visible offset drains the reservoir on display ticks at the
    /// measured input rate, which redistributes bursty packet delivery without
    /// predicting ahead of input the user has actually produced.
    private struct DirectTouchResampler {
        /// Accepted input that has not reached the visible offset yet.
        var pending: CGFloat = 0
        /// Sum of realized input deltas for this gesture (the displacement record).
        var totalInput: CGFloat = 0
        /// Sum of steps written to the visible offset for this gesture.
        var totalApplied: CGFloat = 0

        var lastSampleTime: CFTimeInterval = 0
        var lastProcessedTick: CFTimeInterval = 0
        /// Time of the previous rate-window append. Measuring the actual interval
        /// keeps the drain rate correct when the display clock skips a tick on
        /// resume: the input from both frames is divided by both frames, not one.
        var lastWindowTime: CFTimeInterval = 0
        /// Trailing per-tick input sums and tick durations used by the rate window.
        var windowInputs: [CGFloat] = []
        var windowDts: [CGFloat] = []
        /// Display ticks since the last tick that carried input, and the observed
        /// spacing between them. The window spans one measured input interval.
        var ticksSinceNonzero: Int = 0
        var inputTickInterval: Int = 0
        var hasNonzeroTick = false
        var inputSinceLastTick: CGFloat = 0
        var samplesSinceLastTick: Int = 0
        var rate: CGFloat = 0
        var isActive = false

        mutating func begin(at time: CFTimeInterval) {
            self = DirectTouchResampler()
            isActive = true
            lastSampleTime = time
            lastWindowTime = time
        }

        mutating func accept(_ delta: CGFloat, timestamp: CFTimeInterval) {
            if delta.isFinite && delta != 0 {
                pending += delta
                totalInput += delta
                inputSinceLastTick += delta
                // Only real packets count toward the cold-start split; a zero-delta
                // phase marker must not halve a uniform first frame.
                samplesSinceLastTick += 1
            }
            // Timestamps only order samples and bound gaps; the drain rate is
            // derived from per-tick sums, so a clock-epoch mismatch cannot break it.
            lastSampleTime = max(timestamp, lastSampleTime)
        }

        mutating func reset() {
            self = DirectTouchResampler()
        }
    }

    private var directTouch = DirectTouchResampler()

    // Diagnostics for the standalone harness; not part of the public API.
    var directTouchPending: CGFloat { directTouch.pending }
    var directTouchTotalInput: CGFloat { directTouch.totalInput }
    var directTouchTotalApplied: CGFloat { directTouch.totalApplied }
    var directTouchRate: CGFloat { directTouch.rate }
    var isDirectTouchResampling: Bool { directTouch.isActive }

    /// Bounded prediction/teleport guard for one displayed frame. The reservoir can
    /// never move further than this even after a pathological event gap.
    private static let directTouchMaxStep: CGFloat = 160.0
    private static let directTouchResidualEpsilon: CGFloat = 0.01
    private static let directTouchEpochTimeout: CFTimeInterval = 0.12
    /// Bounded rate-window size in display ticks. The floor spreads an
    /// alternating 0 / burst pattern across frames at 60 Hz; the ceiling keeps
    /// the reservoir bounded when input is much slower than the display.
    private static let directTouchMinWindowTicks = 2
    private static let directTouchMaxWindowTicks = 8

    // Viewport & Physics State
    public private(set) var currentOffset: CGFloat = 0.0
    public private(set) var currentVelocity: CGFloat = 0.0
    /// The destination of the current direct-tracking gesture. During a spring this
    /// mirrors `springState.target`; it is never a second competing animation.
    public private(set) var smoothTargetOffset: CGFloat = 0.0
    public private(set) var settleVelocity: CGFloat = 0.0
    public var maxOffset: CGFloat = 0.0
    public var isLoopModeEnabled: Bool = false
    public var loopPeriod: CGFloat = 0.0

    public var springState: SpringState = SpringState()

    public var isSwipingInteractively: Bool { phase == .interactive }
    public var isSpringAnimating: Bool { phase == .springing }
    public var isMomentumCoasting: Bool { phase == .decelerating }
    public var isActivelyScrolling: Bool {
        switch phase {
        case .interactive, .tracking, .decelerating: return true
        case .idle, .springing: return false
        }
    }
    /// Source of the most recent `onScrollActivity` emission. Read synchronously by the
    /// callback's owner to decide whether the event was user-driven.
    public private(set) var lastActivitySource: ScrollActivitySource = .programmatic
    private var springSource: ScrollActivitySource = .programmatic

    public var isMoving: Bool {
        isActivelyScrolling || isSpringAnimating || !springState.isAtRest
            || abs(smoothTargetOffset - currentOffset) > 0.05
    }

    private var lastScrollTime: CFTimeInterval = 0
    private var lastInputTimestamp: CFTimeInterval = 0
    private var lastFrameTimestamp: CFTimeInterval = 0
    private var pendingDelta: CGFloat = 0.0
    private var pendingInteractiveDelta: CGFloat = 0.0
    private var lastPhase: Int64 = 0
    private var lastMomentumPhase: Int64 = 0
    /// The direct-touch reservoir retired after an input gap while the finger may
    /// still be down. A continuing phase-2 packet resumes the same physical
    /// gesture instead of starting a fresh epoch, which would reset the target and
    /// clamp a live rubber-band overscroll to the boundary in one frame.
    private var directTouchResumable = false
    private var hasPendingSettle: Bool = false
    /// Invalidates settle/watchdog timers belonging to a previous gesture.
    private var gestureGeneration: UInt64 = 0

    private var settleTimer: Timer?
    private var momentumWatchdogTimer: Timer?
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: DisplayLinkTarget?
    private var displayLinkScreenId: CGDirectDisplayID?
    private var fallbackTimer: Timer?

    public private(set) var gestureOwner: GestureOwner = .undecided
    private var lastScrollEventTime: CFTimeInterval = 0

    /// D06 experiment: hand a gesture that started horizontally back to the app once
    /// vertical intent dominates. Off by default for one release; opt in with
    /// `defaults write com.iume.Iume iume.diagonalHandback -bool YES`.
    /// Only future events can be handed back — events already consumed by the tap
    /// cannot be replayed into another application.
    public var diagonalHandbackEnabled: Bool =
        UserDefaults.standard.bool(forKey: "iume.diagonalHandback")
    private var stripVerticalIntentX: CGFloat = 0
    private var stripVerticalIntentY: CGFloat = 0
    private var stripVerticalIntentSamples = 0
    private var handedBackThisGesture = false
    
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    public private(set) var eventTapIsActive: Bool = false
    private var lastGestureTraceTime: CFTimeInterval = 0
    
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
    
    public func invalidate() {
        displayLink?.invalidate()
        fallbackTimer?.invalidate()
        settleTimer?.invalidate()
        momentumWatchdogTimer?.invalidate()
        stopMultitouchMonitoring()
    }
    
    // MARK: - Display Link Setup & Pacing (80-120Hz ProMotion)

    private func setupDisplayLink() {
        guard displayLink == nil else { return }
        guard let screen = NSScreen.main else { return }
        installDisplayLink(on: screen, running: false)
    }

    /// Move the display link to a new screen. Called when the active display changes
    /// or the display arrangement changes; without this the link stays attached to a
    /// panel that may no longer exist and animation pacing silently degrades.
    public func attachDisplayLink(to screen: NSScreen, force: Bool = false) {
        let screenId = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        if !force, let screenId = screenId, screenId == displayLinkScreenId, displayLink != nil {
            return
        }
        let wasRunning = displayLink.map { !$0.isPaused } ?? false
        installDisplayLink(on: screen, running: wasRunning)
    }

    private func installDisplayLink(on screen: NSScreen, running: Bool) {
        displayLink?.invalidate()
        displayLinkScreenId = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let target = DisplayLinkTarget(self)
        self.displayLinkTarget = target
        let link = screen.displayLink(target: target, selector: #selector(DisplayLinkTarget.onTick(_:)))
        if #available(macOS 14.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        }
        link.add(to: .main, forMode: .common)
        link.isPaused = !running
        self.displayLink = link
        if running {
            // A new panel starts a new timestamp epoch. Do not carry the old one.
            lastFrameTimestamp = CACurrentMediaTime()
            fallbackTimer?.invalidate()
            fallbackTimer = nil
        }
    }

    private func resumeDisplayLink() {
        lastInputTimestamp = CACurrentMediaTime()
        if let link = displayLink {
            if link.isPaused {
                // Use real elapsed time on the first tick after a start rather than
                // a synthetic one-frame step.
                lastFrameTimestamp = CACurrentMediaTime()
                link.isPaused = false
            }
        } else if NSScreen.main != nil {
            setupDisplayLink()
            lastFrameTimestamp = CACurrentMediaTime()
            displayLink?.isPaused = false
        } else {
            // Headless / test fallback timer (120Hz)
            if fallbackTimer == nil {
                lastFrameTimestamp = CACurrentMediaTime()
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

    /// Suspends all motion work. Used when Accessibility permission is revoked, the
    /// display disconnects, or the app is going away.
    public func suspend() {
        cancelAnimation()
        pauseDisplayLink()
    }

    // MARK: - Hardware VSYNC Tick

    /// Convert the display timestamp into a clamped elapsed time.
    ///
    /// The first tick after a start has no previous sample; one nominal 120 Hz frame
    /// is the least surprising estimate. Every later tick uses the real elapsed time.
    /// A gap beyond `maxStallDelta` means the process was suspended, the display
    /// disconnected, or the debugger stopped us: that frame is skipped entirely
    /// rather than integrated with a 33 ms step, which at high velocity would still
    /// read as a teleport. The next normal tick resumes from the same position.
    private func frameDelta(_ now: CFTimeInterval) -> CGFloat {
        guard now.isFinite else { return 0 }
        let previous = lastFrameTimestamp
        if previous <= 0 {
            lastFrameTimestamp = now
            return 1.0 / 120.0
        }
        lastFrameTimestamp = now
        let raw = CGFloat(now - previous)
        guard raw.isFinite, raw > 0 else { return 0 }
        if raw > 0.1 { return 0 }
        return min(raw, SpringState.maxFrameDelta)
    }

    public func displayLinkFired(timestamp: CFTimeInterval? = nil) {
        let now = timestamp ?? CACurrentMediaTime()
        guard now.isFinite else { return }
        let dt = frameDelta(now)
        // Seam detection needs the position before this frame touched it, since a lap
        // can complete inside any one of the motion branches below.
        let offsetAtFrameStart = currentOffset

        switch phase {
        case .interactive:
            _ = stepInteractive(now: now, dt: dt, from: offsetAtFrameStart)
        case .tracking:
            _ = stepTracking(now: now, dt: dt, from: offsetAtFrameStart)
        case .decelerating:
            _ = stepDeceleration(dt: dt, from: offsetAtFrameStart)
        case .springing:
            _ = stepSpring(dt: dt, from: offsetAtFrameStart)
        case .idle:
            break
        }

        // A lift, a wheel-idle timer, or the end of a momentum stream asks for a
        // settle. It is applied here, once, after this frame's motion has been
        // committed, and never while a spring already owns the offset.
        if hasPendingSettle && phase != .springing {
            let settings = SettingsStore.shared
            if (!settings.snapToColumn || settings.freeformScroll) && abs(smoothTargetOffset - currentOffset) > 0.2 {
                // Let the remaining glide finish before settling.
            } else {
                hasPendingSettle = false
                settle()
                return
            }
        }

        if phase == .idle {
            maybePauseDisplayLinkIfIdle(now: now)
        }
    }

    private func maybePauseDisplayLinkIfIdle(now: CFTimeInterval) {
        guard !hasPendingSettle else { return }
        guard springState.isAtRest, abs(smoothTargetOffset - currentOffset) <= 0.05 else { return }
        // A short tail avoids downclock/restart churn when the user taps the trackpad
        // twice in quick succession, but the link never stays alive indefinitely.
        guard now - lastInputTimestamp > 0.5 else { return }
        normalizeLoopOffsetAtRest()
        pauseDisplayLink()
    }

    // MARK: - Frame Steps (exactly one phase runs)

    private func stepInteractive(now: CFTimeInterval, dt: CGFloat, from frameStart: CGFloat) -> Bool {
        var didWork = false

        if abs(pendingInteractiveDelta) > 0.0001 {
            let elapsed = max(0.004, CGFloat(now - lastInputTimestamp))
            lastInputTimestamp = now
            didWork = applyInteractiveDeltaToOffset(pendingInteractiveDelta, elapsed: elapsed) || didWork
            pendingInteractiveDelta = 0.0
            if didWork {
                publish(offset: currentOffset, velocity: currentVelocity, source: .user, interactive: true, seamFrom: frameStart)
            }
        }

        if now - lastInputTimestamp > 0.11 {
            endInteractiveSwipe(maxOffset: maxOffset)
        }
        return didWork
    }

    /// Applies one already-timestamped direct delta. Returns true when the offset moved.
    @discardableResult
    private func applyInteractiveDeltaToOffset(_ deltaX: CGFloat, elapsed: CGFloat) -> Bool {
        guard deltaX.isFinite, deltaX != 0 else { return false }
        let base = springState.position
        var nextOffset = base + deltaX
        if !isLoopModeEnabled {
            let rubberLimit: CGFloat = 180.0
            if nextOffset < 0 {
                let overshoot = -nextOffset
                let resistance = max(0.12, 1.0 - (overshoot / rubberLimit))
                nextOffset = base + (deltaX * resistance)
            } else if nextOffset > maxOffset {
                let overshoot = nextOffset - maxOffset
                let resistance = max(0.12, 1.0 - (overshoot / rubberLimit))
                nextOffset = base + (deltaX * resistance)
            }
        }
        guard nextOffset.isFinite else { return false }
        let stepDuration = min(max(elapsed, 0.004), 0.1)
        let instantVelocity = (nextOffset - base) / stepDuration
        springState.velocity = (0.65 * springState.velocity) + (0.35 * instantVelocity)
        springState.position = nextOffset
        springState.target = nextOffset
        currentOffset = nextOffset
        currentVelocity = springState.velocity
        smoothTargetOffset = nextOffset
        return true
    }

    /// Consume one display tick from the direct-touch reservoir.
    ///
    /// The drain rate is a two-tick, time-weighted mean of accepted input. That is
    /// exactly the gesture mean for an alternating `0 / burst` packet pattern at any
    /// refresh cadence, so the reservoir cancels the burst instead of merely
    /// low-passing it. It never consumes more than has been received, so uniform
    /// input is delivered 1:1 and reversals land on the next frame.
    private func stepDirectTouch(now: CFTimeInterval, dt: CGFloat, frameStart: CGFloat) -> Bool {
        guard now.isFinite, dt > 0 else { return false }

        // Lost the lift event (or the system paused mid-gesture). Land on the exact
        // input integral once, then retire; a continuing phase-2 packet starts a
        // fresh epoch. This mirrors the existing 0.12 s direct-touch window.
        if now - directTouch.lastSampleTime > Self.directTouchEpochTimeout {
            let seamStart = currentOffset
            _ = flushDirectTouch(publish: true, frameStart: seamStart)
            directTouch.reset()
            if phase == .tracking {
                phase = .idle
                directTouchResumable = true
            }
            // The pause ends any flick: velocity measured before it must not decide
            // the coast when the finger eventually lifts. It also lets `isMoving`
            // become false so the display link can pause.
            currentVelocity = 0
            settleVelocity = 0
            springState.velocity = 0
            springState.position = currentOffset
            springState.target = currentOffset
            resumeDisplayLink()
            return true
        }

        // Rate is the mean input over a trailing window sized to the observed input
        // cadence. For regularly-paced packets the window contains exactly one
        // packet interval, so the drain rate equals the true input rate and the
        // reservoir cancels the burst instead of low-passing it. The window has a
        // two-tick floor (spreads a burst at 60 Hz display cadence) and an
        // eight-tick ceiling (bounds buffering when input is slow).
        let thisTickInput = directTouch.inputSinceLastTick
        let windowDt: CGFloat
        if directTouch.lastWindowTime > 0, now > directTouch.lastWindowTime {
            // The resume after an idle pause skips one display tick by design. Use
            // the real elapsed window so the skipped frame's input is spread over
            // both frames instead of landing as a 1.5x catch-up step.
            windowDt = min(CGFloat(now - directTouch.lastWindowTime), 0.1)
        } else {
            windowDt = dt
        }
        directTouch.lastWindowTime = now
        directTouch.windowInputs.append(thisTickInput)
        directTouch.windowDts.append(windowDt)
        if directTouch.windowInputs.count > Self.directTouchMaxWindowTicks {
            let excess = directTouch.windowInputs.count - Self.directTouchMaxWindowTicks
            directTouch.windowInputs.removeFirst(excess)
            directTouch.windowDts.removeFirst(excess)
        }
        directTouch.ticksSinceNonzero += 1
        if thisTickInput != 0 {
            if directTouch.hasNonzeroTick {
                directTouch.inputTickInterval = max(
                    Self.directTouchMinWindowTicks,
                    min(Self.directTouchMaxWindowTicks, directTouch.ticksSinceNonzero)
                )
            }
            directTouch.hasNonzeroTick = true
            directTouch.ticksSinceNonzero = 0
        }
        let requestedTicks = directTouch.inputTickInterval > 0
            ? directTouch.inputTickInterval
            : Self.directTouchMinWindowTicks
        let windowTicks = min(requestedTicks, directTouch.windowInputs.count)
        var windowInput: CGFloat = 0
        var windowSeconds: CGFloat = 0
        for index in (directTouch.windowInputs.count - windowTicks)..<directTouch.windowInputs.count {
            windowInput += directTouch.windowInputs[index]
            windowSeconds += directTouch.windowDts[index]
        }
        let measuredRate = windowSeconds > 0 ? windowInput / windowSeconds : 0
        directTouch.rate = measuredRate.isFinite ? measuredRate : 0
        let samples = directTouch.samplesSinceLastTick
        directTouch.inputSinceLastTick = 0
        directTouch.samplesSinceLastTick = 0

        guard abs(directTouch.pending) > Self.directTouchResidualEpsilon else {
            // Keep sub-epsilon movement in the ledger instead of discarding it;
            // repeated tiny packets must still add up to their exact total.
            directTouch.lastProcessedTick = now
            return false
        }

        var magnitude = abs(directTouch.rate) * dt
        if directTouch.totalApplied == 0, samples > 0 {
            // Split a multi-packet first frame by its packet count (capped at two):
            // a single uniform packet stays 1:1, a two-packet burst is halved.
            magnitude = abs(directTouch.pending) / CGFloat(min(max(samples, 1), 2))
        }
        if directTouch.rate != 0,
           (directTouch.pending < 0) != (directTouch.rate < 0) {
            // The window still averages pre-reversal motion. Land the net pending
            // input now rather than draining it against a stale direction, so a
            // reversal is never smeared across the length of the window.
            magnitude = abs(directTouch.pending)
        }
        if !magnitude.isFinite || magnitude <= 0 {
            // No usable rate (all-zero samples or a clock anomaly): drain, bounded.
            magnitude = abs(directTouch.pending)
        }
        magnitude = min(magnitude, abs(directTouch.pending))
        magnitude = min(magnitude, Self.directTouchMaxStep)

        let step = directTouch.pending < 0 ? -magnitude : magnitude
        directTouch.pending -= step
        directTouch.totalApplied += step
        directTouch.lastProcessedTick = now

        currentOffset += step
        let instantVelocity = step / max(dt, 0.004)
        if currentVelocity == 0 || !currentVelocity.isFinite {
            currentVelocity = instantVelocity
        } else {
            currentVelocity = (currentVelocity * 0.65) + (instantVelocity * 0.35)
        }
        lastInputTimestamp = max(lastInputTimestamp, directTouch.lastSampleTime)
        springState.position = currentOffset
        springState.target = smoothTargetOffset
        springState.velocity = currentVelocity

        publish(
            offset: currentOffset,
            velocity: currentVelocity,
            source: .user,
            interactive: true,
            seamFrom: frameStart
        )
        return true
    }

    /// Apply all accepted direct-touch input that has not reached the visible offset.
    /// Called exactly once per completed gesture, before the coast/settle decision.
    @discardableResult
    private func flushDirectTouch(publish shouldPublish: Bool, frameStart: CGFloat?) -> Bool {
        guard directTouch.isActive else { return false }
        let residual = directTouch.pending.isFinite ? directTouch.pending : 0
        directTouch.pending = 0
        directTouch.totalApplied += residual
        directTouch.isActive = false
        directTouch.windowInputs.removeAll(keepingCapacity: false)
        directTouch.windowDts.removeAll(keepingCapacity: false)
        directTouch.ticksSinceNonzero = 0
        directTouch.inputTickInterval = 0
        directTouch.hasNonzeroTick = false
        directTouch.inputSinceLastTick = 0
        directTouch.samplesSinceLastTick = 0

        guard residual.isFinite, abs(residual) > 0.0001 else {
            smoothTargetOffset = currentOffset
            return false
        }
        // The target was already advanced at input time; only the visible offset lags.
        currentOffset += residual
        if !currentOffset.isFinite {
            currentOffset = smoothTargetOffset
        }
        smoothTargetOffset = currentOffset
        springState.position = currentOffset
        springState.target = currentOffset
        if shouldPublish {
            publish(
                offset: currentOffset,
                velocity: currentVelocity,
                source: .user,
                interactive: true,
                seamFrom: frameStart ?? currentOffset
            )
        }
        return true
    }

    // [LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:stepTracking]
    // Description: Real-time trackpad event tracking, 1:1 direct touch bypass, and continuous smoothness filter.
    private func stepTracking(now: CFTimeInterval, dt: CGFloat, from frameStart: CGFloat) -> Bool {
        if directTouch.isActive {
            return stepDirectTouch(now: now, dt: dt, frameStart: frameStart)
        }

        let offsetBefore = currentOffset
        let hadPendingDelta = abs(pendingDelta) > 0.001

        if hadPendingDelta {
            let effectiveDelta = pendingDelta
            pendingDelta = 0.0
            lastInputTimestamp = now
            let dtScroll: CGFloat = (lastScrollTime == 0)
                ? (1.0 / 120.0)
                : min(max(0.004, CGFloat(now - lastScrollTime)), 0.05)
            lastScrollTime = now

            let instVelocity = effectiveDelta / dtScroll
            if instVelocity.isFinite, currentVelocity.isFinite {
                currentVelocity = (currentVelocity == 0)
                    ? instVelocity
                    : (currentVelocity * 0.65 + instVelocity * 0.35)
            }

            advanceSmoothedTarget(by: effectiveDelta)
        }

        let isDirectTouch = (lastPhase == 1 || lastPhase == 2)
            && lastMomentumPhase == 0
            && (now - lastInputTimestamp) <= 0.12
        let isMacOSMomentum = (lastMomentumPhase == 1 || lastMomentumPhase == 2)
        let smoothness = SettingsStore.shared.scrollSmoothness
        let smoothEnabled = SettingsStore.shared.smoothScrollingEnabled

        if isDirectTouch || isMacOSMomentum || !smoothEnabled || smoothness <= 0.05 {
            // Direct 1:1 manipulation during physical touch or the native momentum
            // stream, or when smooth scrolling is disabled. Zero filter lag;
            // the input timestamp paces the motion.
            if currentOffset != smoothTargetOffset {
                currentOffset = smoothTargetOffset
            }
        } else {
            // Trackpad events arrive in irregular bursts (0, 1 or 2 per 120 Hz frame).
            // This filter turns the queued destination into continuous motion; the
            // time constant is the Smoothness control.
            let lambda = max(28.0, 35.0 + CGFloat(1.0 - smoothness) * 80.0)
            let factor = 1.0 - exp(-lambda * dt)
            let distance = smoothTargetOffset - currentOffset
            let step = distance * factor
            currentOffset += step
            let frameVelocity = step / max(0.001, dt)
            let alpha = min(0.85, max(0.40, 0.45 + CGFloat(smoothness) * 0.35))
            if dt > 0, frameVelocity.isFinite {
                currentVelocity = (currentVelocity == 0)
                    ? frameVelocity
                    : (currentVelocity * alpha + frameVelocity * (1.0 - alpha))
            }
            if abs(smoothTargetOffset - currentOffset) < 0.05 {
                currentOffset = smoothTargetOffset
            }
        }

        springState.position = currentOffset
        springState.target = smoothTargetOffset
        springState.velocity = currentVelocity

        let moved = abs(currentOffset - offsetBefore) > 0.0001
        guard hadPendingDelta || moved else { return false }
        publish(
            offset: currentOffset,
            velocity: currentVelocity,
            source: .user,
            interactive: true,
            seamFrom: frameStart
        )
        return true
    }
    // [END LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:stepTracking]

    /// Advance the smoothed destination with continuous rubber-banded resistance
    /// past the strip boundaries. Shared by live tracking and the lift path so the
    /// final queued event is not discarded when a coast takes over.
    private func advanceSmoothedTarget(by delta: CGFloat) {
        guard delta.isFinite, delta != 0 else { return }
        var nextTarget = smoothTargetOffset + delta
        if !isLoopModeEnabled {
            if SettingsStore.shared.freezeOnRelease {
                nextTarget = min(max(0, nextTarget), maxOffset)
            } else {
                let rubberLimit: CGFloat = 200.0
                if nextTarget < 0 {
                    let overshoot = -nextTarget
                    let resistance = max(0.10, 1.0 - (overshoot / rubberLimit))
                    nextTarget = smoothTargetOffset + (delta * resistance)
                } else if nextTarget > maxOffset {
                    let overshoot = nextTarget - maxOffset
                    let resistance = max(0.10, 1.0 - (overshoot / rubberLimit))
                    nextTarget = smoothTargetOffset + (delta * resistance)
                }
            }
        }
        if nextTarget.isFinite { smoothTargetOffset = nextTarget }
    }

    // [LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:stepDeceleration]
    // Description: Closed-form exponential and aerodynamic drag deceleration physics across the 4 kinetic profiles.
    private func stepDeceleration(dt: CGFloat, from frameStart: CGFloat) -> Bool {
        guard dt > 0 else { return false }
        let settings = SettingsStore.shared
        let rawFriction = CGFloat(settings.scrollDeceleration)
        let baseDecel = min(max(rawFriction, 0.85), 0.995)

        let displacement: CGFloat
        let decay: CGFloat

        switch settings.kineticScrollingProfile {
        case .natural:
            // Exact exponential decay: v(t) = v0 · k^t, x(t) = x0 + v0 · (k^t − 1) / ln k.
            // Integrating the closed form keeps a flick's distance frame-rate independent.
            let perSecond = pow(baseDecel, 60.0)
            decay = pow(perSecond, dt)
            let logDecay = log(perSecond)
            displacement = currentVelocity * (decay - 1.0) / logDecay
            currentVelocity *= decay

        case .viscous:
            // Aerodynamic fluid resistance: dv/dt = -(alpha * v + beta * v * |v|)
            // High speeds encounter quadratic drag for smooth arrest without harsh stops.
            let speed = abs(currentVelocity)
            let linearAlpha = (1.0 - baseDecel) * 60.0
            let quadBeta: CGFloat = 0.00040
            let totalDrag = linearAlpha + quadBeta * speed
            decay = max(0.0, 1.0 - totalDrag * dt)
            displacement = currentVelocity * dt * (1.0 + decay) * 0.5
            currentVelocity *= decay

        case .highInertia:
            // Low friction kinetic glide: extended momentum conservation for sweeping moves
            let effectiveDecel = min(0.996, baseDecel + 0.015)
            let perSecond = pow(effectiveDecel, 60.0)
            decay = pow(perSecond, dt)
            let logDecay = log(perSecond)
            displacement = currentVelocity * (decay - 1.0) / logDecay
            currentVelocity *= decay

        case .snappy:
            // Fast kinetic braking: slightly higher friction with linear arrest below 250 pt/s
            let effectiveDecel = max(0.85, baseDecel - 0.035)
            let perSecond = pow(effectiveDecel, 60.0)
            var snappyDecay = pow(perSecond, dt)
            if abs(currentVelocity) < 250.0 {
                snappyDecay *= max(0.2, 1.0 - 0.35 * (dt * 60.0))
            }
            decay = snappyDecay
            displacement = currentVelocity * dt
            currentVelocity *= decay
        }

        guard currentVelocity.isFinite else {
            cancelAnimation()
            return false
        }

        smoothTargetOffset += displacement
        currentOffset = smoothTargetOffset
        springState.position = currentOffset
        springState.target = currentOffset
        springState.velocity = currentVelocity
        publish(
            offset: currentOffset,
            velocity: currentVelocity,
            source: .momentum,
            interactive: true,
            seamFrom: frameStart
        )

        let stopThreshold: CGFloat
        switch settings.kineticScrollingProfile {
        case .highInertia: stopThreshold = 10.0
        case .snappy: stopThreshold = 35.0
        default: stopThreshold = 20.0
        }

        if !isLoopModeEnabled && (currentOffset < 0 || currentOffset > maxOffset) {
            currentVelocity *= pow(0.85, dt * 60.0)
            if abs(currentVelocity) < 35.0 {
                settle()
                return true
            }
        }

        if abs(currentVelocity) < stopThreshold {
            settle()
        }
        return true
    }
    // [END LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:stepDeceleration]

    private func stepSpring(dt: CGFloat, from frameStart: CGFloat) -> Bool {
        // A layout change can shrink the strip while a spring is in flight. Retarget
        // immediately instead of letting the spring finish outside the valid range.
        if !isLoopModeEnabled {
            let boundedTarget = min(max(0, springState.target), maxOffset)
            if boundedTarget != springState.target {
                springState.target = boundedTarget
                smoothTargetOffset = boundedTarget
            }
        }

        springState.step(dt: dt)
        var visible = springState.position
        if isLoopModeEnabled {
            if visible.isFinite {
                visible = loopWrappedOffset(visible)
            }
        } else {
            visible = min(max(0, visible), maxOffset)
        }
        guard visible.isFinite else {
            finishSpring()
            return false
        }
        currentOffset = visible
        currentVelocity = springState.velocity

        // User-aimed springs (flick settle, keyboard scroll) can finish a lap too.
        // Programmatic springs are layout syncs and stay silent.
        if springSource != .programmatic {
            notifyLoopSeamCrossing(from: frameStart, to: currentOffset)
        }
        publish(offset: currentOffset, velocity: currentVelocity, source: springSource, interactive: false, seamFrom: nil)

        if springState.isAtRest {
            finishSpring()
        }
        return true
    }

    private func finishSpring() {
        // Re-resolve the destination once at rest. A focus change or a window closing
        // between the last input and completion can shrink the strip underneath us.
        if let queried = onQueryMaxOffset?(), queried.isFinite {
            let newMax = max(0, queried)
            if abs(newMax - maxOffset) > 0.5 {
                maxOffset = newMax
                let bounded = isLoopModeEnabled
                    ? springState.target
                    : min(max(0, springState.target), newMax)
                if abs(bounded - springState.position) > 0.5 {
                    springState.target = bounded
                    smoothTargetOffset = bounded
                    return
                }
            }
        }

        currentOffset = isLoopModeEnabled
            ? loopWrappedOffset(springState.target)
            : min(max(0, springState.target), maxOffset)
        springState.position = currentOffset
        springState.target = currentOffset
        springState.velocity = 0
        currentVelocity = 0
        smoothTargetOffset = currentOffset
        phase = .idle
        normalizeLoopOffsetAtRest(notify: false)
        publish(offset: currentOffset, velocity: 0, source: springSource, interactive: false, seamFrom: nil)
        onAnimationCompleted?()
    }

    /// Single publishing point for every motion branch.
    private func publish(
        offset: CGFloat,
        velocity: CGFloat,
        source: ScrollActivitySource,
        interactive: Bool,
        seamFrom: CGFloat?
    ) {
        guard offset.isFinite, velocity.isFinite else { return }
        if let seamFrom = seamFrom {
            notifyLoopSeamCrossing(from: seamFrom, to: offset)
        }
        onViewportOffsetChanged?(offset)
        onFrameStep?(offset, interactive)
        emitScrollActivity(offset: offset, maxOffset: maxOffset, velocity: velocity, source: source)
        traceGesture(
            "publish offset=\(offset) velocity=\(velocity) source=\(source) interactive=\(interactive) "
            + "motion=\(String(describing: phase))"
        )
    }

    private func traceGesture(_ message: String, force: Bool = false) {
        let enabled = UserDefaults.standard.bool(forKey: "iume.gestureDiagnostics")
        guard enabled || force else { return }
        let now = CACurrentMediaTime()
        guard force || now - lastGestureTraceTime >= 0.10 else { return }
        lastGestureTraceTime = now
        print("[Iume][GestureTrace] \(message)")
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
        let boundedMax = maxOffset.isFinite ? max(0, maxOffset) : 0
        self.maxOffset = boundedMax
        let resolved: CGFloat
        if isLoopModeEnabled {
            resolved = loopWrappedOffset(offset)
        } else if offset.isFinite {
            resolved = min(max(0, offset), boundedMax)
        } else {
            resolved = 0
        }
        currentOffset = resolved
        smoothTargetOffset = resolved
        currentVelocity = 0.0
        springState.position = resolved
        springState.target = resolved
        springState.velocity = 0.0
        phase = .idle
        publish(offset: resolved, velocity: 0, source: .programmatic, interactive: false, seamFrom: nil)
    }

    // MARK: - Animated Scroll (Analytic Spring Solver)

    /// Retarget the spring to `target`.
    ///
    /// If a spring is already in flight, its position and velocity are carried over:
    /// only the destination changes. That is what makes repeated keyboard presses bend
    /// the existing trajectory instead of restarting from a standstill.
    public func scrollTo(
        target: CGFloat,
        maxOffset: CGFloat,
        duration: Double = 0.18,
        initialVelocity: CGFloat = 0.0,
        source: ScrollActivitySource = .programmatic
    ) {
        springSource = source
        let boundedMax = maxOffset.isFinite ? max(0, maxOffset) : 0
        self.maxOffset = boundedMax
        // An idle call is a safe place to fold the current position into one cycle.
        if isPositionAtRest {
            normalizeLoopOffsetAtRest(notify: false)
        }

        let resolvedTarget: CGFloat
        if isLoopModeEnabled {
            resolvedTarget = target.isFinite ? loopTarget(near: currentOffset, target: target) : currentOffset
        } else if target.isFinite {
            resolvedTarget = min(max(0, target), boundedMax)
        } else {
            resolvedTarget = currentOffset
        }

        // Capture momentum before cancelling the owning phase.
        let carryVelocity: CGFloat
        if initialVelocity.isFinite && initialVelocity != 0 {
            carryVelocity = initialVelocity
        } else if settleVelocity.isFinite && settleVelocity != 0 {
            carryVelocity = settleVelocity
        } else if phase == .springing {
            carryVelocity = springState.velocity
        } else if phase == .tracking || phase == .decelerating || phase == .interactive {
            carryVelocity = currentVelocity
        } else {
            carryVelocity = 0
        }
        settleVelocity = 0.0

        guard abs(currentOffset - resolvedTarget) > 0.5 else {
            cancelAnimation()
            currentOffset = resolvedTarget
            smoothTargetOffset = resolvedTarget
            currentVelocity = 0.0
            pendingDelta = 0.0
            pendingInteractiveDelta = 0.0
            springState.position = resolvedTarget
            springState.target = resolvedTarget
            springState.velocity = 0
            phase = .idle
            publish(offset: resolvedTarget, velocity: 0, source: source, interactive: false, seamFrom: nil)
            onAnimationCompleted?()
            return
        }

        cancelAnimation()
        // A programmatic destination takes ownership of the offset; queued gesture
        // deltas must not fight the spring on the next frame.
        pendingDelta = 0.0
        pendingInteractiveDelta = 0.0

        let smoothness = SettingsStore.shared.scrollSmoothness
        springState.position = currentOffset
        springState.target = resolvedTarget
        springState.velocity = carryVelocity.isFinite ? carryVelocity : 0
        let baseResponse = duration > 0 ? CGFloat(duration) : 0.18
        springState.response = max(0.08, baseResponse * (0.70 + CGFloat(smoothness) * 0.40))
        springState.dampingRatio = max(0.88, 0.98 - CGFloat(smoothness) * 0.10)
        smoothTargetOffset = resolvedTarget
        currentVelocity = springState.velocity
        phase = .springing

        // Emit synchronously so callers get an immediate acknowledgement that the
        // animation started. The first real displacement happens on the next VSYNC,
        // measured against the actual frame clock; we never inject a fake frame step.
        publish(offset: currentOffset, velocity: currentVelocity, source: source, interactive: false, seamFrom: nil)
        resumeDisplayLink()
    }

    public func animateToOffset(_ targetOffset: CGFloat) {
        scrollTo(target: targetOffset, maxOffset: maxOffset)
    }

    // MARK: - Incremental Scroll (Discrete / Shortcut Step)

    public func scrollBy(deltaX: CGFloat, maxOffset: CGFloat) {
        cancelAnimation()
        self.maxOffset = maxOffset.isFinite ? max(0, maxOffset) : 0
        guard deltaX.isFinite else { return }
        let proposedOffset = currentOffset + deltaX
        let newOffset: CGFloat
        if isLoopModeEnabled {
            newOffset = loopWrappedOffset(proposedOffset)
        } else {
            newOffset = min(max(0, proposedOffset), self.maxOffset)
        }
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
        phase = .idle
        publish(offset: currentOffset, velocity: 0, source: .user, interactive: false, seamFrom: nil)
    }

    /// Stop every motion path and park the physics at the visible offset.
    public func cancelAnimation() {
        settleTimer?.invalidate()
        settleTimer = nil
        momentumWatchdogTimer?.invalidate()
        momentumWatchdogTimer = nil
        hasPendingSettle = false
        lastScrollTime = 0
        // A cancelled gesture's unrendered input is discarded, never flushed into
        // whatever motion takes ownership next.
        directTouch.reset()
        directTouchResumable = false
        pendingDelta = 0.0
        pendingInteractiveDelta = 0.0
        currentVelocity = 0.0
        // Invalidate every callback scheduled by the cancelled motion. A Timer that
        // already fired can have a Task waiting on the main actor; without this bump
        // that Task would still pass the generation guard and settle the new state.
        gestureGeneration &+= 1
        resetDiagonalIntent()
        // A geometry shrink can leave the parked offset outside the valid range;
        // cancelling must not strand the strip there (D01).
        clampRestingOffsetIfNeeded()
        smoothTargetOffset = currentOffset
        settleVelocity = 0.0
        springState.position = currentOffset
        springState.target = currentOffset
        springState.velocity = 0.0
        phase = .idle
    }

    /// The offset this controller is allowed to rest at for the current geometry.
    private func boundedRestingOffset(_ offset: CGFloat) -> CGFloat {
        guard offset.isFinite else { return 0 }
        if isLoopModeEnabled {
            return loopWrappedOffset(offset)
        }
        let limit = maxOffset.isFinite ? max(0, maxOffset) : 0
        return min(max(0, offset), limit)
    }

    /// Re-home an out-of-range resting offset after a geometry change or settle.
    /// An in-range offset is untouched, so normal releases keep their exact feel.
    /// Returns true when a correction was applied.
    @discardableResult
    private func clampRestingOffsetIfNeeded() -> Bool {
        let bounded = boundedRestingOffset(currentOffset)
        guard abs(bounded - currentOffset) > 0.0001 else { return false }
        currentOffset = bounded
        smoothTargetOffset = bounded
        springState.position = bounded
        springState.target = bounded
        springState.velocity = 0
        currentVelocity = 0
        settleVelocity = 0
        publish(offset: currentOffset, velocity: 0, source: .programmatic, interactive: false, seamFrom: nil)
        return true
    }

    /// Terminates a lift whose settle callbacks did not take ownership. Without
    /// this, a nil or no-op callback leaves the spring velocity that `isMoving`
    /// reads, so the display link can never pause (D02).
    private func finishUnclaimedSettle() {
        guard phase == .idle else { return }
        smoothTargetOffset = currentOffset
        springState.position = currentOffset
        springState.target = currentOffset
        springState.velocity = 0
        currentVelocity = 0
        settleVelocity = 0
    }

    public func freezeAtCurrentOffset() {
        cancelAnimation()
        currentVelocity = 0.0
        pendingDelta = 0.0
        pendingInteractiveDelta = 0.0
        phase = .idle
    }

    // MARK: - Interactive Direct Manipulation (3/4 Finger Swipes)

    public func applyInteractiveDelta(_ deltaX: CGFloat, maxOffset: CGFloat, timestamp: CFTimeInterval) {
        guard deltaX.isFinite else { return }
        if phase != .interactive {
            cancelAnimation()
        }
        lastInputTimestamp = timestamp.isFinite ? timestamp : CACurrentMediaTime()
        self.maxOffset = maxOffset.isFinite ? max(0, maxOffset) : 0
        if !pendingInteractiveDelta.isFinite || !deltaX.isFinite {
            pendingInteractiveDelta = 0
        } else {
            pendingInteractiveDelta += deltaX
        }
        phase = .interactive
        resumeDisplayLink()
    }

    public func endInteractiveSwipe(maxOffset: CGFloat) {
        guard phase == .interactive else { return }
        self.maxOffset = maxOffset.isFinite ? max(0, maxOffset) : 0

        // Flush the last contact sample before interpreting the lift. Discarding it
        // makes the strip stop short by up to one event's distance.
        let now = CACurrentMediaTime()
        let seamStart = currentOffset
        let elapsed = max(0.004, CGFloat(now - lastInputTimestamp))
        if abs(pendingInteractiveDelta) > 0.0001 {
            if applyInteractiveDeltaToOffset(pendingInteractiveDelta, elapsed: elapsed) {
                publish(offset: currentOffset, velocity: currentVelocity, source: .user, interactive: true, seamFrom: seamStart)
            }
            pendingInteractiveDelta = 0.0
        }

        phase = .idle
        if SettingsStore.shared.freezeOnRelease {
            freezeAtCurrentOffset()
            // A freeze release is still a settle: never park outside the range
            // that the current layout allows (D01).
            clampRestingOffsetIfNeeded()
            onSwipeSettled?(currentOffset)
            onSettleRequested?(currentOffset)
            return
        }
        // The finger has lifted: the strip is stationary, so fold the unbounded
        // gesture offset into one cycle before projecting momentum and snapping.
        // The spring velocity is left untouched so the projection is unchanged.
        normalizeLoopOffsetAtRest()
        let projected: CGFloat
        if isLoopModeEnabled {
            projected = springState.position + (springState.velocity * 0.18)
        } else {
            projected = min(max(0, springState.position + (springState.velocity * 0.18)), self.maxOffset)
        }
        // Preserve the lift velocity for the snap spring. Without this the settle
        // begins from rest, so a fast flick visibly pauses before accelerating.
        settleVelocity = springState.velocity.isFinite ? springState.velocity : 0
        smoothTargetOffset = currentOffset
        onSwipeSettled?(projected)
        onSettleRequested?(projected)
        finishUnclaimedSettle()
    }

    // MARK: - Continuous 2-Finger Trackpad Gesture Queueing (High-Speed & Non-Blocking)

    public func enqueueScroll(
        dx: CGFloat,
        dy: CGFloat,
        phase: Int64,
        momentumPhase: Int64,
        flags: CGEventFlags,
        timestamp: CFTimeInterval? = nil
    ) {
        guard dx.isFinite, dy.isFinite else { return }
        let settings = SettingsStore.shared
        let naturalMultiplier: CGFloat = settings.trackpadNaturalScroll ? -1.0 : 1.0
        let sensitivity = CGFloat(settings.scrollSensitivity)
        let previousPhase = lastPhase

        let hasModifier = flags.contains(.maskAlternate) || flags.contains(.maskControl)
        let primaryDelta: CGFloat
        if abs(dx) >= abs(dy) {
            primaryDelta = dx
        } else if hasModifier || settings.scrollTriggerMode != .seamlessHorizontal {
            primaryDelta = dy
        } else {
            primaryDelta = dx
        }
        let rawDelta = primaryDelta * naturalMultiplier * sensitivity
        let effectiveDelta = rawDelta.isFinite ? rawDelta : 0
        let timestampText = timestamp.map { String($0) } ?? "nil"

        traceGesture(
            "enqueue dx=\(dx) dy=\(dy) phase=\(phase) momentum=\(momentumPhase) "
            + "effective=\(effectiveDelta) timestamp=\(timestampText) "
            + "owner=\(gestureOwner) motion=\(String(describing: self.phase))"
        )

        // The event's own timestamp is the authoritative sample time. If the tap did
        // not provide one, stay on the display clock rather than mixing epochs: a
        // synthetic harness clock must order samples the same way a live one does.
        let sampleTime: CFTimeInterval
        if let timestamp = timestamp, timestamp.isFinite, timestamp > 0 {
            sampleTime = timestamp
        } else {
            sampleTime = max(CACurrentMediaTime(), lastFrameTimestamp)
        }

        lastPhase = phase
        lastMomentumPhase = momentumPhase

        // A repeated lift is the same physical event, not a new gesture. Ignoring it
        // keeps an already-running coast alive; taking the lift path again would
        // cancel that coast and restart the tracking epoch.
        if phase == 4, momentumPhase == 0, previousPhase == 4, effectiveDelta == 0 {
            return
        }
        // A stray lift when no touch epoch is active must not steal ownership from
        // an idle strip or a programmatic spring. macOS can deliver a trailing
        // phase-4 event after a keyboard retarget or an interrupted gesture;
        // beginning tracking for it would cancel the spring or leave `isMoving`
        // true with no input.
        if phase == 4, momentumPhase == 0, effectiveDelta == 0,
           self.phase == .idle || self.phase == .springing,
           !directTouch.isActive {
            return
        }

        // A momentum stream cannot inherit unrendered direct-touch input: the
        // physical gesture is over, so land it before the coast takes ownership.
        if (momentumPhase == 1 || momentumPhase == 2) && directTouch.isActive {
            let seamStart = currentOffset
            flushDirectTouch(publish: true, frameStart: seamStart)
            directTouch.reset()
            directTouchResumable = false
        }

        // Handle freezeOnRelease or disabled momentum / inertia
        if momentumPhase != 0 {
            if settings.freezeOnRelease || !settings.momentumScrolling || !settings.inertialScrolling {
                if momentumPhase == 4 {
                    requestSettle()
                }
                return
            }
        }

        if settings.freezeOnRelease && (phase == 4 || phase == 8) {
            directTouchResumable = false
            if phase == 4, momentumPhase == 0 {
                // Freeze means "land on the input integral": include the lift sample
                // instead of dropping the last few points of the gesture.
                if self.phase != .tracking { beginTracking(resetTarget: true) }
                if !directTouch.isActive { directTouch.begin(at: sampleTime) }
                let realized = advanceDirectTouchTarget(by: effectiveDelta)
                directTouch.accept(realized, timestamp: sampleTime)
                lastInputTimestamp = max(lastInputTimestamp, sampleTime)
                let seamStart = currentOffset
                flushDirectTouch(publish: true, frameStart: seamStart)
            } else {
                directTouch.reset()
            }
            freezeAtCurrentOffset()
            if momentumPhase == 4 {
                requestSettle()
            } else {
                scheduleFreezeWatchdog(generation: gestureGeneration, delay: 0.12)
            }
            return
        }

        if phase == 1 {
            // A new physical gesture always starts a fresh tracking epoch.
            directTouchResumable = false
            gestureGeneration &+= 1
            beginTracking(resetTarget: true)
            currentVelocity = 0.0
            queryMaxOffset()
            // Begin the ledger only after the target reset, so an interrupted
            // gesture's residual can never be counted into the new one.
            directTouch.begin(at: sampleTime)
            let realized = advanceDirectTouchTarget(by: effectiveDelta)
            directTouch.accept(realized, timestamp: sampleTime)
            lastInputTimestamp = max(lastInputTimestamp, sampleTime)
        } else if phase == 2 && momentumPhase == 0 {
            if self.phase != .tracking {
                if directTouchResumable {
                    resumeDirectTouchAfterGap()
                } else {
                    beginTracking(resetTarget: true)
                }
            }
            directTouchResumable = false
            // Already tracking: keep `smoothTargetOffset`. Resetting it on every
            // event would throw away motion that has not been rendered yet.
            if !directTouch.isActive {
                directTouch.begin(at: sampleTime)
            }
            let realized = advanceDirectTouchTarget(by: effectiveDelta)
            directTouch.accept(realized, timestamp: sampleTime)
            lastInputTimestamp = max(lastInputTimestamp, sampleTime)
        } else if phase == 4 && momentumPhase == 0 {
            // A lift can arrive without a preceding phase 1/2 (very short tap);
            // start from the current offset so its delta is not lost.
            if self.phase != .tracking {
                if directTouchResumable {
                    resumeDirectTouchAfterGap()
                } else {
                    beginTracking(resetTarget: true)
                }
            }
            directTouchResumable = false
            if !directTouch.isActive {
                directTouch.begin(at: sampleTime)
            }
            let realized = advanceDirectTouchTarget(by: effectiveDelta)
            directTouch.accept(realized, timestamp: sampleTime)
            lastInputTimestamp = max(lastInputTimestamp, sampleTime)
        } else if momentumPhase == 1 || momentumPhase == 2 {
            directTouchResumable = false
            if self.phase != .tracking {
                beginTracking(resetTarget: true)
            }
            pendingDelta += effectiveDelta
            lastInputTimestamp = max(lastInputTimestamp, sampleTime)
        } else if phase == 0 && momentumPhase == 0 {
            directTouchResumable = false
            // A wheel event takes the offset away from an in-progress touch. Land
            // accepted touch input first; queuing the wheel behind an active
            // reservoir would make it jump in one frame at the eventual lift.
            if directTouch.isActive {
                let seamStart = currentOffset
                flushDirectTouch(publish: true, frameStart: seamStart)
                directTouch.reset()
            }
            queryMaxOffset()
            // A discrete wheel event owns the gesture immediately, whichever motion
            // path was running. Without this the delta would be queued forever
            // because only `.tracking` consumes `pendingDelta`.
            if self.phase != .tracking {
                beginTracking(resetTarget: true)
                // A wheel is a fresh gesture, not a continuation of a flick. Carrying
                // the coast/spring velocity would bias the next snap projection.
                currentVelocity = 0.0
            }
            pendingDelta += effectiveDelta
            lastInputTimestamp = max(lastInputTimestamp, sampleTime)
        } else if phase == 8 {
            // Cancelled: stop every motion path and discard this gesture's
            // unrendered input. It must never be flushed into the next gesture.
            directTouchResumable = false
            cancelAnimation()
        } else {
            directTouchResumable = false
            if directTouch.isActive {
                let seamStart = currentOffset
                flushDirectTouch(publish: true, frameStart: seamStart)
                directTouch.reset()
            }
            pendingDelta += effectiveDelta
            lastInputTimestamp = max(lastInputTimestamp, sampleTime)
        }

        resumeDisplayLink()

        // [LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:onScrollPhysicalLift]
        // Description: Trackpad lift phase 4 handling, momentum velocity multiplication, and inertia dispatch.
        // 1. Physical finger lift (phase 4 = Ended)
        if phase == 4 && momentumPhase == 0 {
            // Land the final contact sample before velocity decides the coast. The
            // flush does not alter currentVelocity, so the projection is unchanged.
            let seamStart = currentOffset
            flushDirectTouch(publish: true, frameStart: seamStart)
            
            let allowInertia = settings.inertialScrolling && settings.momentumScrolling && !settings.freezeOnRelease
            if allowInertia && abs(currentVelocity) > 25 {
                let multiplier = CGFloat(max(0.2, min(3.0, settings.momentumMultiplier)))
                currentVelocity *= multiplier
                beginDeceleration()
            } else if allowInertia {
                // Adaptive grace period (90ms) for macOS trackpad momentum stream
                // to kick in before settling.
                scheduleMomentumGrace(generation: gestureGeneration, delay: 0.090)
            } else {
                requestSettle()
            }
            return
        }
        // [END LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:onScrollPhysicalLift]

        if phase == 8 {
            // Cancelled
            requestSettle()
            return
        }

        if momentumPhase == 4 {
            // macOS momentum ended
            requestSettle()
        }

        // 2. Discrete mouse wheel debounce
        if phase == 0 && momentumPhase == 0 {
            let smoothness = SettingsStore.shared.scrollSmoothness
            scheduleWheelSettle(generation: gestureGeneration, delay: 0.10 + (smoothness * 0.08))
        }
    }

    /// Advance the authoritative target at input time and report the realized delta.
    /// Boundary resistance can make the realized value smaller than the request; the
    /// reservoir records only what the strip actually earned.
    @discardableResult
    private func advanceDirectTouchTarget(by delta: CGFloat) -> CGFloat {
        guard delta.isFinite, delta != 0 else { return 0 }
        let before = smoothTargetOffset
        advanceSmoothedTarget(by: delta)
        let realized = smoothTargetOffset - before
        return realized.isFinite ? realized : 0
    }

    /// Resume the same physical touch after an input-gap epoch timeout. The target
    /// and offset were already reconciled by the flush, so this must not reset the
    /// target or clamp a rubber-band overscroll the way `beginTracking` does.
    private func resumeDirectTouchAfterGap() {
        directTouchResumable = false
        phase = .tracking
        lastScrollTime = 0
        springState.position = currentOffset
        springState.target = smoothTargetOffset
        springState.velocity = currentVelocity
    }

    private func beginTracking(resetTarget: Bool) {
        if phase != .tracking {
            cancelAnimation()
            phase = .tracking
        }
        if resetTarget {
            smoothTargetOffset = currentOffset
        }
        lastScrollTime = 0
        springState.position = currentOffset
        springState.target = smoothTargetOffset
        springState.velocity = currentVelocity
    }

    private func beginDeceleration() {
        // Any accepted direct-touch input that has not reached the screen lands
        // before the coast owns the offset. This is normally a no-op because the
        // lift path flushes first; it guards a lost/duplicated lift event.
        if directTouch.isActive {
            let seamStart = currentOffset
            flushDirectTouch(publish: true, frameStart: seamStart)
            directTouch.reset()
        }
        // Apply input that arrived with the lift event before the coast owns the
        // offset. Otherwise the last gesture sample is silently discarded and the
        // strip stops short by up to one event's distance.
        if abs(pendingDelta) > 0.001 {
            let delta = pendingDelta
            pendingDelta = 0.0
            advanceSmoothedTarget(by: delta)
            currentOffset = smoothTargetOffset
        }
        // Start the coast from what is actually on screen. Carrying a trailing
        // smoothness distance into the coast is what produced a small jump on lift.
        smoothTargetOffset = currentOffset
        springState.position = currentOffset
        springState.target = currentOffset
        springState.velocity = currentVelocity
        phase = .decelerating
        settleTimer?.invalidate()
        settleTimer = nil
        momentumWatchdogTimer?.invalidate()
        momentumWatchdogTimer = nil
        resumeDisplayLink()
    }

    private func queryMaxOffset() {
        if let queried = onQueryMaxOffset?(), queried.isFinite {
            maxOffset = max(0, queried)
        }
    }

    private func requestSettle() {
        hasPendingSettle = true
        resumeDisplayLink()
    }

    private func scheduleWheelSettle(generation: UInt64, delay: TimeInterval) {
        settleTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWheelSettleTimer(generation: generation)
            }
        }
        // `.common` so a wheel settle still fires while the run loop is in a
        // tracking mode; the display link already uses `.common`.
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    private func scheduleMomentumGrace(generation: UInt64, delay: TimeInterval) {
        momentumWatchdogTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMomentumGraceTimer(generation: generation)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        momentumWatchdogTimer = timer
    }

    private func scheduleFreezeWatchdog(generation: UInt64, delay: TimeInterval) {
        momentumWatchdogTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleFreezeWatchdogTimer(generation: generation)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        momentumWatchdogTimer = timer
    }

    /// The gesture generation that owns the most recent deferred callback.
    /// Exposed for the executable harness so stale-timer behaviour is testable
    /// without running a live run loop; not part of the public API.
    var currentGestureGeneration: UInt64 { gestureGeneration }

    /// Body of the deferred wheel settle. A callback from an older gesture, or one
    /// arriving after the phase moved on, must be inert (D09).
    func handleWheelSettleTimer(generation: UInt64) {
        guard self.gestureGeneration == generation, phase == .tracking else { return }
        if abs(pendingDelta) > 0.001 {
            // Input is still queued for the next VSYNC; settle after it lands.
            requestSettle()
        } else {
            settle()
        }
    }

    /// Body of the momentum grace timer. Same ownership contract as the wheel
    /// settle: only the newest tracking gesture may settle.
    func handleMomentumGraceTimer(generation: UInt64) {
        guard self.gestureGeneration == generation, phase == .tracking else { return }
        guard lastMomentumPhase == 0 else { return }
        if abs(currentVelocity) > 30.0 {
            beginDeceleration()
        } else {
            requestSettle()
        }
    }

    /// Body of the freeze watchdog. A wheel event or new gesture leaves `.idle`,
    /// and must not be aborted by a watchdog from the previous freeze release.
    func handleFreezeWatchdogTimer(generation: UInt64) {
        guard self.gestureGeneration == generation,
              lastMomentumPhase == 0,
              phase == .idle else { return }
        settle()
    }
    
    public func accumulateScroll(dx: CGFloat, dy: CGFloat, phase: Int64, momentumPhase: Int64, flags: CGEventFlags, timestamp: CFTimeInterval? = nil) {
        enqueueScroll(
            dx: dx,
            dy: dy,
            phase: phase,
            momentumPhase: momentumPhase,
            flags: flags,
            timestamp: timestamp
        )
    }
    
    public func handleContinuousScrollDelta(
        dx: CGFloat,
        dy: CGFloat,
        phase: Int64,
        momentumPhase: Int64,
        flags: CGEventFlags,
        timestamp: CFTimeInterval? = nil
    ) {
        enqueueScroll(
            dx: dx,
            dy: dy,
            phase: phase,
            momentumPhase: momentumPhase,
            flags: flags,
            timestamp: timestamp
        )
    }
    
    // MARK: - Settle / Snapping
    
    public func settle() {
        settleTimer?.invalidate()
        settleTimer = nil
        momentumWatchdogTimer?.invalidate()
        momentumWatchdogTimer = nil
        gestureGeneration &+= 1
        lastScrollTime = 0
        hasPendingSettle = false
        gestureOwner = .undecided
        handedBackThisGesture = false
        resetDiagonalIntent()
        directTouchResumable = false
        // A settle is a completed gesture: land any accepted tail exactly once, then
        // clear the ledger. Cancel/discard paths deliberately do not call this.
        if directTouch.isActive {
            let seamStart = currentOffset
            _ = flushDirectTouch(publish: true, frameStart: seamStart)
        }
        directTouch.reset()
        pendingDelta = 0.0
        pendingInteractiveDelta = 0.0

        let velocityAtSettle = currentVelocity.isFinite ? currentVelocity : 0
        phase = .idle

        queryMaxOffset()

        // Motion has stopped. Fold the accumulated offset into one cycle before the
        // projection/snap math below, so neither the snap target nor the spring can
        // carry an unbounded magnitude into a long session.
        normalizeLoopOffsetAtRest()

        let settings = SettingsStore.shared

        if settings.freezeOnRelease {
            // Never leave a freeze release outside the valid range (D01).
            clampRestingOffsetIfNeeded()
            smoothTargetOffset = currentOffset
            currentVelocity = 0.0
            settleVelocity = 0.0
            springState.position = currentOffset
            springState.target = currentOffset
            springState.velocity = 0
            onSettleRequested?(currentOffset)
            onSwipeSettled?(currentOffset)
            onAnimationCompleted?()
            return
        }

        // Overshot boundaries: spring back smoothly (linear strip only)
        if !isLoopModeEnabled {
            if currentOffset < 0 {
                scrollTo(target: 0, maxOffset: maxOffset, duration: settings.animationDuration, initialVelocity: velocityAtSettle, source: .user)
                return
            }
            if currentOffset > maxOffset {
                scrollTo(target: maxOffset, maxOffset: maxOffset, duration: settings.animationDuration, initialVelocity: velocityAtSettle, source: .user)
                return
            }
        }

        springState.position = currentOffset
        springState.target = currentOffset
        springState.velocity = 0

        if settings.snapToColumn && !settings.freeformScroll {
            let base = abs(smoothTargetOffset - currentOffset) > 0.5 ? smoothTargetOffset : currentOffset
            let projection = base + velocityAtSettle * 0.18
            settleVelocity = velocityAtSettle
            currentVelocity = 0.0
            // The callback owns the destination now. Park the controller at the
            // visible offset so a no-op callback cannot leave a stale target that
            // keeps `isMoving` true and the display link running forever.
            smoothTargetOffset = currentOffset
            onSettleRequested?(projection)
            onSwipeSettled?(projection)
            // `settleVelocity` is a handoff consumed by the next `scrollTo`, not a
            // motion flag: `phase`, `springState` and `isMoving` are already idle
            // here. Preserve it so the documented settle→scrollTo contract holds
            // (`testVelocityContinuityAcrossSettle`).
        } else {
            smoothTargetOffset = currentOffset
            currentVelocity = 0.0
            settleVelocity = 0.0
            onSettleRequested?(currentOffset)
            onSwipeSettled?(currentOffset)
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
        // Watchdog: If 150ms elapsed without scroll events, reset stale gesture owner so scroll never locks out.
        // The motion phase itself is ended by its own lift/settle path, never by this read-only gate.
        if lastScrollEventTime > 0 && (now - lastScrollEventTime) > 0.15 {
            gestureOwner = .undecided
            handedBackThisGesture = false
            resetDiagonalIntent()
        }
        lastScrollEventTime = now
        
        // Touch began / touch may begin resets gesture ownership decision
        if phase == 1 || phase == 32 {
            gestureOwner = .undecided
            handedBackThisGesture = false
            resetDiagonalIntent()
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
                if momentumPhase == 4 || (momentumPhase == 0 && (!settings.momentumScrolling || !settings.inertialScrolling || abs(currentVelocity) <= 30)) {
                    gestureOwner = .undecided
                    handedBackThisGesture = false
                    resetDiagonalIntent()
                }
            } else if momentumPhase == 4 {
                gestureOwner = .undecided
                handedBackThisGesture = false
                resetDiagonalIntent()
            }
            if shouldHandBackDiagonal(dx: dx, dy: dy) {
                return false
            }
            return true
        } else if gestureOwner == .app {
            if phase == 4 || phase == 8 || momentumPhase == 4 {
                gestureOwner = .undecided
                handedBackThisGesture = false
                resetDiagonalIntent()
                return false
            }
            if handedBackThisGesture {
                // One-way for the rest of this gesture: a late horizontal sample
                // must not steal ownership back from the app after hand-back.
                return false
            }
            // Allow breaking out of .app if the user switches decisively to horizontal scrolling
            let absX = abs(dx)
            let absY = abs(dy)
            if absX > 2.0 && absX > absY * 2.5 {
                gestureOwner = .strip
                stripVerticalIntentX = 0
                stripVerticalIntentY = 0
                stripVerticalIntentSamples = 0
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

    private func resetDiagonalIntent() {
        stripVerticalIntentX = 0
        stripVerticalIntentY = 0
        stripVerticalIntentSamples = 0
    }

    /// D06: detect a decisive vertical takeover inside a gesture that Iume already
    /// owns. Returns true exactly once, on the event that must be delivered to the
    /// app instead of being consumed.
    private func shouldHandBackDiagonal(dx: CGFloat, dy: CGFloat) -> Bool {
        guard diagonalHandbackEnabled, !handedBackThisGesture else { return false }
        stripVerticalIntentX += abs(dx)
        stripVerticalIntentY += abs(dy)
        stripVerticalIntentSamples += 1
        guard stripVerticalIntentSamples >= 3,
              stripVerticalIntentY > 12.0,
              stripVerticalIntentY > stripVerticalIntentX * 2.0,
              abs(dy) > abs(dx) * 2.5 else {
            return false
        }
        handBackGestureToApp()
        return true
    }

    /// Park the strip and stop consuming. Accepted input is landed first so the
    /// visible offset stays on the horizontal trajectory the user already produced;
    /// the current event itself is delivered unmodified (consumed events cannot be
    /// returned to another process).
    private func handBackGestureToApp() {
        // Hand-back ends Iume's ownership now, so deferred callbacks from this
        // gesture must not be able to settle or restart it afterwards. This is the
        // same invalidation `cancelAnimation` performs, but without clamping an
        // in-progress rubber-band overscroll: the strip stays where the horizontal
        // trajectory left it.
        settleTimer?.invalidate()
        settleTimer = nil
        momentumWatchdogTimer?.invalidate()
        momentumWatchdogTimer = nil
        hasPendingSettle = false
        gestureGeneration &+= 1
        lastScrollTime = 0

        handedBackThisGesture = true
        gestureOwner = .app
        if directTouch.isActive {
            let seamStart = currentOffset
            _ = flushDirectTouch(publish: true, frameStart: seamStart)
        }
        directTouch.reset()
        directTouchResumable = false
        pendingDelta = 0.0
        pendingInteractiveDelta = 0.0
        currentVelocity = 0.0
        settleVelocity = 0.0
        smoothTargetOffset = currentOffset
        springState.position = currentOffset
        springState.target = currentOffset
        springState.velocity = 0
        phase = .idle
    }
    
    public func shouldInterceptScroll(dx: CGFloat, dy: CGFloat, flags: CGEventFlags, phase: Int64 = 0) -> Bool {
        return shouldInterceptScroll(dx: dx, dy: dy, flags: flags, phase: phase, momentumPhase: 0)
    }
    
    @discardableResult
    public func startEventTap() -> Bool {
        guard eventTap == nil else { return eventTapIsActive }
        let mask = (1 << CGEventType.scrollWheel.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<ScrollController>.fromOpaque(userInfo).takeUnretainedValue()
            
            // Self-healing watchdog: auto re-enable if macOS timed out tap
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                print("[Iume][ERROR][Gesture] CGEventTap disabled by system type=\(type.rawValue); attempting re-enable")
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
            // CGEvent timestamps are mach-absolute nanoseconds, the same clock as
            // CACurrentMediaTime()/CADisplayLink.targetTimestamp.
            let eventTimestamp = Double(event.timestamp) / 1_000_000_000.0
            controller.traceGesture(
                "callback dx=\(dx) dy=\(dy) phase=\(phase) momentum=\(momentumPhase) timestampNs=\(event.timestamp)",
                force: phase == 1 || phase == 4 || phase == 8 || momentumPhase == 4
            )

            if controller.shouldInterceptScroll(dx: dx, dy: dy, flags: flags, phase: phase, momentumPhase: momentumPhase) {
                if Thread.isMainThread {
                    controller.enqueueScroll(
                        dx: dx,
                        dy: dy,
                        phase: phase,
                        momentumPhase: momentumPhase,
                        flags: flags,
                        timestamp: eventTimestamp
                    )
                } else {
                    DispatchQueue.main.async {
                        controller.enqueueScroll(
                            dx: dx,
                            dy: dy,
                            phase: phase,
                            momentumPhase: momentumPhase,
                            flags: flags,
                            timestamp: eventTimestamp
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
            eventTapIsActive = true
            print("[Iume][Gesture] CGEventTap created and enabled mask=scrollWheel runLoop=main/commonModes")
        } else {
            eventTapIsActive = false
            let bundleID = Bundle.main.bundleIdentifier ?? "com.iume.Iume"
            print("[Iume][ERROR][Gesture] CGEventTap creation failed; check Accessibility and Input Monitoring for \(bundleID)")
        }

        // Preserve the historical independent 3/4-finger monitoring path even when
        // the two-finger event tap cannot be created.
        startMultitouchMonitoring()
        return eventTapIsActive
    }
    
    public func stopEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.eventTap = nil
        }
        eventTapIsActive = false
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
