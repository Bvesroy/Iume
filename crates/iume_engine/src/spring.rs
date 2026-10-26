//! Frame-rate independent spring physics.
//!
//! Exact closed-form port of `SpringState` from
//! `Sources/IumeCore/Physics/SpringState.swift`. Both implementations solve the
//! same damped harmonic oscillator analytically, so the Rust FFI path and the
//! live Swift path produce identical motion at any display cadence.

/// Harmonic spring state. Identical semantics to Swift `SpringState`.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct SpringState {
    pub position: f64,
    pub velocity: f64,
    pub target: f64,
    /// Perceptual response time in seconds (~0.22 = 220 ms).
    pub response: f64,
    /// 1.0 = critically damped, < 1.0 = slight overshoot.
    pub damping_ratio: f64,
}

impl Default for SpringState {
    fn default() -> Self {
        Self {
            position: 0.0,
            velocity: 0.0,
            target: 0.0,
            response: 0.22,
            damping_ratio: 0.92,
        }
    }
}

impl SpringState {
    pub const REST_POSITION_EPSILON: f64 = 0.40;
    pub const REST_VELOCITY_EPSILON: f64 = 3.5;
    /// Longest integration step. A stalled display tick is truncated to this so the
    /// viewport never teleports; it still covers a 30 Hz display.
    pub const MAX_FRAME_DELTA: f64 = 1.0 / 30.0;

    #[inline]
    pub fn new(position: f64, velocity: f64, target: f64) -> Self {
        Self {
            position,
            velocity,
            target,
            ..Self::default()
        }
    }

    #[inline]
    pub fn is_at_rest(&self) -> bool {
        if !self.position.is_finite() || !self.velocity.is_finite() || !self.target.is_finite() {
            // A poisoned state can never converge; callers use this to terminate.
            return true;
        }
        (self.target - self.position).abs() < Self::REST_POSITION_EPSILON
            && self.velocity.abs() < Self::REST_VELOCITY_EPSILON
    }

    /// Advance the exact damped-oscillator solution by `dt` seconds.
    ///
    /// Non-finite state is repaired, `dt <= 0` is a no-op, and `dt` above
    /// [`Self::MAX_FRAME_DELTA`] is clamped.
    #[inline]
    pub fn step(&mut self, dt: f64) {
        if !self.position.is_finite() || !self.velocity.is_finite() || !self.target.is_finite() {
            self.position = if self.target.is_finite() { self.target } else { 0.0 };
            self.velocity = 0.0;
            return;
        }
        if !dt.is_finite() || dt <= 0.0 {
            return;
        }
        let h = dt.min(Self::MAX_FRAME_DELTA);
        if h <= 0.0 {
            return;
        }

        let omega = (2.0 * std::f64::consts::PI) / self.response.max(0.05);
        let zeta = if self.damping_ratio.is_finite() {
            self.damping_ratio.clamp(0.0, 10.0)
        } else {
            1.0
        };
        let d0 = self.position - self.target;
        let v0 = self.velocity;

        let (d1, v1) = if zeta < 1.0 - 1e-4 {
            // Underdamped: d(t) = e^(-ζωt)[d₀ cos(ω_d t) + ((v₀+ζωd₀)/ω_d) sin(ω_d t)]
            let omega_d = omega * (1.0 - zeta * zeta).sqrt();
            let decay = (-zeta * omega * h).exp();
            let angle = omega_d * h;
            let sin_angle = angle.sin();
            let cos_angle = angle.cos();
            let b = (v0 + zeta * omega * d0) / omega_d;
            (
                decay * (d0 * cos_angle + b * sin_angle),
                decay * (v0 * cos_angle - ((omega * omega * d0 + zeta * omega * v0) / omega_d) * sin_angle),
            )
        } else if zeta <= 1.0 + 1e-4 {
            // Critically damped: d(t) = (d₀ + (v₀ + ωd₀)t)e^(-ωt)
            let decay = (-omega * h).exp();
            let b = v0 + omega * d0;
            ((d0 + b * h) * decay, (v0 - omega * b * h) * decay)
        } else {
            // Overdamped: two real exponentials.
            let root = (zeta * zeta - 1.0).sqrt();
            let r1 = -omega * (zeta - root);
            let r2 = -omega * (zeta + root);
            let denominator = r1 - r2;
            let c1 = (v0 - r2 * d0) / denominator;
            let c2 = (r1 * d0 - v0) / denominator;
            let e1 = (r1 * h).exp();
            let e2 = (r2 * h).exp();
            (c1 * e1 + c2 * e2, c1 * r1 * e1 + c2 * r2 * e2)
        };

        self.position = self.target + d1;
        self.velocity = v1;

        if !self.position.is_finite() || !self.velocity.is_finite() {
            self.position = self.target;
            self.velocity = 0.0;
            return;
        }

        if self.is_at_rest() {
            self.position = self.target;
            self.velocity = 0.0;
        }
    }

