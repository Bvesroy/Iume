import Testing
import Foundation
import CoreGraphics
import QuartzCore
@testable import IumeCore

/// Regression tests for the Phase 2 sliding engine.
///
/// These exercise the shipped `SpringState` solver and `ScrollController` motion
/// pipeline. The suite is serialized because it temporarily changes the shared
/// settings that select snap/freeform behaviour.
@Suite("Sliding engine physics", .serialized)
@MainActor
struct SlidingPhysicsTests {

    /// Deterministic display clock. The controller consumes timestamps through the
    /// same entry point as `CADisplayLink`, so tests never depend on wall time.
    @MainActor
    private final class MotionClock {
        private(set) var now = CACurrentMediaTime()

        func prime(_ controller: ScrollController) {
            controller.displayLinkFired(timestamp: now)
        }

        func advance(_ controller: ScrollController, seconds: Double, hz: Double) {
            let step = 1.0 / hz
            let count = max(1, Int((seconds * hz).rounded()))
            for _ in 0..<count {
                now += step
                controller.displayLinkFired(timestamp: now)
            }
        }

        func advanceOne(_ controller: ScrollController, hz: Double) {
            now += 1.0 / hz
            controller.displayLinkFired(timestamp: now)
        }

        func jump(_ controller: ScrollController, seconds: Double) {
            now += seconds
            controller.displayLinkFired(timestamp: now)
        }
    }

    /// Applies the baseline settings for the serialized suite.
    ///
    /// `ScrollController` reads `SettingsStore.shared` directly, so these tests
    /// necessarily touch the shared instance. The standalone harness under
    /// `scripts/audit` uses an in-memory settings stub instead. A future production
    /// refactor should inject the store so this suite can be fully isolated too.
    private func makeController(maxOffset: CGFloat = 5000) -> ScrollController {
        SettingsStore.shared.snapToColumn = false
        SettingsStore.shared.freezeOnRelease = false
        SettingsStore.shared.freeformScroll = false
        SettingsStore.shared.momentumScrolling = true
        SettingsStore.shared.scrollSmoothness = 0.75
        let controller = ScrollController()
        controller.maxOffset = maxOffset
        return controller
    }

    private func springPosition(target: CGFloat, seconds: Double, hz: Double) -> CGFloat {
        var spring = SpringState(position: 0, velocity: 0, target: target)
        let dt = 1.0 / CGFloat(hz)
        let steps = Int((seconds * hz).rounded())
        for _ in 0..<steps {
            spring.step(dt: dt)
        }
        return spring.position
    }

    @Test("Spring position is independent of display cadence")
    func springFrameRateIndependence() {
        let samples = [60.0, 80.0, 120.0, 240.0].map { hz in
            springPosition(target: 500, seconds: 0.10, hz: hz)
        }
        let spread = (samples.max() ?? 0) - (samples.min() ?? 0)
        #expect(spread < 0.01, "spread \(spread) across \(samples)")
    }

    @Test("A pathological delta is clamped, not integrated")
    func springStallClamp() {
        var spring = SpringState(position: 0, velocity: 0, target: 100)
        spring.step(dt: 10.0)
        #expect(spring.position.isFinite)
        #expect(spring.position <= 100.001)
        #expect(spring.position >= 0)
    }

    @Test("Critical damping never overshoots or reverses")
    func criticalDampingNoOvershoot() {
        var spring = SpringState(position: 0, velocity: 0, target: 100)
        spring.dampingRatio = 1.0
        var previous = spring.position
        for _ in 0..<240 {
            spring.step(dt: 1.0 / 120.0)
            #expect(spring.position <= 100.000001)
            #expect(spring.position >= previous - 0.000001)
            previous = spring.position
        }
        #expect(spring.isAtRest)
    }

    @Test("Retarget preserves position and velocity")
    func retargetContinuity() {
        var spring = SpringState(position: 0, velocity: 0, target: 500)
        for _ in 0..<6 {
            spring.step(dt: 1.0 / 120.0)
        }
        let position = spring.position
        let velocity = spring.velocity
        #expect(velocity > 0)
        spring.retarget(-250)
        #expect(spring.position == position)
        #expect(spring.velocity == velocity)
        #expect(spring.target == -250)
    }

