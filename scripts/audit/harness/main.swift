import Foundation
import CoreGraphics
import QuartzCore
import Darwin

// Standalone physics/controller harness.
//
// Compiles the real production sources (`SpringState.swift`,
// `ScrollController.swift`) against a minimal SettingsStore stub. It exercises the
// shipped motion pipeline without SwiftUI, so it runs on machines that only have
// Command Line Tools installed.

private var failures = 0
private var checks = 0

@MainActor
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL: \(message)")
    }
}

@MainActor
func checkClose(
    _ actual: CGFloat,
    _ expected: CGFloat,
    tolerance: CGFloat,
    _ message: String
) {
    check(abs(actual - expected) <= tolerance, "\(message) (actual \(actual), expected \(expected) ± \(tolerance))")
}

@MainActor
final class MotionClock {
    private(set) var now: CFTimeInterval

    init() {
        now = CACurrentMediaTime()
    }

    /// Establish a deterministic epoch after a motion start. A backward timestamp
    /// is a no-op for physics but pins `lastFrameTimestamp` to this value.
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

    /// Advance the controller by an arbitrary (pathological) gap.
    func jump(_ controller: ScrollController, seconds: Double) {
        now += seconds
        controller.displayLinkFired(timestamp: now)
    }
}

@MainActor
func makeController(maxOffset: CGFloat = 5000) -> ScrollController {
    let controller = ScrollController()
    controller.maxOffset = maxOffset
    SettingsStore.shared.snapToColumn = false
    SettingsStore.shared.freezeOnRelease = false
    SettingsStore.shared.freeformScroll = false
    SettingsStore.shared.momentumScrolling = true
    SettingsStore.shared.scrollSmoothness = 0.75
    return controller
}

@MainActor
func springPosition(target: CGFloat, seconds: Double, hz: Double) -> CGFloat {
    var spring = SpringState(position: 0, velocity: 0, target: target)
    let dt = 1.0 / CGFloat(hz)
    let steps = Int((seconds * hz).rounded())
    for _ in 0..<steps {
        spring.step(dt: dt)
    }
    return spring.position
}

// MARK: - Direct-touch replay harness (D04)

@MainActor
struct DirectTouchReplay {
    var offsets: [CGFloat] = []
    var steps: [CGFloat] = []
    var pendings: [CGFloat] = []
    var rates: [CGFloat] = []
    var controller: ScrollController!
}

/// Replays one direct-touch gesture. `packets(frame)` returns the point deltas
/// delivered just before display frame `frame`; the display schedule is `hz`.
@MainActor
func replayDirectTouch(
    hz: Double,
    frames: Int,
    smoothness: Double = 0.75,
    sensitivity: Double = 1.2,
    momentum: Bool = false,
    releasePhase: Int64? = 4,
    packets: (Int) -> [CGFloat],
    timestampOffset: (Int, Int) -> Double = { _, _ in 0 }
) -> DirectTouchReplay {
    let controller = makeController(maxOffset: 100_000)
    SettingsStore.shared.scrollSmoothness = smoothness
    SettingsStore.shared.scrollSensitivity = sensitivity
    SettingsStore.shared.trackpadNaturalScroll = false
    SettingsStore.shared.momentumScrolling = momentum
    SettingsStore.shared.snapToColumn = false
    SettingsStore.shared.freezeOnRelease = false

    let clock = MotionClock()
    clock.prime(controller)
    var replay = DirectTouchReplay()
    replay.controller = controller

    // Phase 1 establishes the gesture epoch. The tap sends it even when the first
    // sample is zero.
    controller.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: clock.now)
    clock.advanceOne(controller, hz: hz)
    var previous = controller.currentOffset

    for frame in 0..<frames {
        for (index, delta) in packets(frame).enumerated() {
            let time = clock.now + timestampOffset(frame, index)
            controller.enqueueScroll(dx: delta, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: time)
        }
        clock.advanceOne(controller, hz: hz)
        let step = controller.currentOffset - previous
        previous = controller.currentOffset
        replay.offsets.append(controller.currentOffset)
        replay.steps.append(step)
        replay.pendings.append(controller.directTouchPending)
        replay.rates.append(controller.directTouchRate)
    }

    if let releasePhase = releasePhase {
        controller.enqueueScroll(dx: 0, dy: 0, phase: releasePhase, momentumPhase: 0, flags: [], timestamp: clock.now)
        clock.advanceOne(controller, hz: hz)
    }
    return replay
}

