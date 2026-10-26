import Foundation
import CoreGraphics
import QuartzCore

@MainActor
func runAdversarialStressTests() {
    print("\n==========================================")
    print("=== STARTING ADVERSARIAL STRESS SUITE ===")
    print("==========================================")

    // -------------------------------------------------------------------------
    // TEST 1: Displacement Ledger Invariant Fuzzing
    // Invariant: totalApplied + pending == totalInput (within float epsilon)
    // -------------------------------------------------------------------------
    print("\n[Test 1] Fuzzing Displacement Ledger Invariant (10,000 steps)...")
    do {
        let controller = makeController(maxOffset: 1_000_000)
        SettingsStore.shared.scrollSensitivity = 1.2
        SettingsStore.shared.trackpadNaturalScroll = false
        SettingsStore.shared.momentumScrolling = false
        let clock = MotionClock()
        clock.prime(controller)

        controller.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: clock.now)
        clock.advanceOne(controller, hz: 120)

        var ledgerViolations = 0
        var maxDiscrepancy: CGFloat = 0.0

        for step in 0..<10_000 {
            // Pseudo-random delta with diverse regimes:
            // 0: zero
            // 1: sub-epsilon (0.0001 .. 0.009)
            // 2: normal (1.0 .. 25.0)
            // 3: large (50.0 .. 500.0)
            // 4: extreme reversals
            let mode = step % 5
            let sign: CGFloat = (step % 3 == 0) ? -1.0 : 1.0
            let rawVal: CGFloat
            switch mode {
            case 0: rawVal = 0.0
            case 1: rawVal = CGFloat((step % 90) + 1) * 0.0001
            case 2: rawVal = CGFloat((step % 25) + 1)
            case 3: rawVal = CGFloat((step % 450) + 50)
            case 4: rawVal = CGFloat((step % 100) + 10) * -sign
            default: rawVal = 5.0
            }
            let delta = rawVal * sign

            if delta != 0 {
                controller.enqueueScroll(dx: delta, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: clock.now)
            }

            // Check invariant immediately after enqueue
            let expectedInput1 = controller.directTouchTotalInput
            let applied1 = controller.directTouchTotalApplied
            let pending1 = controller.directTouchPending
            let diff1 = abs((applied1 + pending1) - expectedInput1)
            maxDiscrepancy = max(maxDiscrepancy, diff1)
            if diff1 > 1e-4 {
                ledgerViolations += 1
            }

            // Display link tick (variable dt / cadence)
            let hz = [60.0, 80.0, 120.0, 240.0][step % 4]
            clock.advanceOne(controller, hz: hz)

            // Check invariant after display tick
            let expectedInput2 = controller.directTouchTotalInput
            let applied2 = controller.directTouchTotalApplied
            let pending2 = controller.directTouchPending
            let diff2 = abs((applied2 + pending2) - expectedInput2)
            maxDiscrepancy = max(maxDiscrepancy, diff2)
            if diff2 > 1e-4 {
                ledgerViolations += 1
            }
        }

        // Lift fingers and verify final flush
        controller.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: clock.now)
        let finalApplied = controller.directTouchTotalApplied
        let finalInput = controller.directTouchTotalInput
        let finalPending = controller.directTouchPending
        let finalDiff = abs((finalApplied + finalPending) - finalInput)

        print("  Displacement Ledger: 10,000 steps completed.")
        print("  Max invariant discrepancy: \(maxDiscrepancy)")
        print("  Final: applied=\(finalApplied), input=\(finalInput), pending=\(finalPending), diff=\(finalDiff)")
        check(ledgerViolations == 0, "Ledger invariant held across all 10,000 random steps (violations: \(ledgerViolations))")
        check(finalPending == 0, "Final pending after lift is exactly zero (got \(finalPending))")
        checkClose(finalApplied, finalInput, tolerance: 1e-4, "Final applied equals final input")
    }

    // -------------------------------------------------------------------------
    // TEST 2: Rapid Direction Reversals Stress
    // -------------------------------------------------------------------------
    print("\n[Test 2] Rapid Direction Reversals Stress...")
    do {
        let controller = makeController(maxOffset: 100_000)
        SettingsStore.shared.scrollSensitivity = 1.0
        SettingsStore.shared.trackpadNaturalScroll = false
        SettingsStore.shared.momentumScrolling = false
        let clock = MotionClock()
        clock.prime(controller)

        controller.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: clock.now)
        clock.advanceOne(controller, hz: 120)

        // Alternate +100 and -100 every single frame for 20 frames
        var firstReversalStep: CGFloat = 0
        for f in 0..<20 {
            let delta: CGFloat = (f % 2 == 0) ? 100.0 : -100.0
            controller.enqueueScroll(dx: delta, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: clock.now)
            let prev = controller.currentOffset
            clock.advanceOne(controller, hz: 120)
            let step = controller.currentOffset - prev
            if f == 1 { firstReversalStep = step }
            check(step.isFinite, "Step is finite during rapid reversals")
            check(abs(step) <= 160.001, "Step never teleports beyond maxStep: \(step)")
        }
        check(firstReversalStep < 0, "First reversal step was negative on frame 1: \(firstReversalStep)")

        // Extreme reversal: build high velocity forward (+500/s) then smash -2000
        for _ in 0..<10 {
            controller.enqueueScroll(dx: 50, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: clock.now)
            clock.advanceOne(controller, hz: 120)
        }
        check(controller.directTouchRate > 0, "Rate is positive before smash")
        let offsetBeforeSmash = controller.currentOffset
        controller.enqueueScroll(dx: -2000, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: clock.now)
        clock.advanceOne(controller, hz: 120)
        let smashStep = controller.currentOffset - offsetBeforeSmash
        check(smashStep < 0, "Smash reversal immediately stepped negative: \(smashStep)")
        check(abs(smashStep) <= 160.001, "Smash reversal bounded by maxStep 160: got \(abs(smashStep))")

        // Drain remainder
        for _ in 0..<30 {
            clock.advanceOne(controller, hz: 120)
        }
        controller.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: clock.now)
        checkClose(controller.directTouchTotalApplied, controller.directTouchTotalInput, tolerance: 0.001, "Reversal total matches input")
        print("  Rapid direction reversals verified.")
    }

    // -------------------------------------------------------------------------
    // TEST 3: Duplicate Lift / Phase 4 Events
    // -------------------------------------------------------------------------
    print("\n[Test 3] Duplicate Lift / Phase 4 Events...")
    do {
        // Sub-test 3A: Consecutive phase 4 with effectiveDelta == 0 during coast
        let c1 = makeController(maxOffset: 5000)
        SettingsStore.shared.scrollSensitivity = 1.0
        SettingsStore.shared.trackpadNaturalScroll = false
        SettingsStore.shared.momentumScrolling = true
        let clk1 = MotionClock()
        clk1.prime(c1)

        c1.enqueueScroll(dx: 50, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: clk1.now)
        clk1.advanceOne(c1, hz: 120)
        c1.enqueueScroll(dx: 50, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: clk1.now)
        clk1.advanceOne(c1, hz: 120)

        // First lift starts coast
        c1.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: clk1.now)
        check(c1.isMomentumCoasting, "First lift starts coasting")
        let coastVel = c1.currentVelocity

        // Duplicate lifts (5 times)
        for _ in 0..<5 {
            c1.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: clk1.now)
            check(c1.isMomentumCoasting, "Duplicate lift does not cancel coast")
            checkClose(c1.currentVelocity, coastVel, tolerance: 1e-4, "Coast velocity preserved")
        }

        // Sub-test 3B: Phase 4 when idle
        let c2 = makeController(maxOffset: 5000)
        c2.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: 1.0)
        check(!c2.isMoving, "Phase 4 while idle stays idle")

        // Sub-test 3C: Duplicate phase 4 with non-zero delta
        let c3 = makeController(maxOffset: 5000)
        SettingsStore.shared.momentumScrolling = false
        let clk3 = MotionClock()
        clk3.prime(c3)
        c3.enqueueScroll(dx: 20, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: clk3.now)
        clk3.advanceOne(c3, hz: 120)
        c3.enqueueScroll(dx: 10, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: clk3.now)
        let posAfterFirstLift = c3.currentOffset
        checkClose(posAfterFirstLift, 30, tolerance: 0.1, "First lift with delta applied 30")
        // Second lift with delta 5
        c3.enqueueScroll(dx: 5, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: clk3.now)
        checkClose(c3.currentOffset, 35, tolerance: 0.1, "Second lift with delta 5 applied 5 more")
        print("  Duplicate lift handling verified.")
    }

    // -------------------------------------------------------------------------
    // TEST 4: Cancelation (cancelAnimation) Edge Cases
    // -------------------------------------------------------------------------
    print("\n[Test 4] Cancelation (cancelAnimation) Edge Cases...")
    do {
        // Cancel during active direct-touch with large pending backlog
        let controller = makeController(maxOffset: 10_000)
        SettingsStore.shared.scrollSensitivity = 1.0
        SettingsStore.shared.trackpadNaturalScroll = false
        SettingsStore.shared.momentumScrolling = false
        let clock = MotionClock()
        clock.prime(controller)

        controller.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: clock.now)
        clock.advanceOne(controller, hz: 120)
        controller.enqueueScroll(dx: 500, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: clock.now)
        check(controller.directTouchPending > 0, "Has pending backlog")
        check(controller.isDirectTouchResampling, "Is resampling")

        let offsetAtCancel = controller.currentOffset
        controller.cancelAnimation()

        check(!controller.isDirectTouchResampling, "Resampler deactivated by cancelAnimation")
        check(controller.directTouchPending == 0, "Pending delta zeroed by cancelAnimation")
        check(controller.currentOffset == offsetAtCancel, "Visible offset frozen at cancellation point")
        check(controller.smoothTargetOffset == controller.currentOffset, "smoothTargetOffset parked at currentOffset")
        check(!controller.isMoving, "Controller is not moving after cancel")

        // Display ticks after cancel must not advance offset
        for _ in 0..<5 {
            clock.advanceOne(controller, hz: 120)
            check(controller.currentOffset == offsetAtCancel, "No movement on ticks after cancel")
        }

        // Cancel while overscrolled beyond shrunken geometry
        controller.setOffset(2000, maxOffset: 5000)
        controller.maxOffset = 800
        controller.cancelAnimation()
        checkClose(controller.currentOffset, 800, tolerance: 1e-4, "Cancel clamps offset to shrunken maxOffset")
        print("  Cancelation edge cases verified.")
    }

    // -------------------------------------------------------------------------
    // TEST 5: Gesture Interruption by Keyboard Retargeting & Finger Lift
    // -------------------------------------------------------------------------
    print("\n[Test 5] Gesture Interruption by Keyboard Retargeting & Finger Lift...")
    do {
        let controller = makeController(maxOffset: 5000)
        SettingsStore.shared.scrollSensitivity = 1.0
        SettingsStore.shared.trackpadNaturalScroll = false
        SettingsStore.shared.momentumScrolling = true
        let clock = MotionClock()
        clock.prime(controller)

        // Step 1: User scrolls with trackpad
        controller.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: clock.now)
        clock.advanceOne(controller, hz: 120)
        controller.enqueueScroll(dx: 30, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: clock.now)
        clock.advanceOne(controller, hz: 120)
        let pos1 = controller.currentOffset

        // Step 2: Keyboard shortcut triggers scrollTo(2500)
        controller.scrollTo(target: 2500, maxOffset: 5000)
        check(controller.isSpringAnimating, "Spring animation active after scrollTo")
        checkClose(controller.smoothTargetOffset, 2500, tolerance: 1e-4, "smoothTargetOffset set to 2500")

        // Advance 4 frames of spring
        clock.advance(controller, seconds: 0.04, hz: 120)
        let springPos = controller.currentOffset
        check(springPos > pos1, "Spring advanced towards 2500")

        // Step 3: Finger lifts from trackpad (phase 4, delta 0)
        // What happens?
        print("  Checking behavior when phase 4 arrives during active spring...")
        controller.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: clock.now)
        
        // Let's observe if spring was aborted or continues
        let wasSpringAborted = !controller.isSpringAnimating
        print("  After phase 4 lift during spring: isSpringAnimating=\(controller.isSpringAnimating), isActivelyScrolling=\(controller.isActivelyScrolling), phase=\(controller.isMoving)")
        
        clock.advance(controller, seconds: 1.5, hz: 120)
        print("  Position after 1.5s: \(controller.currentOffset) (Target was 2500)")

        if wasSpringAborted || abs(controller.currentOffset - 2500) > 1.0 {
            print("  [FINDING] Keyboard spring WAS cancelled by trailing finger lift (ended at \(controller.currentOffset) instead of 2500)!")
        } else {
            print("  [OK] Spring completed to 2500.")
        }
        check(!wasSpringAborted, "Trailing zero-delta lift does not abort the keyboard spring")
        checkClose(controller.currentOffset, 2500, tolerance: 1.0, "Keyboard spring completes to target after trailing lift")
    }

    // -------------------------------------------------------------------------
    // TEST 6: Epoch Timeout & Lost-Lift Recovery
    // -------------------------------------------------------------------------
    print("\n[Test 6] Epoch Timeout & Lost-Lift Recovery...")
    do {
        let controller = makeController(maxOffset: 5000)
        SettingsStore.shared.scrollSensitivity = 1.0
        SettingsStore.shared.trackpadNaturalScroll = false
        SettingsStore.shared.momentumScrolling = false
        let clock = MotionClock()
        clock.prime(controller)

        // 1. Send touch packets
        controller.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: clock.now)
        clock.advanceOne(controller, hz: 120)
        controller.enqueueScroll(dx: 15, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: clock.now)
        controller.enqueueScroll(dx: 15, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: clock.now)
        // Total input = 30. Don't tick yet.
        check(controller.directTouchPending == 30, "Pending is 30 before tick")

        // 2. Pause time for 0.15s (> 0.12s directTouchEpochTimeout) - lost lift!
        clock.advance(controller, seconds: 0.15, hz: 120)

        // 3. Verify epoch timeout behavior
        check(!controller.isDirectTouchResampling, "Timeout resets resampler")
        check(controller.directTouchPending == 0, "Timeout flushed pending input")
        checkClose(controller.currentOffset, 30, tolerance: 0.01, "Timeout flushed all 30pt to visible offset")
        checkClose(controller.currentVelocity, 0, tolerance: 0.001, "Timeout zeroed velocity to prevent flick")
        check(!controller.isMoving, "Controller is idle after timeout")

        // 4. Continue touch after timeout gap (macOS sends phase 2 without phase 1)
        controller.enqueueScroll(dx: 10, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: clock.now)
        check(controller.isDirectTouchResampling, "Resampler resumes on continuing phase 2")
        clock.advanceOne(controller, hz: 120)
        controller.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: clock.now)
        checkClose(controller.currentOffset, 40, tolerance: 0.01, "Continuing touch added exact 10pt without jump")

        // 5. Lost lift where lift event NEVER arrives and user touches again after 2 seconds
        clock.advance(controller, seconds: 2.0, hz: 120)
        controller.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: clock.now)
        clock.advanceOne(controller, hz: 120)
        controller.enqueueScroll(dx: 25, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: clock.now)
        controller.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: clock.now)
        checkClose(controller.currentOffset, 65, tolerance: 0.01, "New gesture starts clean without inherited backlog")
        print("  Epoch timeout and lost-lift recovery verified.")
    }

    // -------------------------------------------------------------------------
    // TEST 7: Sub-epsilon Delta Accumulation Ledger Preservation
    // -------------------------------------------------------------------------
    print("\n[Test 7] Sub-epsilon Delta Accumulation...")
    do {
        let controller = makeController(maxOffset: 5000)
        SettingsStore.shared.scrollSensitivity = 1.0
        SettingsStore.shared.trackpadNaturalScroll = false
        SettingsStore.shared.momentumScrolling = false
        let clock = MotionClock()
        clock.prime(controller)

        controller.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: clock.now)
        clock.advanceOne(controller, hz: 120)

        // 100 packets of 0.0005 pt each (total 0.05 pt, each below residualEpsilon 0.01)
        for _ in 0..<100 {
            controller.enqueueScroll(dx: 0.0005, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: clock.now)
            clock.advanceOne(controller, hz: 120)
        }
        controller.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: clock.now)

        checkClose(controller.directTouchTotalApplied, 0.05, tolerance: 1e-4, "Sub-epsilon inputs accumulated exactly")
        checkClose(controller.currentOffset, 0.05, tolerance: 1e-4, "Current offset reflects sub-epsilon accumulation")
        print("  Sub-epsilon accumulation verified.")
    }

    // -------------------------------------------------------------------------
    // TEST 8: Deceleration / Friction & Momentum Dynamics
    // -------------------------------------------------------------------------
    print("\n[Test 8] Deceleration / Friction & Momentum Dynamics...")
    do {
        // High friction (fast stop) vs Low friction (long glide)
        var highFrictionDisplacement: CGFloat = 0.0
        var lowFrictionDisplacement: CGFloat = 0.0

        for (friction, result) in [(0.91, { highFrictionDisplacement = $0 }), (0.98, { lowFrictionDisplacement = $0 })] {
            let controller = makeController(maxOffset: 500_000)
            SettingsStore.shared.scrollSensitivity = 1.0
            SettingsStore.shared.trackpadNaturalScroll = false
            SettingsStore.shared.freezeOnRelease = false
            SettingsStore.shared.momentumScrolling = true
            SettingsStore.shared.scrollDeceleration = friction

            let clock = MotionClock()
            clock.prime(controller)

            // Rapid flick: 10 frames of 80pt displacement
            controller.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: clock.now)
            clock.advanceOne(controller, hz: 120)
            for _ in 0..<10 {
                controller.enqueueScroll(dx: 80.0, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: clock.now)
                clock.advanceOne(controller, hz: 120)
            }
            // Lift fingers
            controller.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: clock.now)

            // Step clock through coasting until settled
            for _ in 0..<240 {
                clock.advanceOne(controller, hz: 120)
                if !controller.isMoving { break }
            }

            check(controller.currentOffset.isFinite, "Deceleration produced finite offset at friction=\(friction)")
            result(controller.currentOffset)
        }

        check(
            lowFrictionDisplacement > highFrictionDisplacement,
            "Lower friction (0.98) glides further than higher friction (0.91): got \(lowFrictionDisplacement) > \(highFrictionDisplacement)"
        )
        print("  Deceleration and friction monotonicity verified.")
    }

    // -------------------------------------------------------------------------
    // TEST 9: Inertial Scrolling Toggle Verification
    // -------------------------------------------------------------------------
    print("\n[Test 9] Inertial Scrolling Toggle...")
    do {
        // Case A: Inertial scrolling disabled
        let controllerA = makeController(maxOffset: 50_000)
        SettingsStore.shared.scrollSensitivity = 1.0
        SettingsStore.shared.trackpadNaturalScroll = false
        SettingsStore.shared.freezeOnRelease = false
        SettingsStore.shared.momentumScrolling = true
        SettingsStore.shared.inertialScrolling = false
        let clockA = MotionClock()
        clockA.prime(controllerA)

        controllerA.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: clockA.now)
        clockA.advanceOne(controllerA, hz: 120)
        for _ in 0..<5 {
            controllerA.enqueueScroll(dx: 60.0, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: clockA.now)
            clockA.advanceOne(controllerA, hz: 120)
        }
        let offsetBeforeLiftA = controllerA.currentOffset
        controllerA.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: clockA.now)
        clockA.advanceOne(controllerA, hz: 120)

        check(!controllerA.isMomentumCoasting, "Inertial scrolling disabled prevents momentum coasting")
        checkClose(controllerA.currentOffset, offsetBeforeLiftA, tolerance: 0.5, "Offset halts at release when inertia disabled")

        // Case B: Inertial scrolling enabled
        let controllerB = makeController(maxOffset: 50_000)
        SettingsStore.shared.inertialScrolling = true
        let clockB = MotionClock()
        clockB.prime(controllerB)

        controllerB.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: clockB.now)
        clockB.advanceOne(controllerB, hz: 120)
        for _ in 0..<5 {
            controllerB.enqueueScroll(dx: 60.0, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: clockB.now)
            clockB.advanceOne(controllerB, hz: 120)
        }
        controllerB.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: clockB.now)
        clockB.advanceOne(controllerB, hz: 120)

        check(controllerB.isMomentumCoasting, "Inertial scrolling enabled enters momentum coasting")
        print("  Inertial scrolling toggle verified.")
    }

    // -------------------------------------------------------------------------
    // TEST 10: Momentum Scrolling Velocity Multiplier
    // -------------------------------------------------------------------------
    print("\n[Test 10] Momentum Velocity Multiplier Scaling...")
    do {
        var baseDistance: CGFloat = 0.0
        var boostedDistance: CGFloat = 0.0

        for (mult, record) in [(1.0, { baseDistance = $0 }), (2.0, { boostedDistance = $0 })] {
            let controller = makeController(maxOffset: 100_000)
            SettingsStore.shared.scrollSensitivity = 1.0
            SettingsStore.shared.trackpadNaturalScroll = false
            SettingsStore.shared.freezeOnRelease = false
            SettingsStore.shared.momentumScrolling = true
            SettingsStore.shared.inertialScrolling = true
            SettingsStore.shared.momentumMultiplier = mult
            SettingsStore.shared.scrollDeceleration = 0.95

            let clock = MotionClock()
            clock.prime(controller)

            controller.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: clock.now)
            clock.advanceOne(controller, hz: 120)
            for _ in 0..<5 {
                controller.enqueueScroll(dx: 70.0, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: clock.now)
                clock.advanceOne(controller, hz: 120)
            }
            controller.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: clock.now)

            for _ in 0..<200 {
                clock.advanceOne(controller, hz: 120)
                if !controller.isMoving { break }
            }
            record(controller.currentOffset)
        }

        check(
            boostedDistance > baseDistance,
            "Momentum multiplier 2.0x glides further than 1.0x: \(boostedDistance) > \(baseDistance)"
        )
        print("  Momentum velocity multiplier scaling verified.")
    }

    // -------------------------------------------------------------------------
    // TEST 11: Kinetic Scrolling Profiles
    // -------------------------------------------------------------------------
    print("\n[Test 11] Kinetic Scrolling Profiles...")
    do {
        var snappyDist: CGFloat = 0.0
        var highInertiaDist: CGFloat = 0.0

        for (profile, record) in [(KineticScrollingProfile.snappy, { snappyDist = $0 }),
                                  (KineticScrollingProfile.highInertia, { highInertiaDist = $0 })] {
            let controller = makeController(maxOffset: 100_000)
            SettingsStore.shared.scrollSensitivity = 1.0
            SettingsStore.shared.trackpadNaturalScroll = false
            SettingsStore.shared.freezeOnRelease = false
            SettingsStore.shared.momentumScrolling = true
            SettingsStore.shared.inertialScrolling = true
            SettingsStore.shared.momentumMultiplier = 1.0
            SettingsStore.shared.scrollDeceleration = 0.95
            SettingsStore.shared.kineticScrollingProfile = profile

            let clock = MotionClock()
            clock.prime(controller)

            controller.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: clock.now)
            clock.advanceOne(controller, hz: 120)
            for _ in 0..<6 {
                controller.enqueueScroll(dx: 60.0, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: clock.now)
                clock.advanceOne(controller, hz: 120)
            }
            controller.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: clock.now)

            for _ in 0..<200 {
                clock.advanceOne(controller, hz: 120)
                if !controller.isMoving { break }
            }
            record(controller.currentOffset)
        }

        check(
            highInertiaDist > snappyDist,
            "High inertia profile glides further than snappy profile: \(highInertiaDist) > \(snappyDist)"
        )
        print("  Kinetic scrolling profiles verified.")
    }

    // -------------------------------------------------------------------------
    // TEST 12: Smooth Scrolling Toggle & Discrete Step Latency
    // -------------------------------------------------------------------------
    print("\n[Test 12] Smooth Scrolling Toggle & Dynamics...")
    do {
        // Disabled: discrete mouse wheel step jumps immediately on next display link
        let controllerA = makeController(maxOffset: 50_000)
        SettingsStore.shared.scrollSensitivity = 1.0
        SettingsStore.shared.trackpadNaturalScroll = false
        SettingsStore.shared.smoothScrollingEnabled = false
        let clockA = MotionClock()
        clockA.prime(controllerA)

        // Mouse wheel event (phase 0, momentumPhase 0)
        controllerA.enqueueScroll(dx: 120.0, dy: 0, phase: 0, momentumPhase: 0, flags: [], timestamp: clockA.now)
        clockA.advanceOne(controllerA, hz: 120)
        checkClose(controllerA.currentOffset, 120.0, tolerance: 0.05, "Disabled smooth scrolling applies step immediately")

        // Enabled: discrete mouse wheel step moves gradually through low-pass filter
        let controllerB = makeController(maxOffset: 50_000)
        SettingsStore.shared.smoothScrollingEnabled = true
        SettingsStore.shared.scrollSmoothness = 0.85
        let clockB = MotionClock()
        clockB.prime(controllerB)

        controllerB.enqueueScroll(dx: 120.0, dy: 0, phase: 0, momentumPhase: 0, flags: [], timestamp: clockB.now)
        clockB.advanceOne(controllerB, hz: 120)
        check(controllerB.currentOffset < 110.0, "Enabled smooth scrolling eases gradually (first frame \(controllerB.currentOffset) < 110.0)")
        print("  Smooth scrolling toggle and dynamics verified.")
    }

    print("\n==========================================")
    print("=== ADVERSARIAL STRESS SUITE COMPLETE ===")
    print("==========================================\n")
}