    @Test("Controller reaches the same offset at 60/80/120/240 Hz")
    func controllerFrameRateIndependence() {
        var samples: [CGFloat] = []
        for hz in [60.0, 80.0, 120.0, 240.0] {
            let controller = makeController()
            let clock = MotionClock()
            controller.scrollTo(target: 500, maxOffset: 5000)
            clock.prime(controller)
            clock.advance(controller, seconds: 0.10, hz: hz)
            samples.append(controller.currentOffset)
            #expect(controller.currentOffset > 0)
        }
        let spread = (samples.max() ?? 0) - (samples.min() ?? 0)
        #expect(spread < 0.01, "spread \(spread) across \(samples)")
    }

    @Test("Rapid keyboard retarget does not reset position or velocity")
    func rapidRetarget() {
        let controller = makeController(maxOffset: 2000)
        let clock = MotionClock()
        controller.scrollTo(target: 800, maxOffset: 2000)
        clock.prime(controller)
        clock.advance(controller, seconds: 0.08, hz: 120)

        let position = controller.currentOffset
        let velocity = controller.currentVelocity
        #expect(position > 0)

        controller.scrollTo(target: 300, maxOffset: 2000)
        #expect(controller.currentOffset == position)
        #expect(abs(controller.currentVelocity - velocity) < 0.0001)
        #expect(controller.isSpringAnimating)

        clock.advanceOne(controller, hz: 120)
        let firstStep = abs(controller.currentOffset - position)
        #expect(firstStep <= abs(velocity) / 120.0 + 5.0)
    }

    @Test("Long jump settles exactly on the target")
    func longJump() {
        let controller = makeController(maxOffset: 3000)
        let clock = MotionClock()
        controller.scrollTo(target: 3000, maxOffset: 3000)
        clock.prime(controller)
        clock.advance(controller, seconds: 2.0, hz: 120)
        #expect(abs(controller.currentOffset - 3000) <= 0.001)
        #expect(controller.springState.isAtRest)
        #expect(!controller.isMoving)
    }

    @Test("Reversed movement stays continuous and settles at the new target")
    func reversedMovement() {
        let controller = makeController(maxOffset: 2000)
        let clock = MotionClock()
        controller.scrollTo(target: 1500, maxOffset: 2000)
        clock.prime(controller)
        clock.advance(controller, seconds: 0.08, hz: 120)

        let position = controller.currentOffset
        let velocity = controller.currentVelocity
        controller.scrollTo(target: 100, maxOffset: 2000)
        #expect(controller.currentOffset == position)
        #expect(abs(controller.currentVelocity - velocity) < 0.0001)

        clock.advance(controller, seconds: 1.5, hz: 120)
        #expect(abs(controller.currentOffset - 100) <= 0.001)
    }

    @Test("A stalled display tick does not teleport")
    func stalledTick() {
        let controller = makeController(maxOffset: 3000)
        let clock = MotionClock()
        controller.scrollTo(target: 3000, maxOffset: 3000)
        clock.prime(controller)
        clock.advance(controller, seconds: 0.05, hz: 120)

        let beforeStall = controller.currentOffset
        clock.jump(controller, seconds: 10.0)
        #expect(abs(controller.currentOffset - beforeStall) <= 0.0001)

        clock.advanceOne(controller, hz: 120)
        #expect(abs(controller.currentOffset - beforeStall) < 300)
    }

    @Test("Gesture lift flushes the last pending delta without a jump")
    func gestureLiftFlush() {
        let controller = makeController(maxOffset: 5000)
        let clock = MotionClock()
        controller.applyInteractiveDelta(40, maxOffset: 5000, timestamp: clock.now)
        clock.advanceOne(controller, hz: 120)

        let beforeLift = controller.currentOffset
        controller.applyInteractiveDelta(15, maxOffset: 5000, timestamp: clock.now)
        controller.endInteractiveSwipe(maxOffset: 5000)

        #expect(abs(controller.currentOffset - (beforeLift + 15)) <= 0.51)
        #expect(!controller.isSwipingInteractively)
    }