@MainActor
func median(_ values: [CGFloat]) -> CGFloat {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

@MainActor
func percentile(_ values: [CGFloat], _ fraction: Double) -> CGFloat {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
    return sorted[index]
}

@MainActor
func directTouchMetrics(
    hz: Double,
    frames: Int,
    packets: (Int) -> [CGFloat],
    smoothness: Double = 0.75,
    timestampOffset: (Int, Int) -> Double = { _, _ in 0 }
) -> (frozen: Int, sampled: Int, p50: CGFloat, p95: CGFloat, maxStep: CGFloat, total: CGFloat, latencyMS: CGFloat, peakPending: CGFloat, rateSamples: Int) {
    let replay = replayDirectTouch(
        hz: hz,
        frames: frames,
        smoothness: smoothness,
        packets: packets,
        timestampOffset: timestampOffset
    )
    let steps = replay.steps.map { abs($0) }
    let sampled = max(0, steps.count - 1)
    let frozen = steps.dropFirst().filter { $0 < 0.001 }.count
    let total = replay.controller.currentOffset
    let meanPending = replay.pendings.map { abs($0) }.reduce(0, +) / CGFloat(max(1, replay.pendings.count))
    let nonzeroRates = replay.rates.map { abs($0) }.filter { $0 > 0.001 }
    let meanRate = nonzeroRates.isEmpty ? 0 : nonzeroRates.reduce(0, +) / CGFloat(nonzeroRates.count)
    let latency = meanRate > 0 ? (meanPending / meanRate) * 1000.0 : 0
    return (
        frozen,
        sampled,
        median(steps),
        percentile(steps, 0.95),
        steps.max() ?? 0,
        total,
        latency,
        replay.pendings.map { abs($0) }.max() ?? 0,
        nonzeroRates.count
    )
}


@MainActor
func run() {
    print("== Spring solver ==")

    // 1. Refresh-rate independence: the same wall-clock time must produce the same
    // position on every panel cadence.
    let target: CGFloat = 500
    let samples = [60.0, 80.0, 120.0, 240.0].map { hz in
        springPosition(target: target, seconds: 0.10, hz: hz)
    }
    let spread = (samples.max() ?? 0) - (samples.min() ?? 0)
    check(spread < 0.01, "spring position is refresh-rate independent (spread \(spread))")

    // 2. Pathological delta is clamped instead of integrating seconds at once.
    var stalled = SpringState(position: 0, velocity: 0, target: 100)
    stalled.step(dt: 10.0)
    check(stalled.position.isFinite && stalled.position <= 100.001, "spring clamps a 10 s stall")

    // 3. Critical damping never overshoots and never reverses.
    var critical = SpringState(position: 0, velocity: 0, target: 100)
    critical.dampingRatio = 1.0
    var previous = critical.position
    var criticalOK = true
    for _ in 0..<240 {
        critical.step(dt: 1.0 / 120.0)
        if critical.position > 100.000001 || critical.position < previous - 0.000001 {
            criticalOK = false
        }
        previous = critical.position
    }
    check(criticalOK, "critical damping never overshoots or reverses")
    check(critical.isAtRest, "critical damping reaches rest")

    // 4. Retarget preserves position and velocity at the instant of the change.
    var retargeted = SpringState(position: 0, velocity: 0, target: 500)
    for _ in 0..<6 { retargeted.step(dt: 1.0 / 120.0) }
    let beforePosition = retargeted.position
    let beforeVelocity = retargeted.velocity
    retargeted.retarget(-250)
    check(retargeted.position == beforePosition, "retarget preserves position")
    check(retargeted.velocity == beforeVelocity, "retarget preserves velocity")
    check(retargeted.target == -250, "retarget updates only the destination")

    // 5. Non-positive / non-finite deltas cannot advance physics.
    var frozen = SpringState(position: 10, velocity: 2, target: 100)
    frozen.step(dt: 0)
    frozen.step(dt: -1)
    frozen.step(dt: .nan)
    check(frozen.position == 10 && frozen.velocity == 2, "non-positive dt is a no-op")

    print("== ScrollController ==")

    // 6. The controller reaches the same place at 60/80/120/240 Hz after 100 ms.
    var controllerSamples: [CGFloat] = []
    for hz in [60.0, 80.0, 120.0, 240.0] {
        let controller = makeController()
        let clock = MotionClock()
        controller.scrollTo(target: 500, maxOffset: 5000)
        clock.prime(controller)
        clock.advance(controller, seconds: 0.10, hz: hz)
        controllerSamples.append(controller.currentOffset)
        check(controller.currentOffset > 0, "controller moves at \(Int(hz)) Hz")
    }
    let controllerSpread = (controllerSamples.max() ?? 0) - (controllerSamples.min() ?? 0)
    check(controllerSpread < 0.01, "controller is refresh-rate independent (spread \(controllerSpread))")

    // 7. A rapid keyboard retarget must not reset position or velocity.
    let rapid = makeController(maxOffset: 2000)
    let rapidClock = MotionClock()
    rapid.scrollTo(target: 800, maxOffset: 2000)
    rapidClock.prime(rapid)
    rapidClock.advance(rapid, seconds: 0.08, hz: 120)
    let positionAtRetarget = rapid.currentOffset
    let velocityAtRetarget = rapid.currentVelocity
    check(positionAtRetarget > 0, "rapid-retarget setup produced motion")

    rapid.scrollTo(target: 300, maxOffset: 2000)
    check(rapid.currentOffset == positionAtRetarget, "keyboard retarget does not jump position")
    checkClose(rapid.currentVelocity, velocityAtRetarget, tolerance: 0.0001, "keyboard retarget carries velocity")
    check(rapid.isSpringAnimating, "retarget stays in the spring phase")

    rapidClock.advanceOne(rapid, hz: 120)
    let firstRetargetStep = abs(rapid.currentOffset - positionAtRetarget)
    check(firstRetargetStep <= abs(velocityAtRetarget) / 120.0 + 5.0, "first retargeted frame is continuous")

    // 8. Long jump: no overshoot beyond the strip and exact rest at the endpoint.
    let jump = makeController(maxOffset: 3000)
    let jumpClock = MotionClock()
    jump.scrollTo(target: 3000, maxOffset: 3000)
    jumpClock.prime(jump)
    jumpClock.advance(jump, seconds: 2.0, hz: 120)
    checkClose(jump.currentOffset, 3000, tolerance: 0.001, "long jump settles exactly on target")
    check(jump.springState.isAtRest, "long jump reports rest")
    check(!jump.isMoving, "settled controller is not moving")

    // 9. Reversed movement mid-flight stays continuous.
    let reverse = makeController(maxOffset: 2000)
    let reverseClock = MotionClock()
    reverse.scrollTo(target: 1500, maxOffset: 2000)
    reverseClock.prime(reverse)
    reverseClock.advance(reverse, seconds: 0.08, hz: 120)
    let reverseStart = reverse.currentOffset
    let reverseVelocity = reverse.currentVelocity
    reverse.scrollTo(target: 100, maxOffset: 2000)
    check(reverse.currentOffset == reverseStart, "reversal does not jump position")
    checkClose(reverse.currentVelocity, reverseVelocity, tolerance: 0.0001, "reversal keeps momentum")
    reverseClock.advance(reverse, seconds: 1.5, hz: 120)
    checkClose(reverse.currentOffset, 100, tolerance: 0.001, "reversal settles at the new target")

    // 10. A stalled display tick is skipped, not integrated.
    let stall = makeController(maxOffset: 3000)
    let stallClock = MotionClock()
    stall.scrollTo(target: 3000, maxOffset: 3000)
    stallClock.prime(stall)
    stallClock.advance(stall, seconds: 0.05, hz: 120)
    let beforeStall = stall.currentOffset
    stallClock.jump(stall, seconds: 10.0)
    checkClose(stall.currentOffset, beforeStall, tolerance: 0.0001, "10 s stall does not teleport")
    stallClock.advanceOne(stall, hz: 120)
    check(abs(stall.currentOffset - beforeStall) < 300, "motion resumes with a bounded next frame")

    // 11. Lifting a finger flushes the last queued contact sample without a jump.
    let gesture = makeController(maxOffset: 5000)
    let gestureClock = MotionClock()
    SettingsStore.shared.snapToColumn = false
    gesture.applyInteractiveDelta(40, maxOffset: 5000, timestamp: gestureClock.now)
    gestureClock.advanceOne(gesture, hz: 120)
    let beforeLift = gesture.currentOffset
    let expectedLift = beforeLift + 15
    gesture.applyInteractiveDelta(15, maxOffset: 5000, timestamp: gestureClock.now)
    gesture.endInteractiveSwipe(maxOffset: 5000)
    checkClose(gesture.currentOffset, expectedLift, tolerance: 0.51, "lift flushes the pending delta")
    check(!gesture.isSwipingInteractively, "lift ends direct manipulation")

    // 12. Repeated gesture interruptions never create a position discontinuity.
    let interrupted = makeController(maxOffset: 2000)
    let interruptedClock = MotionClock()
    var maxFrameDelta: CGFloat = 0
    var previousOffset = interrupted.currentOffset
    interrupted.scrollTo(target: 600, maxOffset: 2000)
    interruptedClock.prime(interrupted)
    for index in 0..<40 {
        if index % 3 == 0 {
            interrupted.applyInteractiveDelta(index % 2 == 0 ? 24 : -24, maxOffset: 2000, timestamp: interruptedClock.now)
        } else {
            interrupted.scrollTo(
                target: CGFloat((index * 137) % 1800),
                maxOffset: 2000
            )
        }
        interruptedClock.advanceOne(interrupted, hz: 120)
        let delta = abs(interrupted.currentOffset - previousOffset)
        maxFrameDelta = max(maxFrameDelta, delta)
        previousOffset = interrupted.currentOffset
        check(interrupted.currentOffset.isFinite, "interrupted motion stays finite at step \(index)")
    }
    check(maxFrameDelta < 400, "interrupted motion has no teleport (max frame \(maxFrameDelta))")

    // 13. A shrinking strip is re-queried at rest and the offset is clamped.
    let shrinking = makeController(maxOffset: 2000)
    var queriedMax: CGFloat = 2000
    shrinking.onQueryMaxOffset = { queriedMax }
    var completed = 0
    shrinking.onAnimationCompleted = { completed += 1 }
    let shrinkClock = MotionClock()
    shrinking.scrollTo(target: 2000, maxOffset: 2000)
    shrinkClock.prime(shrinking)
    shrinkClock.advance(shrinking, seconds: 0.05, hz: 120)
    queriedMax = 700
    shrinkClock.advance(shrinking, seconds: 1.5, hz: 120)
    check(shrinking.currentOffset <= 700.001, "settle re-queries and clamps a shrinking strip")
    check(completed == 1, "settle completes exactly once")

    // 14. Momentum coast also skips a pathological gap.
    let coast = makeController(maxOffset: 5000)
    let coastClock = MotionClock()
    coast.enqueueScroll(dx: -40, dy: 0, phase: 1, momentumPhase: 0, flags: [])
    coastClock.prime(coast)
    coastClock.advance(coast, seconds: 0.01, hz: 120)
    coast.enqueueScroll(dx: -40, dy: 0, phase: 2, momentumPhase: 0, flags: [])
    coastClock.advance(coast, seconds: 0.01, hz: 120)
    coast.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [])
    coastClock.advance(coast, seconds: 0.02, hz: 120)
    let beforeCoastStall = coast.currentOffset
    coastClock.jump(coast, seconds: 5.0)
    checkClose(coast.currentOffset, beforeCoastStall, tolerance: 0.0001, "momentum stall does not teleport")

    // 15. A near-target scroll must not leave a stale destination behind.
    let near = makeController(maxOffset: 5000)
    near.scrollTo(target: 0.4, maxOffset: 5000)
    checkClose(near.currentOffset, 0.4, tolerance: 0.0001, "near-target scroll lands immediately")
    checkClose(near.smoothTargetOffset, 0.4, tolerance: 0.0001, "near-target scroll clears the destination")
    check(!near.isMoving, "near-target scroll is idle, not pinned to a stale target")

    // 16. A settle whose callback starts no spring must not pin the display link.
    let settleIdle = makeController(maxOffset: 5000)
    SettingsStore.shared.snapToColumn = true
    SettingsStore.shared.scrollSmoothness = 0.90
    SettingsStore.shared.trackpadNaturalScroll = false
    settleIdle.enqueueScroll(dx: 100, dy: 0, phase: 0, momentumPhase: 0, flags: [])
    let settleIdleClock = MotionClock()
    settleIdleClock.prime(settleIdle)
    settleIdleClock.advanceOne(settleIdle, hz: 120)
    check(abs(settleIdle.smoothTargetOffset - settleIdle.currentOffset) > 5, "settle setup has a lagging destination")
    settleIdle.settle()
    check(!settleIdle.isMoving, "a no-op settle callback leaves the controller idle")
    SettingsStore.shared.trackpadNaturalScroll = true
    SettingsStore.shared.snapToColumn = false

    // 17. A discrete wheel event takes ownership from a running spring.
    let wheelSpring = makeController(maxOffset: 2000)
    let wheelSpringClock = MotionClock()
    wheelSpring.scrollTo(target: 800, maxOffset: 2000)
    wheelSpringClock.prime(wheelSpring)
    wheelSpringClock.advance(wheelSpring, seconds: 0.08, hz: 120)
    wheelSpring.enqueueScroll(dx: -30, dy: 0, phase: 0, momentumPhase: 0, flags: [])
    check(!wheelSpring.isSpringAnimating, "wheel cancels an in-flight spring")
    check(wheelSpring.isActivelyScrolling, "wheel starts tracking mode")
    check(wheelSpring.currentVelocity == 0, "wheel takeover clears inherited spring velocity")
    let beforeWheelSpring = wheelSpring.currentOffset
    wheelSpringClock.advanceOne(wheelSpring, hz: 120)
    check(abs(wheelSpring.currentOffset - beforeWheelSpring) > 1, "wheel input moves after cancelling a spring")

    // 18. A discrete wheel event takes ownership from a momentum coast.
    let wheelCoast = makeController(maxOffset: 5000)
    SettingsStore.shared.trackpadNaturalScroll = false
    let wheelCoastClock = MotionClock()
    wheelCoast.enqueueScroll(dx: 40, dy: 0, phase: 1, momentumPhase: 0, flags: [])
    wheelCoastClock.prime(wheelCoast)
    wheelCoastClock.advanceOne(wheelCoast, hz: 120)
    wheelCoast.enqueueScroll(dx: 40, dy: 0, phase: 2, momentumPhase: 0, flags: [])
    wheelCoastClock.advanceOne(wheelCoast, hz: 120)
    wheelCoast.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [])
    wheelCoastClock.advanceOne(wheelCoast, hz: 120)
    check(wheelCoast.isMomentumCoasting, "coast setup produced momentum")
    wheelCoast.enqueueScroll(dx: 20, dy: 0, phase: 0, momentumPhase: 0, flags: [])
    check(!wheelCoast.isMomentumCoasting, "wheel cancels a momentum coast")
    check(wheelCoast.isActivelyScrolling, "wheel takes over coasting as tracking")
    SettingsStore.shared.trackpadNaturalScroll = true

    // 19. The lift event's final delta is rendered before the coast starts.
    let liftFlush = makeController(maxOffset: 5000)
    SettingsStore.shared.trackpadNaturalScroll = false
    let liftFlushClock = MotionClock()
    liftFlush.enqueueScroll(dx: 40, dy: 0, phase: 1, momentumPhase: 0, flags: [])
    liftFlushClock.prime(liftFlush)
    liftFlushClock.advanceOne(liftFlush, hz: 120)
    liftFlush.enqueueScroll(dx: 40, dy: 0, phase: 2, momentumPhase: 0, flags: [])
    liftFlushClock.advanceOne(liftFlush, hz: 120)
    let beforeLiftFlush = liftFlush.currentOffset
    liftFlush.enqueueScroll(dx: 12, dy: 0, phase: 4, momentumPhase: 0, flags: [])
    checkClose(liftFlush.currentOffset, beforeLiftFlush + 12, tolerance: 0.51, "lift event delta reaches the visible offset")
    SettingsStore.shared.trackpadNaturalScroll = true

    // 20. A direct swipe preserves its lift velocity for the settle spring.
    let flick = makeController(maxOffset: 5000)
    let flickClock = MotionClock()
    var capturedSettleVelocity: CGFloat = -1
    flick.onSettleRequested = { _ in capturedSettleVelocity = flick.settleVelocity }
    flick.applyInteractiveDelta(60, maxOffset: 5000, timestamp: flickClock.now)
    flickClock.advanceOne(flick, hz: 120)
    flick.applyInteractiveDelta(60, maxOffset: 5000, timestamp: flickClock.now)
    flickClock.advanceOne(flick, hz: 120)
    let liftVelocity = flick.currentVelocity
    flick.endInteractiveSwipe(maxOffset: 5000)
    check(liftVelocity > 1, "flick setup produced lift velocity")
    checkClose(capturedSettleVelocity, liftVelocity, tolerance: 0.0001, "swipe lift preserves velocity for settle")

    // MARK: - Direct-touch resampling (D04)

    print("== Direct-touch resampling (D04) ==")

    // The historical fixture: 60 display frames alternating 0 and 2 packets of
    // 8 pt at sensitivity 1.2. Raw 1:1 delivery therefore moves 19.2 pt on burst
    // frames and 0 on the others: 576 pt total, 29/59 frozen, median 19.2.
    let burstyPackets: (Int) -> [CGFloat] = { frame in frame % 2 == 1 ? [8, 8] : [] }
    let legacySteps = (0..<60).map { abs(burstyPackets($0).reduce(0, +) * 1.2) }
    let legacyFrozen = legacySteps.dropFirst().filter { $0 < 0.001 }.count
    check(legacyFrozen == 29, "fixture arithmetic matches the historical 29/59 frozen raw frames (got \(legacyFrozen))")
    checkClose(median(legacySteps), 19.2, tolerance: 0.0001, "fixture arithmetic matches the historical 19.2 pt raw median")
    checkClose(legacySteps.reduce(0, +), 576, tolerance: 0.0001, "fixture arithmetic matches the historical 576 pt total")

    var burstyTotals: [CGFloat] = []
    for hz in [60.0, 80.0, 120.0, 240.0] {
        let metrics = directTouchMetrics(hz: hz, frames: 60, packets: burstyPackets)
        burstyTotals.append(metrics.total)
        print(String(
            format: "BENCH direct_bursty hz=%3.0f frozen=%d/%d p50=%.2f p95=%.2f max=%.2f total=%.2f latency_ms=%.2f peak_pending=%.2f",
            hz, metrics.frozen, metrics.sampled, metrics.p50, metrics.p95, metrics.maxStep,
            metrics.total, metrics.latencyMS, metrics.peakPending
        ))
        check(metrics.frozen <= 3, "bursty \(Int(hz)) Hz frozen frames <= 3 (got \(metrics.frozen)/\(metrics.sampled))")
        check(metrics.maxStep <= 12.0, "bursty \(Int(hz)) Hz no movement spike above 12 pt (got \(metrics.maxStep))")
        checkClose(metrics.total, 576, tolerance: 0.5, "bursty \(Int(hz)) Hz preserves the 576 pt total")
        // Mean reservoir latency budget: the reservoir holds at most one input
        // interval; half a 60 Hz frame (8.33 ms) plus estimator tolerance is the ceiling.
        check(metrics.rateSamples > 0, "bursty \(Int(hz)) Hz latency has a measured drain rate")
        check(metrics.latencyMS <= 8.5, "bursty \(Int(hz)) Hz reservoir latency <= 8.5 ms (got \(metrics.latencyMS))")
    }

    // Smoothness must not touch the direct-touch trajectory.
    let smooth0 = replayDirectTouch(hz: 120, frames: 40, smoothness: 0.0, packets: burstyPackets).offsets
    let smooth05 = replayDirectTouch(hz: 120, frames: 40, smoothness: 0.5, packets: burstyPackets).offsets
    let smooth1 = replayDirectTouch(hz: 120, frames: 40, smoothness: 1.0, packets: burstyPackets).offsets
    check(smooth0 == smooth05 && smooth05 == smooth1, "smoothness 0/0.5/1 produce identical direct-touch offsets")

    // Constant 60 Hz input against 60/80/120/240 Hz display schedules: the input
    // rate differs from the render rate, so packets bunch unevenly across ticks.
    for hz in [60.0, 80.0, 120.0, 240.0] {
        let frames = Int((0.5 * hz).rounded())
        var packetFrames: [Int: [CGFloat]] = [:]
        for event in 0..<30 {
            let frame = min(frames - 1, Int(((Double(event) / 60.0) * hz).rounded()))
            packetFrames[frame, default: []].append(contentsOf: [8, 8])
        }
        let metrics = directTouchMetrics(hz: hz, frames: frames, packets: { packetFrames[$0] ?? [] })
        print(String(
            format: "BENCH direct_60hz_input hz=%3.0f frozen=%d/%d p50=%.2f p95=%.2f max=%.2f total=%.2f latency_ms=%.2f peak_pending=%.2f",
            hz, metrics.frozen, metrics.sampled, metrics.p50, metrics.p95, metrics.maxStep,
            metrics.total, metrics.latencyMS, metrics.peakPending
        ))
        check(metrics.frozen <= 3, "60 Hz input at \(Int(hz)) Hz display frozen frames <= 3 (got \(metrics.frozen)/\(metrics.sampled))")
        // At 60/80 Hz display one 60 Hz input packet is a legitimate single-frame
        // step of 19.2 pt; above that the window must spread each packet.
        let maxStepGate: CGFloat = hz <= 80.0 ? 20.5 : 12.0
        check(metrics.maxStep <= maxStepGate, "60 Hz input at \(Int(hz)) Hz display max step <= \(maxStepGate) pt (got \(metrics.maxStep))")
        check(metrics.rateSamples > 0, "60 Hz input at \(Int(hz)) Hz display latency has a measured drain rate")
        check(metrics.latencyMS <= 8.5, "60 Hz input at \(Int(hz)) Hz display latency <= 8.5 ms (got \(metrics.latencyMS))")
        checkClose(metrics.total, 576, tolerance: 0.5, "60 Hz input at \(Int(hz)) Hz display preserves 576 pt")
    }

    // Slow and fast uniform motion both stay 1:1.
    let slow = replayDirectTouch(hz: 60, frames: 90, packets: { _ in [2] })
    check(slow.steps.dropFirst().allSatisfy { abs(abs($0) - 2.4) < 0.01 }, "slow uniform motion is 1:1")
    checkClose(slow.controller.currentOffset, 90 * 2.4, tolerance: 0.5, "slow motion total is exact")
    let fast = replayDirectTouch(hz: 240, frames: 120, packets: { _ in [24] })
    check(fast.steps.dropFirst().allSatisfy { abs(abs($0) - 28.8) < 0.01 }, "fast uniform motion is 1:1")
    checkClose(fast.controller.currentOffset, 120 * 28.8, tolerance: 0.5, "fast motion total is exact")

    // Uniform input: exactly 1:1, no reservoir backlog, no freeze.
    let uniformReplay = replayDirectTouch(hz: 120, frames: 120, packets: { _ in [8] })
    let uniformSteps = uniformReplay.steps.dropFirst()
    check(uniformSteps.allSatisfy { abs(abs($0) - 9.6) < 0.01 }, "uniform direct touch is delivered 1:1")
    check(uniformSteps.allSatisfy { $0 > 0.001 }, "uniform direct touch never freezes")
    check(uniformReplay.pendings.allSatisfy { abs($0) < 0.01 }, "uniform input leaves no reservoir backlog")
    checkClose(uniformReplay.controller.currentOffset, 1152, tolerance: 0.5, "uniform total displacement is exact")

    // Multiple packets between display frames.
    let multiReplay = replayDirectTouch(hz: 80, frames: 60, packets: { _ in [8, 8, 8] })
    check(multiReplay.steps.dropFirst().allSatisfy { abs(abs($0) - 28.8) < 0.01 }, "three packets per frame are applied exactly once")
    checkClose(multiReplay.controller.currentOffset, 60 * 28.8, tolerance: 0.5, "multi-packet displacement is exact")

    // Tiny per-frame deltas must accumulate instead of being discarded by the
    // rest threshold.
    let tiny = replayDirectTouch(hz: 120, frames: 120, packets: { _ in [0.005] })
    check(tiny.steps.contains { abs($0) > 0.0001 }, "tiny deltas still move the strip")
    checkClose(tiny.controller.currentOffset, 120 * 0.005 * 1.2, tolerance: 0.01, "tiny deltas preserve their exact total")

    // A mid-gesture input gap must not create a catch-up spike or a NaN.
    let gapReplay = replayDirectTouch(hz: 120, frames: 120, packets: { frame in
        (frame < 40 || frame >= 80) ? [8] : []
    })
    check(gapReplay.steps.allSatisfy { $0.isFinite }, "a mid-gesture input gap stays finite")
    check(gapReplay.steps.allSatisfy { abs($0) <= 160.001 }, "a mid-gesture input gap has no teleport")
    let gapCatchUp = gapReplay.steps.map { abs($0) }.max() ?? 0
    check(gapCatchUp <= 15.0, "a mid-gesture input gap catches up in bounded steps (max \(gapCatchUp))")
    checkClose(gapReplay.controller.currentOffset, 80 * 9.6, tolerance: 0.5, "a mid-gesture input gap preserves displacement")
    print(String(
        format: "BENCH input_gap max_catchup=%.2f total=%.2f",
        gapCatchUp,
        gapReplay.controller.currentOffset
    ))

    // A finger pause longer than the epoch timeout must not turn the next packet
    // into a fresh gesture: a fresh epoch resets the target and clamps a live
    // rubber-band overscroll to the boundary in one frame.
    let pauseOverscroll = makeController(maxOffset: 100)
    SettingsStore.shared.scrollSensitivity = 1.0
    SettingsStore.shared.trackpadNaturalScroll = false
    SettingsStore.shared.momentumScrolling = false
    let pauseClock = MotionClock()
    pauseClock.prime(pauseOverscroll)
    pauseOverscroll.enqueueScroll(dx: 60, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: pauseClock.now)
    pauseClock.advanceOne(pauseOverscroll, hz: 120)
    pauseOverscroll.enqueueScroll(dx: 60, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: pauseClock.now)
    pauseClock.advanceOne(pauseOverscroll, hz: 120)
    let overscrolledAt = pauseOverscroll.currentOffset
    check(overscrolledAt > 100, "pause fixture is genuinely overscrolled (got \(overscrolledAt))")
    pauseClock.advance(pauseOverscroll, seconds: 0.2, hz: 120)
    checkClose(pauseOverscroll.currentOffset, overscrolledAt, tolerance: 0.5, "an input gap parks the accepted integral")
    check(!pauseOverscroll.isMoving, "an input gap leaves the controller parked and idle")
    let resumeBase = pauseOverscroll.currentOffset
    pauseOverscroll.enqueueScroll(dx: 5, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: pauseClock.now)
    pauseClock.advanceOne(pauseOverscroll, hz: 120)
    check(pauseOverscroll.currentOffset >= resumeBase - 0.001, "a resumed gesture never snaps a live overscroll backward")
    check(pauseOverscroll.currentOffset > 100, "a resumed gesture keeps the rubber-band overscroll")
    check(pauseOverscroll.currentOffset - resumeBase <= 10, "a resumed gesture moves by its own delta only")

    // A duplicate lift is one physical event. It must not cancel or restart a coast.
    let duplicateCoast = makeController(maxOffset: 5000)
    SettingsStore.shared.scrollSensitivity = 1.0
    SettingsStore.shared.trackpadNaturalScroll = false
    SettingsStore.shared.momentumScrolling = true
    let duplicateCoastClock = MotionClock()
    duplicateCoastClock.prime(duplicateCoast)
    duplicateCoast.enqueueScroll(dx: 40, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: duplicateCoastClock.now)
    duplicateCoastClock.advanceOne(duplicateCoast, hz: 120)
    duplicateCoast.enqueueScroll(dx: 40, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: duplicateCoastClock.now)
    duplicateCoastClock.advanceOne(duplicateCoast, hz: 120)
    duplicateCoast.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: duplicateCoastClock.now)
    check(duplicateCoast.isMomentumCoasting, "duplicate-lift fixture starts a coast")
    let coastVelocity = duplicateCoast.currentVelocity
    let coastOffset = duplicateCoast.currentOffset
    duplicateCoast.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: duplicateCoastClock.now)
    check(duplicateCoast.isMomentumCoasting, "a duplicate lift does not cancel the coast")
    checkClose(duplicateCoast.currentVelocity, coastVelocity, tolerance: 0.0001, "a duplicate lift preserves the coast velocity")
    duplicateCoastClock.advanceOne(duplicateCoast, hz: 120)
    check(duplicateCoast.currentOffset > coastOffset, "the original coast keeps moving after a duplicate lift")

    // A wheel event during a touch takes ownership: queued wheel input must drain
    // through the filter, never jump in one frame at the eventual lift.
    let wheelDuringTouch = makeController(maxOffset: 5000)
    SettingsStore.shared.scrollSensitivity = 1.0
    SettingsStore.shared.trackpadNaturalScroll = false
    SettingsStore.shared.momentumScrolling = false
    let wheelDuringTouchClock = MotionClock()
    wheelDuringTouchClock.prime(wheelDuringTouch)
    wheelDuringTouch.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: wheelDuringTouchClock.now)
    wheelDuringTouchClock.advanceOne(wheelDuringTouch, hz: 120)
    wheelDuringTouch.enqueueScroll(dx: 20, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: wheelDuringTouchClock.now)
    wheelDuringTouch.enqueueScroll(dx: 100, dy: 0, phase: 0, momentumPhase: 0, flags: [], timestamp: wheelDuringTouchClock.now)
    var wheelTouchMax: CGFloat = abs(wheelDuringTouch.currentOffset)
    var wheelTouchPrevious = wheelDuringTouch.currentOffset
    for _ in 0..<20 {
        wheelDuringTouchClock.advanceOne(wheelDuringTouch, hz: 120)
        wheelTouchMax = max(wheelTouchMax, abs(wheelDuringTouch.currentOffset - wheelTouchPrevious))
        wheelTouchPrevious = wheelDuringTouch.currentOffset
    }
    wheelDuringTouch.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: wheelDuringTouchClock.now)
    for _ in 0..<20 {
        wheelDuringTouchClock.advanceOne(wheelDuringTouch, hz: 120)
    }
    checkClose(wheelDuringTouch.currentOffset, 120, tolerance: 0.5, "a wheel during touch keeps both inputs' displacement")
    check(wheelTouchMax <= 60, "a wheel during touch never lands as one instantaneous jump (max \(wheelTouchMax))")

    // Cancelling a wheel gesture discards its queued delta; the next wheel gesture
    // starts from zero, not from the cancelled delta.
    let wheelCancel = makeController(maxOffset: 5000)
    SettingsStore.shared.scrollSensitivity = 1.0
    SettingsStore.shared.trackpadNaturalScroll = false
    SettingsStore.shared.momentumScrolling = false
    SettingsStore.shared.scrollSmoothness = 0.0
    let wheelCancelClock = MotionClock()
    wheelCancelClock.prime(wheelCancel)
    wheelCancel.enqueueScroll(dx: 50, dy: 0, phase: 0, momentumPhase: 0, flags: [], timestamp: wheelCancelClock.now)
    wheelCancel.enqueueScroll(dx: 0, dy: 0, phase: 8, momentumPhase: 0, flags: [], timestamp: wheelCancelClock.now)
    wheelCancel.enqueueScroll(dx: 5, dy: 0, phase: 0, momentumPhase: 0, flags: [], timestamp: wheelCancelClock.now)
    wheelCancelClock.advanceOne(wheelCancel, hz: 120)
    checkClose(wheelCancel.currentOffset, 5, tolerance: 0.001, "a cancelled wheel delta never reaches the next gesture")
    SettingsStore.shared.scrollSmoothness = 0.75

    // A single oversized packet is pathological; the release seam lands it exactly
    // once. Continuous drainage is capped at 160 pt, the seam is the documented
    // exception because dropping or deferring it would lose displacement or delay
    // the coast.
    let releaseSeam = makeController(maxOffset: 5000)
    SettingsStore.shared.scrollSensitivity = 1.2
    SettingsStore.shared.trackpadNaturalScroll = false
    SettingsStore.shared.momentumScrolling = false
    let releaseSeamClock = MotionClock()
    releaseSeamClock.prime(releaseSeam)
    releaseSeam.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: releaseSeamClock.now)
    releaseSeamClock.advanceOne(releaseSeam, hz: 120)
    releaseSeam.enqueueScroll(dx: 300, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: releaseSeamClock.now)
    let beforeSeam = releaseSeam.currentOffset
    releaseSeam.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: releaseSeamClock.now)
    let seamStep = releaseSeam.currentOffset - beforeSeam
    checkClose(releaseSeam.currentOffset, 360, tolerance: 0.01, "an immediate release lands the exact 360 pt integral")
    check(seamStep > 0, "the release seam lands the pending integral rather than dropping it")
    print(String(format: "BENCH release_seam step=%.2f total=%.2f", seamStep, releaseSeam.currentOffset))
    let afterSeam = releaseSeam.currentOffset
    releaseSeam.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: releaseSeamClock.now)
    checkClose(releaseSeam.currentOffset, afterSeam, tolerance: 0.0001, "a duplicate lift after the seam applies nothing")

    // Irregular packet timestamps must not change the delivered trajectory.
    let irregular = replayDirectTouch(hz: 120, frames: 60, packets: { _ in [8] }) { frame, index in
        -0.006 + (Double((frame * 7 + index * 3) % 5) * 0.001)
    }
    check(irregular.steps.dropFirst().allSatisfy { abs(abs($0) - 9.6) < 0.01 }, "irregular timestamps keep a stable trajectory")
    checkClose(irregular.controller.currentOffset, 576, tolerance: 0.5, "irregular timestamps preserve displacement")

    // Out-of-order packet timestamps within one frame must not reorder or lose
    // input: sample time only orders epochs, while the rate is tick-derived.
    let backwards = replayDirectTouch(hz: 120, frames: 60, packets: { _ in [8, 8] }) { _, index in
        index == 0 ? 0 : -0.004
    }
    check(backwards.steps.allSatisfy { $0.isFinite }, "backwards packet timestamps stay finite")
    check(backwards.steps.dropFirst().allSatisfy { abs(abs($0) - 19.2) < 0.01 }, "backwards packet timestamps keep the trajectory")
    checkClose(backwards.controller.currentOffset, 1152, tolerance: 0.5, "backwards packet timestamps preserve displacement")

    // Direction reversal: the sign flips on the first frame that sees reverse input.
    let reversal = replayDirectTouch(hz: 120, frames: 80, packets: { frame in
        if frame < 20 { return [6] }
        if frame < 40 { return [-6] }
        return []
    })
    check(reversal.steps[20] < 0, "reversal lands on the next frame (step \(reversal.steps[20]))")
    check(reversal.steps.firstIndex(where: { $0 < 0 }) == 20, "reversal response is exactly one frame")
    checkClose(reversal.controller.currentOffset, 0, tolerance: 0.5, "reversal keeps the endpoint exact")

    // Short and long gestures both conserve displacement.
    let short = replayDirectTouch(hz: 120, frames: 3, packets: { _ in [8] })
    checkClose(short.controller.currentOffset, 3 * 9.6, tolerance: 0.01, "a three-frame gesture preserves its total")
    checkClose(short.controller.directTouchPending, 0, tolerance: 0.0001, "a short gesture releases cleanly")
    let long = replayDirectTouch(hz: 120, frames: 600, packets: { _ in [8] })
    check(long.steps.dropFirst().allSatisfy { abs(abs($0) - 9.6) < 0.01 }, "a long uniform gesture stays 1:1")
    checkClose(long.controller.currentOffset, 600 * 9.6, tolerance: 0.5, "a long gesture preserves its total")
    checkClose(long.controller.directTouchPending, 0, tolerance: 0.0001, "a long gesture leaves no backlog")

    // Release with unrendered input: exactly once, no double apply.
    let releaseReplay = replayDirectTouch(hz: 120, frames: 80, packets: { frame in
        frame == 79 ? [8, 8] : (frame % 2 == 1 ? [8, 8] : [])
    })
    checkClose(
        releaseReplay.controller.currentOffset,
        768,
        tolerance: 0.01,
        "release lands the exact input integral"
    )
    checkClose(releaseReplay.controller.directTouchPending, 0, tolerance: 0.0001, "release leaves no pending input")
    checkClose(
        releaseReplay.controller.directTouchTotalApplied,
        releaseReplay.controller.directTouchTotalInput,
        tolerance: 0.0001,
        "release ledger: applied equals accepted input"
    )
    let offsetAfterRelease = releaseReplay.controller.currentOffset
    releaseReplay.controller.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: 1)
    checkClose(releaseReplay.controller.currentOffset, offsetAfterRelease, tolerance: 0.0001, "duplicate lift applies nothing")

    // Cancellation must not leak into the next gesture.
    let cancelled = makeController(maxOffset: 5000)
    SettingsStore.shared.scrollSensitivity = 1.2
    SettingsStore.shared.trackpadNaturalScroll = false
    SettingsStore.shared.momentumScrolling = false
    let cancelledClock = MotionClock()
    cancelledClock.prime(cancelled)
    cancelled.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: cancelledClock.now)
    cancelledClock.advanceOne(cancelled, hz: 120)
    cancelled.enqueueScroll(dx: 10, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: cancelledClock.now)
    cancelled.enqueueScroll(dx: 10, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: cancelledClock.now)
    let beforeCancel = cancelled.currentOffset
    cancelled.enqueueScroll(dx: 0, dy: 0, phase: 8, momentumPhase: 0, flags: [], timestamp: cancelledClock.now)
    check(!cancelled.isDirectTouchResampling, "cancel discards the direct-touch reservoir")
    cancelledClock.advanceOne(cancelled, hz: 120)
    checkClose(cancelled.currentOffset, beforeCancel, tolerance: 0.0001, "cancel does not apply unrendered input")
    cancelled.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: cancelledClock.now)
    cancelledClock.advanceOne(cancelled, hz: 120)
    cancelled.enqueueScroll(dx: 5, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: cancelledClock.now)
    cancelled.enqueueScroll(dx: 5, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: cancelledClock.now)
    cancelled.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: cancelledClock.now)
    checkClose(cancelled.currentOffset - beforeCancel, 12, tolerance: 0.01, "a new gesture applies only its own 12 pt")
    checkClose(cancelled.directTouchPending, 0, tolerance: 0.0001, "new gesture has no inherited backlog")

    // Keyboard retarget mid-gesture takes ownership without replaying touch input.
    let takeover = makeController(maxOffset: 5000)
    SettingsStore.shared.scrollSensitivity = 1.2
    SettingsStore.shared.trackpadNaturalScroll = false
    let takeoverClock = MotionClock()
    takeoverClock.prime(takeover)
    takeover.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: takeoverClock.now)
    takeoverClock.advanceOne(takeover, hz: 120)
    takeover.enqueueScroll(dx: 10, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: takeoverClock.now)
    takeover.enqueueScroll(dx: 10, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: takeoverClock.now)
    let beforeTakeover = takeover.currentOffset
    takeover.scrollTo(target: beforeTakeover + 200, maxOffset: 5000)
    check(!takeover.isDirectTouchResampling, "keyboard retarget clears the touch reservoir")
    checkClose(takeover.directTouchPending, 0, tolerance: 0.0001, "keyboard retarget leaves no touch backlog")
    check(takeover.isSpringAnimating, "keyboard retarget owns the spring")
    takeoverClock.advanceOne(takeover, hz: 120)
    check(takeover.currentOffset > beforeTakeover, "spring continues after the takeover")

    // Duplicate display timestamp consumes nothing.
    let duplicate = makeController(maxOffset: 5000)
    SettingsStore.shared.scrollSensitivity = 1.2
    SettingsStore.shared.trackpadNaturalScroll = false
    let duplicateClock = MotionClock()
    duplicateClock.prime(duplicate)
    duplicate.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: duplicateClock.now)
    duplicateClock.advanceOne(duplicate, hz: 120)
    duplicate.enqueueScroll(dx: 8, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: duplicateClock.now)
    duplicate.enqueueScroll(dx: 8, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: duplicateClock.now)
    duplicateClock.advanceOne(duplicate, hz: 120)
    let offsetAfterFirstTick = duplicate.currentOffset
    let pendingAfterFirstTick = duplicate.directTouchPending
    duplicate.displayLinkFired(timestamp: duplicateClock.now)
    checkClose(duplicate.currentOffset, offsetAfterFirstTick, tolerance: 0.0001, "duplicate timestamp does not advance the offset")
    checkClose(duplicate.directTouchPending, pendingAfterFirstTick, tolerance: 0.0001, "duplicate timestamp does not drain the reservoir")

    // Pathological single-event jump is bounded, then drains without losing input.
    let spike = makeController(maxOffset: 5000)
    SettingsStore.shared.scrollSensitivity = 1.2
    SettingsStore.shared.trackpadNaturalScroll = false
    SettingsStore.shared.momentumScrolling = false
    let spikeClock = MotionClock()
    spikeClock.prime(spike)
    spike.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: spikeClock.now)
    spikeClock.advanceOne(spike, hz: 120)
    spike.enqueueScroll(dx: 300, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: spikeClock.now)
    var spikeMax: CGFloat = 0
    var spikePrevious = spike.currentOffset
    for _ in 0..<10 {
        spikeClock.advanceOne(spike, hz: 120)
        spikeMax = max(spikeMax, abs(spike.currentOffset - spikePrevious))
        spikePrevious = spike.currentOffset
    }
    spike.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: spikeClock.now)
    check(spikeMax <= 160.001, "a 300 pt event is delivered in bounded steps (max \(spikeMax))")
    checkClose(spike.currentOffset, 360, tolerance: 0.5, "the bounded catch-up still delivers all 360 pt")
    print(String(format: "BENCH single_event_360pt max_step=%.2f total=%.2f", spikeMax, spike.currentOffset))

    // MARK: - Gesture ownership (D06)

    print("== Gesture ownership (D06) ==")

    // The opt-in flag must be off with no defaults key. Use the harness defaults
    // domain, not the app domain; restore whatever was there afterwards.
    let handbackKey = "iume.diagonalHandback"
    let savedHandback = UserDefaults.standard.object(forKey: handbackKey)
    UserDefaults.standard.removeObject(forKey: handbackKey)
    let defaultsOff = ScrollController()
    check(!defaultsOff.diagonalHandbackEnabled, "diagonal hand-back defaults to off with no override")
    UserDefaults.standard.set(true, forKey: handbackKey)
    let defaultsOn = ScrollController()
    check(defaultsOn.diagonalHandbackEnabled, "the diagonal hand-back override is read from defaults")
    if let savedHandback {
        UserDefaults.standard.set(savedHandback, forKey: handbackKey)
    } else {
        UserDefaults.standard.removeObject(forKey: handbackKey)
    }

    let handbackOff = makeController(maxOffset: 5000)
    handbackOff.diagonalHandbackEnabled = false
    _ = handbackOff.shouldInterceptScroll(dx: 5, dy: 0, flags: [], phase: 1)
    _ = handbackOff.shouldInterceptScroll(dx: 5, dy: 0, flags: [], phase: 2)
    var flagOffStaysOwned = true
    for _ in 0..<3 {
        flagOffStaysOwned = handbackOff.shouldInterceptScroll(dx: 1, dy: 10, flags: [], phase: 2) && flagOffStaysOwned
    }
    check(flagOffStaysOwned, "hand-back flag off keeps the current ownership behavior")
    check(handbackOff.gestureOwner == .strip, "hand-back flag off stays latched to the strip")

    let handbackOn = makeController(maxOffset: 5000)
    handbackOn.diagonalHandbackEnabled = true
    var handbackSettles = 0
    handbackOn.onSettleRequested = { _ in handbackSettles += 1 }
    let generationBeforeHandback = handbackOn.currentGestureGeneration
    _ = handbackOn.shouldInterceptScroll(dx: 5, dy: 0, flags: [], phase: 1)
    _ = handbackOn.shouldInterceptScroll(dx: 5, dy: 0, flags: [], phase: 2)
    _ = handbackOn.shouldInterceptScroll(dx: 1, dy: 10, flags: [], phase: 2)
    let delivered = handbackOn.shouldInterceptScroll(dx: 1, dy: 10, flags: [], phase: 2)
    check(!delivered, "the decisive vertical event is delivered, not consumed")
    check(handbackOn.gestureOwner == .app, "ownership hands back to the app")
    check(!handbackOn.shouldInterceptScroll(dx: 10, dy: 0, flags: [], phase: 2), "hand-back is one-way for this gesture")
    check(handbackOn.currentGestureGeneration > generationBeforeHandback, "hand-back invalidates deferred callbacks")
    checkClose(handbackOn.currentOffset, handbackOn.smoothTargetOffset, tolerance: 0.0001, "hand-back parks the strip on its horizontal trajectory")
    check(!handbackOn.isMoving, "hand-back leaves the strip idle")
    handbackOn.handleFreezeWatchdogTimer(generation: generationBeforeHandback)
    check(handbackSettles == 0, "a stale watchdog cannot settle after hand-back")

    let diagonal = makeController(maxOffset: 5000)
    diagonal.diagonalHandbackEnabled = true
    _ = diagonal.shouldInterceptScroll(dx: 5, dy: 0, flags: [], phase: 1)
    var diagonalOwned = true
    for _ in 0..<6 {
        diagonalOwned = diagonal.shouldInterceptScroll(dx: 5, dy: 3, flags: [], phase: 2) && diagonalOwned
    }
    check(diagonalOwned && diagonal.gestureOwner == .strip, "a shallow diagonal never hands back")

    print("== D01 geometry shrink / completion clamps ==")

    // 18. Max offset shrinks while a spring is in flight: the spring must land on
    // the new limit instead of completing at a stale destination.
    let shrinkSpring = makeController(maxOffset: 6000)
    let shrinkClock2 = MotionClock()
    shrinkSpring.scrollTo(target: 5000, maxOffset: 6000)
    shrinkClock2.prime(shrinkSpring)
    shrinkClock2.advance(shrinkSpring, seconds: 0.05, hz: 120)
    check(shrinkSpring.isSpringAnimating, "shrink setup has a spring in flight")
    shrinkSpring.maxOffset = 1400
    shrinkClock2.advance(shrinkSpring, seconds: 3.0, hz: 120)
    checkClose(shrinkSpring.currentOffset, 1400, tolerance: 0.5, "D01 spring lands on the shrunken limit")
    check(!shrinkSpring.isMoving, "D01 shrunken spring terminates")

    // 19. A deferred max-offset query that returns a smaller strip must retarget
    // the finishing spring rather than leave the old destination.
    let queryShrink = makeController(maxOffset: 6000)
    var queriedMax2: CGFloat = 6000
    queryShrink.onQueryMaxOffset = { queriedMax2 }
    let queryClock = MotionClock()
    queryShrink.scrollTo(target: 5000, maxOffset: 6000)
    queryClock.prime(queryShrink)
    queryClock.advance(queryShrink, seconds: 0.05, hz: 120)
    queriedMax2 = 1200
    queryClock.advance(queryShrink, seconds: 3.0, hz: 120)
    checkClose(queryShrink.currentOffset, 1200, tolerance: 0.5, "D01 deferred query lands on the new limit")
    checkClose(queryShrink.maxOffset, 1200, tolerance: 0.001, "D01 deferred query adopts the new limit")
    check(!queryShrink.isMoving, "D01 deferred query terminates")

    // 20. A freeze release after a geometry shrink is clamped before callbacks.
    let freezeClamp = makeController(maxOffset: 5000)
    SettingsStore.shared.freezeOnRelease = true
    freezeClamp.setOffset(1800, maxOffset: 5000)
    freezeClamp.maxOffset = 1200
    var freezeSettleOffsets: [CGFloat] = []
    freezeClamp.onSettleRequested = { freezeSettleOffsets.append($0) }
    freezeClamp.settle()
    checkClose(freezeClamp.currentOffset, 1200, tolerance: 0.001, "D01 freeze settle clamps the resting offset")
    check(freezeSettleOffsets == [1200], "D01 freeze settle reports the clamped offset")
    check(!freezeClamp.isMoving, "D01 freeze settle is idle")
    checkClose(freezeClamp.settleVelocity, 0, tolerance: 0.0001, "D01 freeze settle clears settle velocity")
    SettingsStore.shared.freezeOnRelease = false

    // 21. Cancelling after a shrink cannot park the controller outside the range.
    let cancelClamp = makeController(maxOffset: 5000)
    cancelClamp.setOffset(1800, maxOffset: 5000)
    cancelClamp.maxOffset = 1200
    cancelClamp.cancelAnimation()
    checkClose(cancelClamp.currentOffset, 1200, tolerance: 0.001, "D01 cancel clamps the parked offset")
    check(!cancelClamp.isMoving, "D01 cancel leaves the controller idle")

    print("== D02 settle termination ==")

    // 22. Freeze-on-release preserves the exact released offset and stops.
    let freezeRelease = makeController(maxOffset: 5000)
    SettingsStore.shared.freezeOnRelease = true
    let freezeClock = MotionClock()
    freezeRelease.applyInteractiveDelta(120, maxOffset: 5000, timestamp: freezeClock.now)
    freezeClock.advanceOne(freezeRelease, hz: 120)
    freezeRelease.endInteractiveSwipe(maxOffset: 5000)
    let frozenAt = freezeRelease.currentOffset
    check(!freezeRelease.isSwipingInteractively, "D02 freeze release leaves interactive phase")
    check(!freezeRelease.isMoving, "D02 freeze release is idle")
    checkClose(freezeRelease.settleVelocity, 0, tolerance: 0.0001, "D02 freeze release clears settle velocity")
    freezeClock.advance(freezeRelease, seconds: 0.3, hz: 120)
    checkClose(freezeRelease.currentOffset, frozenAt, tolerance: 0.0001, "D02 freeze release preserves the released offset")
    SettingsStore.shared.freezeOnRelease = false

    // 23. A lift whose settle callbacks do not take ownership must not leave the
    // spring velocity that keeps `isMoving` true forever.
    let unclaimed = makeController(maxOffset: 5000)
    let unclaimedClock = MotionClock()
    unclaimed.applyInteractiveDelta(80, maxOffset: 5000, timestamp: unclaimedClock.now)
    unclaimedClock.advanceOne(unclaimed, hz: 120)
    unclaimed.endInteractiveSwipe(maxOffset: 5000)
    checkClose(unclaimed.settleVelocity, 0, tolerance: 0.0001, "D02 unclaimed lift clears settle velocity")
    checkClose(unclaimed.currentVelocity, 0, tolerance: 0.0001, "D02 unclaimed lift clears current velocity")
    check(unclaimed.springState.isAtRest, "D02 unclaimed lift parks the spring at rest")
    check(!unclaimed.isMoving, "D02 unclaimed lift leaves the controller idle")
    let unclaimedAt = unclaimed.currentOffset
    unclaimedClock.advance(unclaimed, seconds: 0.3, hz: 120)
    checkClose(unclaimed.currentOffset, unclaimedAt, tolerance: 0.0001, "D02 unclaimed lift does not keep drifting")

    // 24. Snap-disabled settle zeroes all residual velocity immediately.
    SettingsStore.shared.snapToColumn = false
    let quietSettle = makeController(maxOffset: 5000)
    quietSettle.setOffset(600, maxOffset: 5000)
    quietSettle.settle()
    checkClose(quietSettle.currentOffset, 600, tolerance: 0.001, "D02 snap-disabled settle preserves the offset")
    checkClose(quietSettle.currentVelocity, 0, tolerance: 0.0001, "D02 snap-disabled settle clears current velocity")
    checkClose(quietSettle.settleVelocity, 0, tolerance: 0.0001, "D02 snap-disabled settle clears settle velocity")
    check(!quietSettle.isMoving, "D02 snap-disabled settle is idle")

    print("== D09 deferred-callback safety ==")

    // 25. A stale freeze watchdog from before a cancel must be inert. Snap is
    // enabled after construction so a stale settle would actually be observable.
    let staleWatchdog = makeController(maxOffset: 5000)
    SettingsStore.shared.snapToColumn = true
    staleWatchdog.setOffset(300, maxOffset: 5000)
    var watchdogSettles = 0
    staleWatchdog.onSettleRequested = { _ in watchdogSettles += 1 }
    staleWatchdog.enqueueScroll(dx: 0, dy: 0, phase: 0, momentumPhase: 0, flags: [])
    let staleGeneration = staleWatchdog.currentGestureGeneration
    staleWatchdog.cancelAnimation()
    staleWatchdog.handleFreezeWatchdogTimer(generation: staleGeneration)
    check(watchdogSettles == 0, "D09 stale freeze watchdog does not settle")

    // 26. A fresh freeze watchdog is phase-guarded: a tracking gesture suppresses it.
    let phaseGuard = makeController(maxOffset: 5000)
    phaseGuard.setOffset(300, maxOffset: 5000)
    var phaseGuardSettles = 0
    phaseGuard.onSettleRequested = { _ in phaseGuardSettles += 1 }
    phaseGuard.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [])
    phaseGuard.handleFreezeWatchdogTimer(generation: phaseGuard.currentGestureGeneration)
    check(phaseGuardSettles == 0, "D09 watchdog is inert while a gesture is tracking")
    check(phaseGuard.isActivelyScrolling, "D09 watchdog does not end the new gesture")

    // 27. A stale wheel settle from before a cancel must not settle the new state.
    let staleWheel = makeController(maxOffset: 5000)
    staleWheel.setOffset(300, maxOffset: 5000)
    var staleWheelSettles = 0
    staleWheel.onSettleRequested = { _ in staleWheelSettles += 1 }
    staleWheel.enqueueScroll(dx: 40, dy: 0, phase: 1, momentumPhase: 0, flags: [])
    let wheelGeneration = staleWheel.currentGestureGeneration
    staleWheel.cancelAnimation()
    staleWheel.handleWheelSettleTimer(generation: wheelGeneration)
    check(staleWheelSettles == 0, "D09 stale wheel settle does not fire")
    check(!staleWheel.isMoving, "D09 stale wheel settle does not revive motion")

    // 28. Retargeting a spring must discard the old destination and complete once.
    SettingsStore.shared.snapToColumn = false
    let retarget = makeController(maxOffset: 5000)
    var completions = 0
    retarget.onAnimationCompleted = { completions += 1 }
    let retargetClock = MotionClock()
    retarget.scrollTo(target: 4000, maxOffset: 5000)
    retargetClock.prime(retarget)
    retargetClock.advance(retarget, seconds: 0.08, hz: 120)
    retarget.scrollTo(target: 900, maxOffset: 5000)
    retargetClock.advance(retarget, seconds: 3.0, hz: 120)
    checkClose(retarget.currentOffset, 900, tolerance: 1.0, "D09 retarget lands on the new destination")
    check(!retarget.isMoving, "D09 retarget completes cleanly")
    check(completions == 1, "D09 retarget completes exactly once (got \(completions))")

    // 29. A new gesture during a settle takes ownership; the old spring never resumes.
    let regrab = makeController(maxOffset: 5000)
    let regrabClock = MotionClock()
    regrab.scrollTo(target: 4000, maxOffset: 5000)
    regrabClock.prime(regrab)
    regrabClock.advance(regrab, seconds: 0.05, hz: 120)
    check(regrab.isSpringAnimating, "D09 regrab setup has a spring in flight")
    regrab.applyInteractiveDelta(-50, maxOffset: 5000, timestamp: regrabClock.now)
    regrabClock.advanceOne(regrab, hz: 120)
    check(regrab.isSwipingInteractively, "D09 new gesture owns the motion")
    regrab.endInteractiveSwipe(maxOffset: 5000)
    let regrabRest = regrab.currentOffset
    check(!regrab.isMoving, "D09 regrab settle terminates")
    check(regrabRest < 4000, "D09 regrab is not captured by the old spring target")
    regrabClock.advance(regrab, seconds: 0.4, hz: 120)
    checkClose(regrab.currentOffset, regrabRest, tolerance: 0.0001, "D09 old spring does not resume after the new gesture")

    // == Legacy contract compatibility =====================================
    // These mirror the at-risk tests in `WorkspaceAndStateTests.swift`. They are
    // not replacements: they prove the Phase 2 edits preserved the documented
    // contracts while the full Swift Testing target cannot build here.
    print("== Legacy contract compatibility ==")

    // testIsMovingStates
    SettingsStore.shared.snapToColumn = false
    SettingsStore.shared.freezeOnRelease = false
    SettingsStore.shared.trackpadNaturalScroll = true
    SettingsStore.shared.scrollSensitivity = 1.0
    SettingsStore.shared.momentumScrolling = true
    let movingStates = makeController(maxOffset: 1000)
    movingStates.setOffset(100, maxOffset: 1000)
    check(!movingStates.isMoving, "legacy isMoving: parked controller is idle")
    movingStates.scrollTo(target: 500, maxOffset: 1000)
    check(movingStates.isMoving, "legacy isMoving: scrollTo starts motion")
    let movingClock = MotionClock()
    movingClock.prime(movingStates)
    movingClock.advance(movingStates, seconds: 2.0, hz: 120)
    check(!movingStates.isMoving, "legacy isMoving: spring reaches rest")
    check(movingStates.currentOffset == 500, "legacy isMoving: exact final offset")

    // testAnimationCompletedCallback
    let completion = makeController(maxOffset: 1000)
    completion.setOffset(0, maxOffset: 1000)
    var legacyCompleted = false
    completion.onAnimationCompleted = { legacyCompleted = true }
    completion.scrollTo(target: 250, maxOffset: 1000, duration: 0.15)
    check(!legacyCompleted, "legacy completion: not fired synchronously")
    let completionClock = MotionClock()
    completionClock.prime(completion)
    completionClock.advance(completion, seconds: 2.0, hz: 120)
    check(legacyCompleted, "legacy completion: fires on settle")
    check(completion.currentOffset == 250, "legacy completion: exact final offset")
    check(!completion.isMoving, "legacy completion: controller idle")

    // testMomentumDecoupling
    let decoupling = makeController(maxOffset: 2000)
    SettingsStore.shared.snapToColumn = true
    decoupling.setOffset(0, maxOffset: 2000)
    var legacySettleRequested = false
    decoupling.onSettleRequested = { _ in legacySettleRequested = true }
    let decouplingClock = MotionClock()
    decoupling.enqueueScroll(dx: -80, dy: 0, phase: 2, momentumPhase: 0, flags: [])
    decouplingClock.advanceOne(decoupling, hz: 120)
    check(abs(decoupling.currentVelocity) > 60, "legacy momentum: fast gesture builds velocity")
    decoupling.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [])
    decouplingClock.advanceOne(decoupling, hz: 120)
    check(!legacySettleRequested, "legacy momentum: lift does not settle before momentum")
    decoupling.enqueueScroll(dx: -10, dy: 0, phase: 0, momentumPhase: 1, flags: [])
    decouplingClock.advanceOne(decoupling, hz: 120)
    check(!legacySettleRequested, "legacy momentum: momentum stream does not settle")
    decoupling.enqueueScroll(dx: 0, dy: 0, phase: 0, momentumPhase: 4, flags: [])
    decouplingClock.advanceOne(decoupling, hz: 120)
    check(legacySettleRequested, "legacy momentum: momentum end requests settle")

    // testVelocityContinuityAcrossSettle
    SettingsStore.shared.snapToColumn = true
    let continuity = makeController(maxOffset: 3000)
    SettingsStore.shared.snapToColumn = true
    continuity.setOffset(0, maxOffset: 3000)
    let continuityClock = MotionClock()
    continuity.enqueueScroll(dx: -120, dy: 0, phase: 2, momentumPhase: 0, flags: [])
    continuityClock.advanceOne(continuity, hz: 120)
    let priorVelocity = continuity.currentVelocity
    check(abs(priorVelocity) > 50, "legacy continuity: gesture builds velocity")
    continuity.settle()
    check(continuity.settleVelocity == priorVelocity, "legacy continuity: settle preserves the handoff")
    continuity.scrollTo(target: 800, maxOffset: 3000, duration: 0.20)
    check(continuity.springState.velocity != 0, "legacy continuity: scrollTo consumes the handoff")
    check(continuity.settleVelocity == 0, "legacy continuity: handoff is consumed exactly once")

    // testDirectManipulationZeroInputLag
    SettingsStore.shared.snapToColumn = false
    let direct = makeController(maxOffset: 2000)
    direct.setOffset(0, maxOffset: 2000)
    let directClock = MotionClock()
    direct.enqueueScroll(dx: -40, dy: 0, phase: 2, momentumPhase: 0, flags: [])
    directClock.advanceOne(direct, hz: 120)
    check(direct.currentOffset == direct.smoothTargetOffset, "legacy direct: touch has zero lag")
    check(direct.currentOffset > 0, "legacy direct: touch moves the strip")
    direct.enqueueScroll(dx: -30, dy: 0, phase: 0, momentumPhase: 2, flags: [])
    directClock.advanceOne(direct, hz: 120)
    check(direct.currentOffset == direct.smoothTargetOffset, "legacy direct: native momentum has zero lag")

    // Restore the shared settings other suites expect.
    SettingsStore.shared.scrollSensitivity = 1.0
    SettingsStore.shared.trackpadNaturalScroll = true
    SettingsStore.shared.momentumScrolling = true

    // Run the adversarial stress suite as part of the production harness so its
    // checks contribute to the aggregate pass/fail result (previously it was
    // compiled but never invoked).
    runAdversarialStressTests()

    print("")
    if failures == 0 {
        print("PASS: \(checks) checks")
    } else {
        print("FAILED: \(failures) of \(checks) checks")
        exit(1)
    }
}

run()
