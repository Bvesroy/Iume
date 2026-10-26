import Foundation
import CoreGraphics

/// The one authoritative damped-harmonic-oscillator state used by the sliding engine.
///
/// The step is the exact closed-form solution of
///
///     x'' + 2ζωx' + ω²(x - target) = 0
///
/// rather than a discrete approximation. That matters because the display link is
/// not guaranteed to hand us a fixed cadence: a 60 Hz panel, an 80 Hz ProMotion
/// panel that has downclocked, and a 120 Hz panel all have to converge to the same
/// position at the same wall-clock time. An exact step also stays stable for every
/// clamped `dt`, so a stalled frame cannot overshoot or explode.
///
/// `response` keeps its existing meaning from the shipping controller: the natural
/// period of the oscillator in seconds (`ω = 2π / response`, floor 50 ms). It is not
/// the settle time. `dampingRatio` is the usual ζ: 1 is critically damped (no
/// overshoot), below 1 is underdamped (a small, intentional overshoot), above 1 is
/// overdamped.
public struct SpringState: Sendable, Equatable {
    public var position: CGFloat = 0
    public var velocity: CGFloat = 0
    public var target: CGFloat = 0
    /// Natural period in seconds (~0.22 s is the perceptual response used in the app).
    public var response: CGFloat = 0.22
    /// Damping ratio ζ. The shipping default is a slight underdamp for a crisp snap.
    public var dampingRatio: CGFloat = 0.92

    /// Longest integration step we will ever take. A display tick that arrives after
    /// a stall, a suspend/resume, or a debugger pause is truncated to this so the
    /// viewport never teleports. 1/30 s also covers a 30 Hz display without altering
    /// the normal 60/80/120/240 Hz paths.
    public static let maxFrameDelta: CGFloat = 1.0 / 30.0

    /// Rest thresholds, preserved from the shipping solver for behavioural compatibility.
    public static let restPositionEpsilon: CGFloat = 0.40
    public static let restVelocityEpsilon: CGFloat = 3.5

    public init(position: CGFloat = 0, velocity: CGFloat = 0, target: CGFloat = 0) {
        self.position = position
        self.velocity = velocity
        self.target = target
    }

    /// True once the oscillator is visually and kinetically settled.
    ///
    /// A non-finite state is treated as settled: callers use this to terminate an
    /// animation, and continuing to integrate NaN would never terminate. `step`
    /// repairs such a state first, so this only guards callers that inspect it
    /// before stepping.
    public var isAtRest: Bool {
        guard position.isFinite, velocity.isFinite, target.isFinite else { return true }
        return abs(target - position) < Self.restPositionEpsilon
            && abs(velocity) < Self.restVelocityEpsilon
    }

    /// Change the destination without disturbing the current position or velocity.
    ///
    /// This is the retarget primitive the keyboard path uses: a new focus target
    /// arriving mid-flight must bend the existing trajectory, not restart it.
    public mutating func retarget(_ newTarget: CGFloat) {
        guard newTarget.isFinite else { return }
        target = newTarget
    }

    /// Advance the exact solution by `dt` seconds.
    ///
    /// `dt <= 0` is a no-op (a duplicate display-link timestamp must not advance
    /// physics), non-finite deltas are ignored, and deltas above `maxFrameDelta`
    /// are clamped. The state is repaired rather than propagated if it is already
    /// non-finite.
    public mutating func step(dt: CGFloat) {
        guard position.isFinite, velocity.isFinite, target.isFinite else {
            position = target.isFinite ? target : 0
            velocity = 0
            return
        }
        guard dt.isFinite, dt > 0 else { return }
        let h = min(dt, Self.maxFrameDelta)
        guard h > 0 else { return }

        let omega = (2 * CGFloat.pi) / max(0.05, response)
        let zeta = min(max(dampingRatio.isFinite ? dampingRatio : 1, 0), 10)
        let d0 = position - target
        let v0 = velocity

        var d1: CGFloat
        var v1: CGFloat

        if zeta < 1 - 1e-4 {
            // Underdamped: d(t) = e^(-ζωt)[d₀ cos(ω_d t) + ((v₀+ζωd₀)/ω_d) sin(ω_d t)]
            let omegaD = omega * sqrt(1 - zeta * zeta)
            let decay = exp(-zeta * omega * h)
            let angle = omegaD * h
            let sinAngle = sin(angle)
            let cosAngle = cos(angle)
            let b = (v0 + zeta * omega * d0) / omegaD
            d1 = decay * (d0 * cosAngle + b * sinAngle)
            v1 = decay * (v0 * cosAngle - ((omega * omega * d0 + zeta * omega * v0) / omegaD) * sinAngle)
        } else if zeta <= 1 + 1e-4 {
            // Critically damped: d(t) = (d₀ + (v₀ + ωd₀)t)e^(-ωt)
            let decay = exp(-omega * h)
            let b = v0 + omega * d0
            d1 = (d0 + b * h) * decay
            v1 = (v0 - omega * b * h) * decay
        } else {
            // Overdamped: two real exponentials.
            let root = sqrt(zeta * zeta - 1)
            let r1 = -omega * (zeta - root)
            let r2 = -omega * (zeta + root)
            let denominator = r1 - r2
            let c1 = (v0 - r2 * d0) / denominator
            let c2 = (r1 * d0 - v0) / denominator
            let e1 = exp(r1 * h)
            let e2 = exp(r2 * h)
            d1 = c1 * e1 + c2 * e2
            v1 = c1 * r1 * e1 + c2 * r2 * e2
        }

        position = target + d1
        velocity = v1

        // A pathological response/damping pair must never poison the render loop.
        if !position.isFinite || !velocity.isFinite {
            position = target
            velocity = 0
            return
        }

        if isAtRest {
            position = target
            velocity = 0
        }
    }
}
