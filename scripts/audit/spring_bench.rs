// Phase 2 sliding-engine benchmark.
//
// Compiles against the real `crates/iume_engine` sources (see run-baseline.sh).
// No test-only copies of the physics: every number below comes from the same
// `SpringState::step` the app ships.
//
// Output is a markdown table plus a JSON block so before/after runs can be
// diffed mechanically.

use std::fmt::Write as _;

use iume_engine::spring::SpringState;

const RATES: [u32; 4] = [60, 80, 120, 240];

fn dt_for(hz: u32) -> f64 {
    1.0 / hz as f64
}

fn fresh(target: f64) -> SpringState {
    SpringState::new(0.0, 0.0, target)
}

/// Steps until `is_at_rest`, returning (elapsed seconds, frames, peak position).
fn settle_profile(mut spring: SpringState, hz: u32, max_seconds: f64) -> (f64, usize, f64) {
    let dt = dt_for(hz);
    let max_frames = (max_seconds * hz as f64).ceil() as usize;
    let mut peak = spring.position;
    for frame in 0..max_frames {
        spring.step(dt);
        peak = peak.max(spring.position);
        if spring.is_at_rest() {
            return ((frame + 1) as f64 * dt, frame + 1, peak);
        }
    }
    ((max_frames) as f64 * dt, max_frames, peak)
}

fn position_after(target: f64, hz: u32, seconds: f64) -> f64 {
    let mut spring = fresh(target);
    let dt = dt_for(hz);
    let frames = (seconds * hz as f64).round() as usize;
    for _ in 0..frames {
        spring.step(dt);
    }
    spring.position
}

fn main() {
    let mut md = String::new();
    let mut json = String::new();

    writeln!(md, "| case | 60 Hz | 80 Hz | 120 Hz | 240 Hz |").unwrap();
    writeln!(md, "|---|---:|---:|---:|---:|").unwrap();

    // 1. Settle time / peak overshoot across short and long distances.
    let mut settle_rows = String::new();
    for target in [100.0_f64, 500.0, 2_000.0, 20_000.0] {
        let mut cells = Vec::new();
        for hz in RATES {
            let (t, frames, peak) = settle_profile(fresh(target), hz, 10.0);
            let overshoot = (peak - target).max(0.0);
            cells.push(format!("{:.0} ms / {:.2} pt / {}f", t * 1000.0, overshoot, frames));
        }
        writeln!(
            settle_rows,
            "| settle {} pt | {} |",
            target as i64,
            cells.join(" | ")
        )
        .unwrap();
    }
    md.push_str(&settle_rows);
    writeln!(md).unwrap();

    // 2. Frame-rate consistency: position at a fixed wall-clock time.
    writeln!(md, "| elapsed | 60 Hz | 80 Hz | 120 Hz | 240 Hz | spread |").unwrap();
    writeln!(md, "|---|---:|---:|---:|---:|---:|").unwrap();
    let mut consistency_json = String::new();
    for seconds in [0.05_f64, 0.10, 0.20, 0.35] {
        let positions: Vec<f64> = RATES
            .iter()
            .map(|hz| position_after(500.0, *hz, seconds))
            .collect();
        let min = positions.iter().cloned().fold(f64::INFINITY, f64::min);
        let max = positions.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
        writeln!(
            md,
            "| {:.0} ms | {:.2} | {:.2} | {:.2} | {:.2} | {:.2} pt |",
            seconds * 1000.0,
            positions[0],
            positions[1],
            positions[2],
            positions[3],
            max - min
        )
        .unwrap();
        if !consistency_json.is_empty() {
            consistency_json.push(',');
        }
        write!(
            consistency_json,
            "{{\"seconds\":{seconds},\"positions\":[{:.6},{:.6},{:.6},{:.6}],\"spread\":{:.6}}}",
            positions[0],
            positions[1],
            positions[2],
            positions[3],
            max - min
        )
        .unwrap();
    }
    writeln!(md).unwrap();

    // 3. Retarget continuity (position and velocity before/after).
    let mut spring = fresh(800.0);
    let dt = dt_for(120);
    for _ in 0..40 {
        spring.step(dt);
    }
    let (p_before, v_before) = (spring.position, spring.velocity);
    spring.retarget(-400.0);
    let (p_after, v_after) = (spring.position, spring.velocity);
    let (retarget_time, _, retarget_peak) = settle_profile(spring, 120, 10.0);
    writeln!(
        md,
        "Retarget continuity: position {:.6} -> {:.6} (Δ{:.2e}), velocity {:.6} -> {:.6} (Δ{:.2e}); settles in {:.0} ms, peak {:.2} pt.",
        p_before,
        p_after,
        (p_after - p_before).abs(),
        v_before,
        v_after,
        (v_after - v_before).abs(),
        retarget_time * 1000.0,
        retarget_peak
    )
    .unwrap();
    writeln!(md).unwrap();

    // 4. Reversal impact: max per-frame position jump after a mid-flight
    //    direction change. A jump must stay bounded by the previous frame's
    //    displacement, not restart from the old position.
    let mut spring = fresh(1_000.0);
    for _ in 0..30 {
        spring.step(dt);
    }
    spring.retarget(-1_000.0);
    let mut prev = spring.position;
    let mut reversal_max_step = 0.0_f64;
    for _ in 0..120 {
        spring.step(dt);
        reversal_max_step = reversal_max_step.max((spring.position - prev).abs());
        prev = spring.position;
    }
    writeln!(
        md,
        "Reversal at 120 Hz: max single-frame displacement {:.2} pt (velocity at retarget {:.1} pt/s).",
        reversal_max_step, v_before
    )
    .unwrap();
    writeln!(md).unwrap();

    // 5. Rapid retargeting every 8 ms / 16 ms for 1 s, alternating targets.
    for period_ms in [8_u32, 16] {
        let mut spring = fresh(0.0);
        let dt = period_ms as f64 / 1000.0;
        let mut prev = spring.position;
        let mut max_step = 0.0_f64;
        for i in 0..(1_000 / period_ms) {
            spring.retarget(if i % 2 == 0 { 600.0 } else { -600.0 });
            spring.step(dt);
            max_step = max_step.max((spring.position - prev).abs());
            prev = spring.position;
        }
        writeln!(
            md,
            "Rapid retarget @ {} ms: max single-frame displacement {:.2} pt, final {:.2} pt.",
            period_ms, max_step, spring.position
        )
        .unwrap();
    }
    writeln!(md).unwrap();

    // 6. Pathological dt: a 10 s stall must advance at most one clamped frame.
    let mut spring = fresh(1_000.0);
    spring.step(10.0);
    let stall_step = spring.position;
    let mut momentum = SpringState::new(0.0, 3_000.0, 0.0);
    momentum.step(10.0);
    writeln!(
        md,
        "10 s stall: spring position {:.2} pt (max {:.1}); momentum-velocity state position {:.2} pt.",
        stall_step, 1000.0, momentum.position
    )
    .unwrap();

    json.push_str(&format!(
        "{{\"rates\":[60,80,120,240],\"consistency\":[{consistency_json}],\"retarget\":{{\"pos_before\":{p_before:.6},\"pos_after\":{p_after:.6},\"vel_before\":{v_before:.6},\"vel_after\":{v_after:.6},\"settle_ms\":{:.3},\"peak\":{retarget_peak:.6}}},\"reversal_max_frame_step\":{reversal_max_step:.6},\"stall_step_10s\":{stall_step:.6}}}",
        retarget_time * 1000.0
    ));

    println!("{md}");
    println!("```json\n{json}\n```");
}
