//! Frame-rate independent spring physics.
//!
//! Port of `SpringState` from `ScrollController.swift`. The Swift solver is
//! already analytically stable; this port exists so the per-frame math leaves
//! the main actor and so the whole step is branch-free and `no_std`-friendly.

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
        (self.target - self.position).abs() < Self::REST_POSITION_EPSILON
            && self.velocity.abs() < Self::REST_VELOCITY_EPSILON
    }

    /// Advance the spring by `dt` seconds. Bit-for-bit the Swift solver.
    #[inline]
    pub fn step(&mut self, dt: f64) {
        let clamped_dt = dt.clamp(0.001, 0.033);
        let omega = (2.0 * std::f64::consts::PI) / self.response.max(0.05);
        let f = 1.0 + 2.0 * clamped_dt * self.damping_ratio * omega;
        let oo = omega * omega;
        let hoo = clamped_dt * oo;
        let hhoo = clamped_dt * hoo;
        let det_inv = 1.0 / (f + hhoo);
        let det_x = f * self.position + clamped_dt * self.velocity + hhoo * self.target;
        let det_v = self.velocity + hoo * (self.target - self.position);
        self.position = det_x * det_inv;
        self.velocity = det_v * det_inv;
        if self.is_at_rest() {
            self.position = self.target;
            self.velocity = 0.0;
        }
    }

    /// Retarget without losing momentum (used when a new focus target arrives mid-flight).
    #[inline]
    pub fn retarget(&mut self, target: f64) {
        self.target = target;
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