    /// Retarget without losing momentum (used when a new focus target arrives mid-flight).
    #[inline]
    pub fn retarget(&mut self, target: f64) {
        if target.is_finite() {
            self.target = target;
        }
    }

    /// Advance until rest or `max_steps`, returning the number of steps taken.
    pub fn settle(&mut self, dt: f64, max_steps: usize) -> usize {
        for i in 0..max_steps {
            self.step(dt);
            if self.is_at_rest() {
                return i + 1;
            }
        }
        max_steps
    }
}

/// Closed-form critically damped spring, mirroring `CriticallyDampedSpring`.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct CriticallyDampedSpring {
    pub target: f64,
    pub omega: f64,
    x0: f64,
    v0: f64,
    t0: f64,
}

impl CriticallyDampedSpring {
    pub fn new(at: f64, now: f64) -> Self {
        Self {
            target: at,
            omega: 19.0,
            x0: 0.0,
            v0: 0.0,
            t0: now,
        }
    }

    /// Sample position and velocity at `now`.
    pub fn sample(&self, now: f64) -> (f64, f64) {
        let t = (now - self.t0).max(0.0);
        let e = (-self.omega * t).exp();
        let b = self.v0 + self.omega * self.x0;
        let pos = self.target + (self.x0 + b * t) * e;
        let vel = (self.v0 - self.omega * b * t) * e;
        (pos, vel)
    }

    pub fn retarget(&mut self, new_target: f64, now: f64, extra_velocity: f64) {
        let (pos, vel) = self.sample(now);
        self.target = new_target;
        self.x0 = pos - new_target;
        self.v0 = vel + extra_velocity;
        self.t0 = now;
    }

    pub fn is_settled(&self, now: f64) -> bool {
        let (pos, vel) = self.sample(now);
        (pos - self.target).abs() < 0.35 && vel.abs() < 3.0
    }
}

/// Exponential smoothing factor for a given smoothing setting at `dt`.
#[inline]
pub fn smoothing_factor(smoothness: f64, dt: f64) -> f64 {
    let lambda = (35.0 + (1.0 - smoothness) * 80.0).max(28.0);
    1.0 - (-lambda * dt).exp()
}

/// Rubber-band resistance past a boundary.
#[inline]
pub fn rubber_band(delta: f64, overshoot: f64, limit: f64) -> f64 {
    let resistance = (1.0 - overshoot / limit).max(0.10);
    delta * resistance
}

#[cfg(test)]
mod tests {
    use super::*;

    fn position_after(target: f64, seconds: f64, hz: f64) -> f64 {
        let mut spring = SpringState::new(0.0, 0.0, target);
        let dt = 1.0 / hz;
        let steps = (seconds * hz).round() as usize;
        for _ in 0..steps {
            spring.step(dt);
        }
        spring.position
    }

    #[test]
    fn converges_to_target() {
        let mut spring = SpringState::new(0.0, 0.0, 500.0);
        let dt = 1.0 / 120.0;
        for _ in 0..120 {
            spring.step(dt);
        }
        assert!(spring.is_at_rest());
        assert_eq!(spring.position, 500.0);
        assert_eq!(spring.velocity, 0.0);
    }

    #[test]
    fn no_overshoot_beyond_reasonable_bounds() {
        let mut spring = SpringState::new(0.0, 0.0, 100.0);
        let dt = 1.0 / 120.0;
        for _ in 0..240 {
            spring.step(dt);
            assert!(spring.position <= 105.0);
            assert!(spring.position >= -5.0);
        }
    }