    @Test("Repeated gesture interruptions never create a discontinuity")
    func repeatedInterruptions() {
        let controller = makeController(maxOffset: 2000)
        let clock = MotionClock()
        var previous = controller.currentOffset
        var maxFrame: CGFloat = 0

        controller.scrollTo(target: 600, maxOffset: 2000)
        clock.prime(controller)
        for index in 0..<40 {
            if index % 3 == 0 {
                controller.applyInteractiveDelta(
                    index % 2 == 0 ? 24 : -24,
                    maxOffset: 2000,
                    timestamp: clock.now
                )
            } else {
                controller.scrollTo(
                    target: CGFloat((index * 137) % 1800),
                    maxOffset: 2000
                )
            }
            clock.advanceOne(controller, hz: 120)
            #expect(controller.currentOffset.isFinite)
            maxFrame = max(maxFrame, abs(controller.currentOffset - previous))
            previous = controller.currentOffset
        }
        #expect(maxFrame < 400, "max frame displacement \(maxFrame)")
    }

    @Test("Settle re-queries a shrinking strip and clamps the offset")
    func settleReclampsMaxOffset() {
        let controller = makeController(maxOffset: 2000)
        var queriedMax: CGFloat = 2000
        controller.onQueryMaxOffset = { queriedMax }
        var completions = 0
        controller.onAnimationCompleted = { completions += 1 }

        let clock = MotionClock()
        controller.scrollTo(target: 2000, maxOffset: 2000)
        clock.prime(controller)
        clock.advance(controller, seconds: 0.05, hz: 120)

        queriedMax = 700
        clock.advance(controller, seconds: 1.5, hz: 120)
        #expect(controller.currentOffset <= 700.001)
        #expect(completions == 1)
    }

    @Test("Momentum coast skips a pathological gap")
    func momentumStall() {
        let controller = makeController(maxOffset: 5000)
        let clock = MotionClock()
        controller.enqueueScroll(dx: -40, dy: 0, phase: 1, momentumPhase: 0, flags: [])
        clock.prime(controller)
        clock.advance(controller, seconds: 0.01, hz: 120)
        controller.enqueueScroll(dx: -40, dy: 0, phase: 2, momentumPhase: 0, flags: [])
        clock.advance(controller, seconds: 0.01, hz: 120)
        controller.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [])
        clock.advance(controller, seconds: 0.02, hz: 120)

