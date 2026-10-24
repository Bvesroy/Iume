import Testing
import CoreGraphics
@testable import IumeCore

/// Loop mode treats the horizontal strip as a circle, so the scroll offset is only
/// meaningful modulo one full period. These tests pin the contract of the pure
/// normalization helper: the controller may fold resting offsets by whole periods
/// without moving what is on screen.
///
/// Only the static helper is exercised. Constructing `ScrollController` would start a
/// display link and, on a machine with a trackpad, install runtime machinery; the
/// helper is deliberately independent of that.
@Suite("Scroll loop offset normalization")
struct ScrollLoopTests {

    private let period: CGFloat = 1000

    @Test("Zero and exact multiples of the period map to the start of the cycle")
    func exactMultiples() {
        #expect(ScrollController.normalizedOffset(0, period: period) == 0)
        #expect(ScrollController.normalizedOffset(period, period: period) == 0)
        #expect(ScrollController.normalizedOffset(period * 7, period: period) == 0)
        #expect(ScrollController.normalizedOffset(-period, period: period) == 0)
        #expect(ScrollController.normalizedOffset(-period * 4, period: period) == 0)
    }

    @Test("Offsets already inside the cycle are unchanged")
    func insideCycle() {
        #expect(ScrollController.normalizedOffset(1, period: period) == 1)
        #expect(ScrollController.normalizedOffset(period - 1, period: period) == period - 1)
        #expect(ScrollController.normalizedOffset(0.25, period: 0.5) == 0.25)
    }

    @Test("Offsets past one period wrap back into the cycle")
    func pastOnePeriod() {
        #expect(ScrollController.normalizedOffset(period + 1, period: period) == 1)
        #expect(ScrollController.normalizedOffset(period * 3 + 250, period: period) == 250)
        #expect(ScrollController.normalizedOffset(period + 0.5, period: period) == 0.5)
    }

    @Test("Negative offsets wrap forward into the cycle")
    func negativeOffsets() {
        #expect(ScrollController.normalizedOffset(-1, period: period) == period - 1)
        #expect(ScrollController.normalizedOffset(-(period + 1), period: period) == period - 1)
        #expect(ScrollController.normalizedOffset(-period * 2 - 250, period: period) == period - 250)
        #expect(ScrollController.normalizedOffset(-0.5, period: period) == period - 0.5)
    }

    @Test("Negative zero is canonicalised to positive zero")
    func negativeZero() {
        let result = ScrollController.normalizedOffset(CGFloat(-0.0), period: period)
        #expect(result == 0)
        #expect(result.sign == .plus)
    }

    @Test("A non-positive or non-finite period has no usable cycle")
    func degeneratePeriods() {
        #expect(ScrollController.normalizedOffset(123, period: 0) == 0)
        #expect(ScrollController.normalizedOffset(123, period: -10) == 0)
        #expect(ScrollController.normalizedOffset(123, period: .infinity) == 0)
        #expect(ScrollController.normalizedOffset(123, period: .nan) == 0)
    }

    @Test("A non-finite offset has no usable cycle")
    func nonFiniteOffsets() {
        #expect(ScrollController.normalizedOffset(.nan, period: period) == 0)
        #expect(ScrollController.normalizedOffset(.infinity, period: period) == 0)
        #expect(ScrollController.normalizedOffset(-.infinity, period: period) == 0)
    }

    @Test("A tiny period still yields a value inside the cycle")
    func tinyPeriod() {
        let tiny: CGFloat = 1e-9
        let offsets: [CGFloat] = [0, tiny, tiny * 3, -tiny, 1, -1, 12_345.678]
        for offset in offsets {
            let result = ScrollController.normalizedOffset(offset, period: tiny)
            #expect(result >= 0, "offset \(offset) produced \(result)")
            #expect(result < tiny, "offset \(offset) produced \(result)")
        }
    }

    @Test("Tiny negative remainders never round up to exactly one period")
    func roundingAtTheSeam() {
        // Adding `period` to a one-ulp negative remainder rounds to exactly `period`
        // in Double, which would break the half-open range contract.
        let hugePeriod: CGFloat = 1_000_000
        let result = ScrollController.normalizedOffset(-CGFloat.ulpOfOne, period: hugePeriod)
        #expect(result == 0)
        #expect(result < hugePeriod)
    }

    @Test("Offsets one or more laps apart normalize to the same value")
    func periodEquivalence() {
        let bases: [CGFloat] = [0, 1, 250.5, 999.999, period - 0.5]
        for base in bases {
            let expected = ScrollController.normalizedOffset(base, period: period)
            for lap in -3...3 {
                let shifted = base + CGFloat(lap) * period
                let result = ScrollController.normalizedOffset(shifted, period: period)
                #expect(abs(result - expected) < 1e-9, "base \(base), lap \(lap): \(result) vs \(expected)")
            }
        }
    }

    @Test("Every finite offset lands in the half-open cycle")
    func rangeProperty() {
        let sweepPeriod: CGFloat = 137.5
        var offset: CGFloat = -5_000
        while offset <= 5_000 {
            let result = ScrollController.normalizedOffset(offset, period: sweepPeriod)
            #expect(result >= 0, "offset \(offset) produced \(result)")
            #expect(result < sweepPeriod, "offset \(offset) produced \(result)")
            offset += 37.25
        }
    }

    // MARK: - Loop seam crossings (cue trigger)

    @Test("A movement that steps over a lap boundary is a crossing")
    func seamCrossedForwardAndBackward() {
        #expect(ScrollController.crossedLoopSeam(from: 0.98 * period, to: 1.02 * period, period: period))
        #expect(ScrollController.crossedLoopSeam(from: 0.02 * period, to: -0.02 * period, period: period))
        #expect(ScrollController.crossedLoopSeam(from: -0.05 * period, to: -1.05 * period, period: period))
        #expect(ScrollController.crossedLoopSeam(from: 0.25 * period, to: 1.25 * period, period: period))
    }

    @Test("A movement that stays inside one lap is not a crossing")
    func seamNotCrossedInsideLap() {
        #expect(!ScrollController.crossedLoopSeam(from: 0.10 * period, to: 0.90 * period, period: period))
        #expect(!ScrollController.crossedLoopSeam(from: 0.90 * period, to: 0.10 * period, period: period))
        #expect(!ScrollController.crossedLoopSeam(from: 0, to: 0, period: period))
        #expect(!ScrollController.crossedLoopSeam(from: 3.20 * period, to: 3.80 * period, period: period))
    }

    @Test("Landing exactly on the seam counts as a crossing")
    func seamAtExactBoundary() {
        #expect(ScrollController.crossedLoopSeam(from: 0.999 * period, to: period, period: period))
        #expect(ScrollController.crossedLoopSeam(from: period, to: 0, period: period))
        #expect(ScrollController.crossedLoopSeam(from: period, to: 0.5 * period, period: period))
        #expect(!ScrollController.crossedLoopSeam(from: period, to: period, period: period))
    }

    @Test("Degenerate or non-finite inputs never report a crossing")
    func seamDegenerateInputs() {
        #expect(!ScrollController.crossedLoopSeam(from: 0, to: 10, period: 0))
        #expect(!ScrollController.crossedLoopSeam(from: 0, to: 10, period: -100))
        #expect(!ScrollController.crossedLoopSeam(from: 0, to: 10, period: .infinity))
        #expect(!ScrollController.crossedLoopSeam(from: 0, to: 10, period: .nan))
        #expect(!ScrollController.crossedLoopSeam(from: .nan, to: 10, period: period))
        #expect(!ScrollController.crossedLoopSeam(from: 0, to: .infinity, period: period))
    }
}
