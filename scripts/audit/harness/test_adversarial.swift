import Foundation
import CoreGraphics
import QuartzCore

@MainActor
func testKeyboardInterruptionByLift() {
    let controller = makeController(maxOffset: 5000)
    SettingsStore.shared.scrollSensitivity = 1.0
    SettingsStore.shared.trackpadNaturalScroll = false
    SettingsStore.shared.momentumScrolling = true
    let clock = MotionClock()
    clock.prime(controller)

    // 1. User starts scrolling with 2 fingers
    controller.enqueueScroll(dx: 0, dy: 0, phase: 1, momentumPhase: 0, flags: [], timestamp: clock.now)
    clock.advanceOne(controller, hz: 120)
    controller.enqueueScroll(dx: 20, dy: 0, phase: 2, momentumPhase: 0, flags: [], timestamp: clock.now)
    clock.advanceOne(controller, hz: 120)
    let posDuringTrack = controller.currentOffset
    print("Position during track: \(posDuringTrack)")

    // 2. Keyboard shortcut arrives and navigates to target 1000
    controller.scrollTo(target: 1000, maxOffset: 5000)
    print("After scrollTo(1000): phase=\(controller.isSpringAnimating), target=\(controller.smoothTargetOffset)")

    clock.advance(controller, seconds: 0.05, hz: 120)
    print("Mid-spring position: \(controller.currentOffset), velocity=\(controller.currentVelocity)")

    // 3. User lifts fingers from trackpad (phase 4, delta 0)
    controller.enqueueScroll(dx: 0, dy: 0, phase: 4, momentumPhase: 0, flags: [], timestamp: clock.now)
    print("After phase 4 lift: isSpringAnimating=\(controller.isSpringAnimating), isMoving=\(controller.isMoving), phase=\(controller.isActivelyScrolling)")

    // 4. Advance clock by 1.0s to allow spring to finish
    clock.advance(controller, seconds: 1.0, hz: 120)
    print("Final position after 1.0s: \(controller.currentOffset), target was 1000")
    if abs(controller.currentOffset - 1000) > 1.0 {
        print("BUG CONFIRMED: Spring was aborted by lift event! Final offset: \(controller.currentOffset)")
    } else {
        print("SUCCESS: Spring reached target 1000")
    }
}