        let beforeStall = controller.currentOffset
        clock.jump(controller, seconds: 5.0)
        #expect(abs(controller.currentOffset - beforeStall) <= 0.0001)
    }

    @Test("A near-target scroll clears the destination and goes idle")
    func nearTargetScrollIsIdle() {
        let controller = makeController(maxOffset: 5000)
        controller.scrollTo(target: 0.4, maxOffset: 5000)

        #expect(abs(controller.currentOffset - 0.4) <= 0.0001)
        #expect(abs(controller.smoothTargetOffset - 0.4) <= 0.0001)
        #expect(!controller.isMoving)
    }

    @Test("A no-op settle callback cannot pin the controller to a stale target")
    func noOpSettleReleasesTarget() {
        let controller = makeController(maxOffset: 5000)
        let settings = SettingsStore.shared
        let previousSnap = settings.snapToColumn
        let previousSmoothness = settings.scrollSmoothness
        let previousNatural = settings.trackpadNaturalScroll
        settings.snapToColumn = true
        settings.scrollSmoothness = 0.90
        settings.trackpadNaturalScroll = false
        defer {
            settings.trackpadNaturalScroll = previousNatural
            settings.snapToColumn = previousSnap
            settings.scrollSmoothness = previousSmoothness
        }

        controller.enqueueScroll(dx: 100, dy: 0, phase: 0, momentumPhase: 0, flags: [])
        let clock = MotionClock()
        clock.prime(controller)
        clock.advanceOne(controller, hz: 120)
        #expect(abs(controller.smoothTargetOffset - controller.currentOffset) > 5)

        controller.settle()
        #expect(!controller.isMoving)
    }

    @Test("A discrete wheel event takes over a running spring")
    func wheelInterruptsSpring() {
        let controller = makeController(maxOffset: 2000)
        let clock = MotionClock()
        controller.scrollTo(target: 800, maxOffset: 2000)
        clock.prime(controller)
        clock.advance(controller, seconds: 0.08, hz: 120)

        controller.enqueueScroll(dx: -30, dy: 0, phase: 0, momentumPhase: 0, flags: [])
        #expect(!controller.isSpringAnimating)
        #expect(controller.isActivelyScrolling)
        #expect(controller.currentVelocity == 0)

        let beforeWheel = controller.currentOffset
        clock.advanceOne(controller, hz: 120)
        #expect(abs(controller.currentOffset - beforeWheel) > 1)
    }

    @Test("A discrete wheel event takes over a momentum coast")
    func wheelInterruptsCoast() {
        let controller = makeController(maxOffset: 5000)
        let previousNatural = SettingsStore.shared.trackpadNaturalScroll
        SettingsStore.shared.trackpadNaturalScroll = false
        defer { SettingsStore.shared.trackpadNaturalScroll = previousNatural }
        let clock = MotionClock()

        controller.enqueueScroll(dx: 40, dy: 0, phase: 1, momentumPhase: 0, flags: [])
        clock.prime(controller)
        clock.advanceOne(controller, hz: 120)
        controller.enqueueScroll(dx: 40, dy: 0, phase: 2, momentumPhase: 0, flags: [])
        clock.advanceOne(controller, hz: 120)
        controller.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [])
        clock.advanceOne(controller, hz: 120)
        #expect(controller.isMomentumCoasting)

        controller.enqueueScroll(dx: 20, dy: 0, phase: 0, momentumPhase: 0, flags: [])
        #expect(!controller.isMomentumCoasting)
        #expect(controller.isActivelyScrolling)
    }

    @Test("The lift event's final delta reaches the visible offset")
    func liftEventFlush() {
        let controller = makeController(maxOffset: 5000)
        let previousNatural = SettingsStore.shared.trackpadNaturalScroll
        SettingsStore.shared.trackpadNaturalScroll = false
        defer { SettingsStore.shared.trackpadNaturalScroll = previousNatural }
        let clock = MotionClock()

        controller.enqueueScroll(dx: 40, dy: 0, phase: 1, momentumPhase: 0, flags: [])
        clock.prime(controller)
        clock.advanceOne(controller, hz: 120)
        controller.enqueueScroll(dx: 40, dy: 0, phase: 2, momentumPhase: 0, flags: [])
        clock.advanceOne(controller, hz: 120)

        let beforeLift = controller.currentOffset
        controller.enqueueScroll(dx: 12, dy: 0, phase: 4, momentumPhase: 0, flags: [])
        #expect(abs(controller.currentOffset - (beforeLift + 12)) <= 0.51)
    }

    @Test("A direct swipe preserves its lift velocity for the settle spring")
    func swipeLiftVelocity() {
        let controller = makeController(maxOffset: 5000)
        let clock = MotionClock()
        var capturedVelocity: CGFloat = -1
        controller.onSettleRequested = { _ in
            capturedVelocity = controller.settleVelocity
        }

        controller.applyInteractiveDelta(60, maxOffset: 5000, timestamp: clock.now)
        clock.advanceOne(controller, hz: 120)
        controller.applyInteractiveDelta(60, maxOffset: 5000, timestamp: clock.now)
        clock.advanceOne(controller, hz: 120)

        let liftVelocity = controller.currentVelocity
        controller.endInteractiveSwipe(maxOffset: 5000)
        #expect(liftVelocity > 1)
        #expect(abs(capturedVelocity - liftVelocity) <= 0.0001)
    }

    // MARK: - Phase 3: direct-touch temporal resampling

    /// Replays a direct-touch gesture, one display tick per frame, with the point
    /// deltas returned by `packets(frame)`. Returns the per-frame steps and the
    /// offsets after the lift.
    @MainActor
    private func replayDirectTouch(
        hz: Double,
        frames: Int,
        smoothness: Double = 0.75,
        packets: (Int) -> [CGFloat],
        timestampOffset: (Int, Int) -> Double = { _, _ in 0 }
    ) -> (controller: ScrollController, steps: [CGFloat], offsets: [CGFloat]) {
        let controller = makeController(maxOffset: 100_000)
        SettingsStore.shared.scrollSmoothness = smoothness
        SettingsStore.shared.scrollSensitivity = 1.2
        SettingsStore.shared.trackpadNaturalScroll = false
        SettingsStore.shared.momentumScrolling = false
        defer {
            SettingsStore.shared.scrollSensitivity = 1.0
            SettingsStore.shared.trackpadNaturalScroll = true
            SettingsStore.shared.momentumScrolling = true
            SettingsStore.shared.scrollSmoothness = 0.75
        }

        let clock = MotionClock()
        clock.prime(controller)
        var steps: [CGFloat] = []
        var offsets: [CGFloat] = []
        var previous = controller.currentOffset

        controller.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: clock.now)
        clock.advanceOne(controller, hz: hz)

        for frame in 0..<frames {
            for (index, delta) in packets(frame).enumerated() {
                controller.enqueueScroll(
                    dx: delta,
                    dy: 0,
                    phase: 2,
                    momentumPhase: 0,
                    flags: [],
                    timestamp: clock.now + timestampOffset(frame, index)
                )
            }
            clock.advanceOne(controller, hz: hz)
            steps.append(controller.currentOffset - previous)
            previous = controller.currentOffset
            offsets.append(controller.currentOffset)
        }

        controller.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: clock.now)
        clock.advanceOne(controller, hz: hz)
        return (controller, steps, offsets)
    }

    @Test("Bursty direct-touch input has no frozen frames or spikes")
    func directTouchBurstyResampling() {
        for hz in [60.0, 80.0, 120.0, 240.0] {
            let result = replayDirectTouch(hz: hz, frames: 60) { frame in
                frame % 2 == 1 ? [8, 8] : []
            }
            let sampled = result.steps.dropFirst().map { abs($0) }
            let frozen = sampled.filter { $0 < 0.001 }.count
            #expect(frozen <= 3, "frozen \(frozen)/\(sampled.count) at \(hz) Hz")
            #expect((sampled.max() ?? 0) <= 12.0, "max step \(sampled.max() ?? 0) at \(hz) Hz")
            #expect(abs(result.controller.currentOffset - 576) <= 0.5, "total \(result.controller.currentOffset) at \(hz) Hz")
        }
    }

    @Test("Uniform direct touch is delivered 1:1")
    func directTouchUniformTransparency() {
        let result = replayDirectTouch(hz: 120, frames: 60) { _ in [8] }
        let steps = result.steps.dropFirst()
        #expect(steps.allSatisfy { abs(abs($0) - 9.6) < 0.01 })
        #expect(steps.allSatisfy { $0 > 0.001 })
        #expect(abs(result.controller.currentOffset - 576) <= 0.5)
    }

    @Test("Smoothness does not change the direct-touch trajectory")
    func directTouchIgnoresSmoothness() {
        let bursty: (Int) -> [CGFloat] = { $0 % 2 == 1 ? [8, 8] : [] }
        let smooth0 = replayDirectTouch(hz: 120, frames: 40, smoothness: 0.0, packets: bursty).offsets
        let smooth1 = replayDirectTouch(hz: 120, frames: 40, smoothness: 1.0, packets: bursty).offsets
        #expect(smooth0 == smooth1)
    }

    @Test("Input slower than the display rate still drains continuously")
    func directTouchSlowInputAtHighRefresh() {
        let frames = 120
        var packetFrames: [Int: [CGFloat]] = [:]
        for event in 0..<30 {
            let frame = min(frames - 1, Int(((Double(event) / 60.0) * 240.0).rounded()))
            packetFrames[frame, default: []].append(contentsOf: [8, 8])
        }
        let result = replayDirectTouch(hz: 240, frames: frames) { packetFrames[$0] ?? [] }
        let sampled = result.steps.dropFirst().map { abs($0) }
        let frozen = sampled.filter { $0 < 0.001 }.count
        #expect(frozen <= 3, "frozen \(frozen)/\(sampled.count)")
        #expect((sampled.max() ?? 0) <= 12.0, "max step \(sampled.max() ?? 0)")
        #expect(abs(result.controller.currentOffset - 576) <= 0.5)
        #expect(abs(result.controller.directTouchPending) <= 0.0001)
    }

    @Test("A direction reversal lands on the first frame")
    func directTouchReversal() {
        let result = replayDirectTouch(hz: 120, frames: 80) { frame in
            frame < 20 ? [6] : (frame < 40 ? [-6] : [])
        }
        #expect(result.steps[20] < 0)
        #expect(result.steps.firstIndex(where: { $0 < 0 }) == 20)
        #expect(abs(result.controller.currentOffset) <= 0.5)
    }

    @Test("Tiny and out-of-order samples preserve the total")
    func directTouchTinyAndOutOfOrder() {
        let tiny = replayDirectTouch(hz: 120, frames: 120) { _ in [0.005] }
        #expect(abs(tiny.controller.currentOffset - 120 * 0.005 * 1.2) <= 0.01)

        let backwards = replayDirectTouch(
            hz: 120,
            frames: 60,
            packets: { _ in [8, 8] },
            timestampOffset: { _, index in index == 0 ? 0 : -0.004 }
        )
        #expect(backwards.steps.dropFirst().allSatisfy { abs(abs($0) - 19.2) < 0.01 })
        #expect(abs(backwards.controller.currentOffset - 1152) <= 0.5)
    }

    @Test("Release flushes pending touch input exactly once")
    func directTouchReleaseFlush() {
        let result = replayDirectTouch(hz: 120, frames: 40) { frame in
            frame == 39 ? [8, 8] : (frame % 2 == 1 ? [8, 8] : [])
        }
        #expect(abs(result.controller.directTouchPending) <= 0.0001)
        #expect(abs(result.controller.currentOffset - 384) <= 0.5)

        let afterRelease = result.controller.currentOffset
        result.controller.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: 1)
        #expect(abs(result.controller.currentOffset - afterRelease) <= 0.0001)
    }

    @Test("A cancelled gesture never leaks input into the next one")
    func directTouchCancelScoping() {
        let controller = makeController(maxOffset: 5000)
        SettingsStore.shared.scrollSensitivity = 1.2
        SettingsStore.shared.trackpadNaturalScroll = false
        SettingsStore.shared.momentumScrolling = false
        defer {
            SettingsStore.shared.scrollSensitivity = 1.0
            SettingsStore.shared.trackpadNaturalScroll = true
            SettingsStore.shared.momentumScrolling = true
        }
        let clock = MotionClock()
        clock.prime(controller)

        controller.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: clock.now)
        clock.advanceOne(controller, hz: 120)
        controller.enqueueScroll(dx: 10, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: clock.now)
        controller.enqueueScroll(dx: 10, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: clock.now)
        let beforeCancel = controller.currentOffset
        controller.enqueueScroll(dx: 0, dy: 0, phase: 8, momentumPhase: 0, flags: [], timestamp: clock.now)
        clock.advanceOne(controller, hz: 120)
        #expect(abs(controller.currentOffset - beforeCancel) <= 0.0001)
        #expect(!controller.isDirectTouchResampling)

        controller.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: clock.now)
        clock.advanceOne(controller, hz: 120)
        controller.enqueueScroll(dx: 5, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: clock.now)
        controller.enqueueScroll(dx: 5, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: clock.now)
        controller.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: clock.now)
        #expect(abs(controller.currentOffset - (beforeCancel + 12)) <= 0.01)
    }

    @Test("Diagonal hand-back is off by default for this release")
    func diagonalHandBackDefaultOff() {
        let controller = makeController(maxOffset: 5000)
        controller.diagonalHandbackEnabled = false
        _ = controller.shouldInterceptScroll(dx: 5, dy: 0, flags: [], phase: 1)
        _ = controller.shouldInterceptScroll(dx: 5, dy: 0, flags: [], phase: 2)
        for _ in 0..<3 {
            #expect(controller.shouldInterceptScroll(dx: 1, dy: 10, flags: [], phase: 2))
        }
        #expect(controller.gestureOwner == .strip)
    }

    @Test("Enabled diagonal hand-back delivers the decisive vertical event")
    func diagonalHandBackDeliversEvent() {
        let controller = makeController(maxOffset: 5000)
        controller.diagonalHandbackEnabled = true
        _ = controller.shouldInterceptScroll(dx: 5, dy: 0, flags: [], phase: 1)
        _ = controller.shouldInterceptScroll(dx: 5, dy: 0, flags: [], phase: 2)
        _ = controller.shouldInterceptScroll(dx: 1, dy: 10, flags: [], phase: 2)
        #expect(!controller.shouldInterceptScroll(dx: 1, dy: 10, flags: [], phase: 2))
        #expect(controller.gestureOwner == .app)
        #expect(!controller.shouldInterceptScroll(dx: 10, dy: 0, flags: [], phase: 2))
    }

    // MARK: - Phase 2 P0 regressions (D01 / D02 / D09)

    @Test("A spring in flight lands on a shrunken max offset")
    func springLandsOnShrunkMaxOffset() {
        let controller = makeController(maxOffset: 6000)
        let clock = MotionClock()
        controller.scrollTo(target: 5000, maxOffset: 6000)
        clock.prime(controller)
        clock.advance(controller, seconds: 0.05, hz: 120)
        #expect(controller.isSpringAnimating)

        controller.maxOffset = 1400
        clock.advance(controller, seconds: 3.0, hz: 120)

        #expect(abs(controller.currentOffset - 1400) <= 0.5)
        #expect(!controller.isMoving)
    }

    @Test("A deferred max-offset query retargets the finishing spring")
    func deferredMaxQueryRetargetsSpring() {
        let controller = makeController(maxOffset: 6000)
        var queried: CGFloat = 6000
        controller.onQueryMaxOffset = { queried }
        let clock = MotionClock()
        controller.scrollTo(target: 5000, maxOffset: 6000)
        clock.prime(controller)
        clock.advance(controller, seconds: 0.05, hz: 120)

        queried = 1200
        clock.advance(controller, seconds: 3.0, hz: 120)

        #expect(abs(controller.currentOffset - 1200) <= 0.5)
        #expect(abs(controller.maxOffset - 1200) <= 0.001)
        #expect(!controller.isMoving)
    }

    @Test("A freeze settle clamps the resting offset before callbacks")
    func freezeSettleClampsAfterShrink() {
        let controller = makeController(maxOffset: 5000)
        SettingsStore.shared.freezeOnRelease = true
        defer { SettingsStore.shared.freezeOnRelease = false }

        controller.setOffset(1800, maxOffset: 5000)
        controller.maxOffset = 1200
        var offsets: [CGFloat] = []
        controller.onSettleRequested = { offsets.append($0) }

        controller.settle()

        #expect(abs(controller.currentOffset - 1200) <= 0.001)
        #expect(offsets == [1200])
        #expect(!controller.isMoving)
        #expect(controller.springState.isAtRest)
        #expect(controller.settleVelocity == 0)
    }

    @Test("Cancelling after a shrink cannot park outside the range")
    func cancelAnimationClampsParkedOffset() {
        let controller = makeController(maxOffset: 5000)
        controller.setOffset(1800, maxOffset: 5000)
        controller.maxOffset = 1200

        controller.cancelAnimation()

        #expect(abs(controller.currentOffset - 1200) <= 0.001)
        #expect(!controller.isMoving)
    }

    @Test("Freeze-on-release preserves the released offset and stops")
    func freezeReleasePreservesReleasedOffset() {
        let controller = makeController(maxOffset: 5000)
        SettingsStore.shared.freezeOnRelease = true
        defer { SettingsStore.shared.freezeOnRelease = false }

        let clock = MotionClock()
        controller.applyInteractiveDelta(120, maxOffset: 5000, timestamp: clock.now)
        clock.advanceOne(controller, hz: 120)
        controller.endInteractiveSwipe(maxOffset: 5000)
        let released = controller.currentOffset

        #expect(!controller.isSwipingInteractively)
        #expect(!controller.isMoving)
        #expect(controller.settleVelocity == 0)

        clock.advance(controller, seconds: 0.3, hz: 120)
        #expect(abs(controller.currentOffset - released) <= 0.0001)
    }

    @Test("An unclaimed lift clears the residual spring velocity")
    func unclaimedLiftClearsResidualVelocity() {
        let controller = makeController(maxOffset: 5000)
        let clock = MotionClock()
        controller.applyInteractiveDelta(80, maxOffset: 5000, timestamp: clock.now)
        clock.advanceOne(controller, hz: 120)

        controller.endInteractiveSwipe(maxOffset: 5000)

        #expect(controller.settleVelocity == 0)
        #expect(controller.currentVelocity == 0)
        #expect(controller.springState.isAtRest)
        #expect(!controller.isMoving)

        let released = controller.currentOffset
        clock.advance(controller, seconds: 0.3, hz: 120)
        #expect(abs(controller.currentOffset - released) <= 0.0001)
    }

    @Test("Snap-disabled settle leaves zero residual velocity")
    func snapDisabledSettleClearsVelocity() {
        let controller = makeController(maxOffset: 5000)
        controller.setOffset(600, maxOffset: 5000)

        controller.settle()

        #expect(abs(controller.currentOffset - 600) <= 0.001)
        #expect(controller.currentVelocity == 0)
        #expect(controller.settleVelocity == 0)
        #expect(controller.springState.isAtRest)
        #expect(!controller.isMoving)
    }

    @Test("A no-op snap settle stays idle while preserving the velocity handoff")
    func noOpSnapSettlePreservesVelocityHandoff() {
        let controller = makeController(maxOffset: 5000)
        SettingsStore.shared.snapToColumn = true
        defer { SettingsStore.shared.snapToColumn = false }

        controller.setOffset(600, maxOffset: 5000)
        controller.settle()

        // `settleVelocity` is a handoff for the next `scrollTo`, not a motion
        // signal; `isMoving` must be false regardless of its value.
        #expect(!controller.isMoving)
        #expect(controller.springState.isAtRest)
        #expect(abs(controller.smoothTargetOffset - controller.currentOffset) <= 0.0001)
    }

    @Test("A stale wheel settle after cancel is inert")
    func staleWheelSettleAfterCancelIsInert() {
        let controller = makeController(maxOffset: 5000)
        controller.setOffset(300, maxOffset: 5000)
        var settles = 0
        controller.onSettleRequested = { _ in settles += 1 }
        controller.enqueueScroll(dx: 40, dy: 0, phase: 1, momentumPhase: 0, flags: [])
        let generation = controller.currentGestureGeneration

        controller.cancelAnimation()
        controller.handleWheelSettleTimer(generation: generation)

        #expect(settles == 0)
        #expect(!controller.isMoving)
    }

    @Test("A stale freeze watchdog after cancel cannot settle")
    func staleFreezeWatchdogAfterCancelIsInert() {
        let controller = makeController(maxOffset: 5000)
        SettingsStore.shared.snapToColumn = true
        defer { SettingsStore.shared.snapToColumn = false }

        controller.setOffset(300, maxOffset: 5000)
        var settles = 0
        controller.onSettleRequested = { _ in settles += 1 }
        controller.enqueueScroll(dx: 0, dy: 0, phase: 0, momentumPhase: 0, flags: [])
        let generation = controller.currentGestureGeneration

        controller.cancelAnimation()
        controller.handleFreezeWatchdogTimer(generation: generation)

        #expect(settles == 0)
        #expect(!controller.isMoving)
    }

    @Test("A freeze watchdog is inert while a new gesture is tracking")
    func freezeWatchdogInertDuringTracking() {
        let controller = makeController(maxOffset: 5000)
        controller.setOffset(300, maxOffset: 5000)
        var settles = 0
        controller.onSettleRequested = { _ in settles += 1 }
        controller.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [])

        controller.handleFreezeWatchdogTimer(generation: controller.currentGestureGeneration)

        #expect(settles == 0)
        #expect(controller.isActivelyScrolling)
    }

    @Test("Retargeting a spring lands on the new destination exactly once")
    func retargetLandsOnce() {
        let controller = makeController(maxOffset: 5000)
        var completions = 0
        controller.onAnimationCompleted = { completions += 1 }
        let clock = MotionClock()
        controller.scrollTo(target: 4000, maxOffset: 5000)
        clock.prime(controller)
        clock.advance(controller, seconds: 0.08, hz: 120)

        controller.scrollTo(target: 900, maxOffset: 5000)
        clock.advance(controller, seconds: 3.0, hz: 120)

        #expect(abs(controller.currentOffset - 900) <= 1.0)
        #expect(!controller.isMoving)
        #expect(completions == 1)
    }

    @Test("A new gesture during a settle takes ownership for good")
    func newGestureDuringSettleOwnsMotion() {
        let controller = makeController(maxOffset: 5000)
        let clock = MotionClock()
        controller.scrollTo(target: 4000, maxOffset: 5000)
        clock.prime(controller)
        clock.advance(controller, seconds: 0.05, hz: 120)
        #expect(controller.isSpringAnimating)

        controller.applyInteractiveDelta(-50, maxOffset: 5000, timestamp: clock.now)
        clock.advanceOne(controller, hz: 120)
        #expect(controller.isSwipingInteractively)
        controller.endInteractiveSwipe(maxOffset: 5000)
        let rest = controller.currentOffset
        #expect(!controller.isMoving)
        #expect(rest < 4000)

        clock.advance(controller, seconds: 0.4, hz: 120)
        #expect(abs(controller.currentOffset - rest) <= 0.0001)
    }
}