    #[test]
    fn stable_at_240hz_and_80hz() {
        for dt in [1.0 / 240.0, 1.0 / 120.0, 1.0 / 80.0] {
            let mut spring = SpringState::new(0.0, 0.0, 300.0);
            for _ in 0..600 {
                spring.step(dt);
            }
            assert!(spring.is_at_rest(), "unstable at dt={dt}");
        }
    }

    #[test]
    fn large_dt_is_clamped() {
        let mut spring = SpringState::new(0.0, 0.0, 100.0);
        spring.step(10.0);
        assert!(spring.position.is_finite());
        assert!(spring.position <= 100.0 + 1.0);
    }

    #[test]
    fn frame_rate_independent_position() {
        // The same target must reach the same place at the same wall-clock time,
        // regardless of how many display ticks happened in between.
        let samples: Vec<f64> = [60.0, 80.0, 120.0, 240.0]
            .iter()
            .map(|hz| position_after(500.0, 0.10, *hz))
            .collect();
        let min = samples.iter().cloned().fold(f64::INFINITY, f64::min);
        let max = samples.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
        assert!(
            max - min < 0.01,
            "refresh-rate dependent: {samples:?} (spread {})",
            max - min
        );
    }

    #[test]
    fn retarget_preserves_position_and_velocity() {
        let mut spring = SpringState::new(0.0, 0.0, 500.0);
        for _ in 0..6 {
            spring.step(1.0 / 120.0);
        }
        let position = spring.position;
        let velocity = spring.velocity;
        assert!(velocity > 0.0);

        spring.retarget(-250.0);

        assert_eq!(spring.position, position);
        assert_eq!(spring.velocity, velocity);
        assert_eq!(spring.target, -250.0);
    }

    #[test]
    fn reversed_retarget_has_no_discontinuity() {
        let mut spring = SpringState::new(0.0, 0.0, 500.0);
        for _ in 0..10 {
            spring.step(1.0 / 120.0);
        }
        let before = spring.position;
        spring.retarget(-250.0);
        spring.step(1.0 / 120.0);
        let displacement = (spring.position - before).abs();
        assert!(
            displacement < 10.0,
            "reversal jumped from {before} to {} in one frame",
            spring.position
        );
    }

    #[test]
    fn critically_damped_never_overshoots() {
        let mut spring = SpringState::new(0.0, 0.0, 100.0);
        spring.damping_ratio = 1.0;
        let dt = 1.0 / 120.0;
        let mut previous = spring.position;
        for _ in 0..240 {
            spring.step(dt);
            assert!(
                spring.position <= 100.0 + 1e-9,
                "critical damping overshot to {}",
                spring.position
            );
            assert!(
                spring.position >= previous - 1e-9,
                "critical damping reversed direction"
            );
            previous = spring.position;
        }
        assert!(spring.is_at_rest());
    }

    #[test]
    fn non_positive_dt_is_noop() {
        let mut spring = SpringState::new(10.0, 2.0, 100.0);
        spring.step(0.0);
        spring.step(-1.0);
        spring.step(f64::NAN);
        assert_eq!(spring.position, 10.0);
        assert_eq!(spring.velocity, 2.0);
    }

    #[test]
    fn non_finite_state_is_repaired() {
        let mut spring = SpringState::new(f64::NAN, f64::INFINITY, 42.0);
        spring.step(1.0 / 120.0);
        assert_eq!(spring.position, 42.0);
        assert_eq!(spring.velocity, 0.0);
        assert!(spring.is_at_rest());
    }

    #[test]
    fn critically_damped_settles() {
        let mut s = CriticallyDampedSpring::new(0.0, 0.0);
        s.retarget(250.0, 0.0, 0.0);
        assert!(!s.is_settled(0.05));
        assert!(s.is_settled(2.0));
    }

    #[test]
    fn smoothing_factor_monotonic() {
        let a = smoothing_factor(0.0, 1.0 / 120.0);
        let b = smoothing_factor(1.0, 1.0 / 120.0);
        assert!(a > b);
    }
}
