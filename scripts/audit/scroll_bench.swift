// Headless benchmark for Iume's ScrollController + LayoutEngine.
//
// Links against prebuilt SwiftPM artifacts so it can run on a machine without
// Xcode (the SwiftUI macro plugin is unavailable in CLT-only setups).
//
// It drives the real ScrollController at a real-time 120 Hz cadence and never
// runs the main run loop, so no CADisplayLink/Timer fires by itself. Settings
// are snapshotted/restored by scripts/audit/run_scroll_bench.sh.
//
// Output: JSON lines on stdout, one object per scenario.

import AppKit
import Foundation
import IumeCore

let hz: Double = 120.0
let frameInterval: Double = 1.0 / hz

func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func emit(_ kind: String, _ fields: [String: Any]) {
    var out: [String: Any] = ["scenario": kind]
    for (k, v) in fields { out[k] = v }
    if let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

func stats(_ xs: [Double]) -> [String: Any] {
    guard !xs.isEmpty else { return ["n": 0] }
    let sorted = xs.sorted()
    let mean = xs.reduce(0, +) / Double(xs.count)
    let varSum = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
    func pct(_ p: Double) -> Double {
        let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[idx]
    }
    return [
        "n": xs.count, "mean": mean,
        "sd": (varSum / Double(xs.count)).squareRoot(),
        "p50": pct(0.50), "p95": pct(0.95),
        "min": sorted.first!, "max": sorted.last!
    ]
}

@MainActor
final class Bench {
    let c = ScrollController()
    var t: Double = CACurrentMediaTime()
    var callbacks = 0
    var frames: [(t: Double, off: CGFloat, target: CGFloat, vel: CGFloat)] = []

    init() {
        c.onViewportOffsetChanged = { [weak self] _ in self?.callbacks += 1 }
    }

    func reset(offset: CGFloat = 0, maxOffset: CGFloat = 20_000) {
        c.setOffset(offset, maxOffset: maxOffset)
        callbacks = 0
        frames.removeAll(keepingCapacity: true)
        t = CACurrentMediaTime()
    }

    /// Real-time pacing. The controller compares event timestamps against
    /// CACurrentMediaTime(), so synthetic timestamps that run faster than the
    /// wall clock poison direct-touch detection.
    func step() {
        let deadline = CACurrentMediaTime() + frameInterval
        t = CACurrentMediaTime()
        c.displayLinkFired(timestamp: t)
        frames.append((t, c.currentOffset, c.smoothTargetOffset, c.currentVelocity))
        while CACurrentMediaTime() < deadline { usleep(250) }
    }

    func step(_ n: Int) { for _ in 0..<n { step() } }

    func gesture(dx: CGFloat, frames n: Int) {
        for _ in 0..<n {
            c.enqueueScroll(dx: dx, dy: 0, phase: 2, momentumPhase: 0, flags: [])
            step()
        }
    }

    func perFrameDeltas() -> [Double] {
        zip(frames, frames.dropFirst()).map { Double($1.off - $0.off) }
    }
}

@MainActor
func runDirect1to1(_ meta: [String: Any]) {
    let b = Bench()
    let s = SettingsStore.shared
    s.freezeOnRelease = false
    s.snapToColumn = false
    s.momentumScrolling = true
    s.scrollSmoothness = 0.75
    s.trackpadNaturalScroll = false
    b.reset()
    b.gesture(dx: 8, frames: 60)
    let sensitivity = s.scrollSensitivity
    let expected = 8.0 * sensitivity * 60.0
    let deltas = b.perFrameDeltas()
    emit("direct_1to1_120hz", [
        "sensitivity": sensitivity,
        "events": 60,
        "frames": 60,
        "expectedOffset": expected,
        "finalOffset": b.frames.last?.off ?? 0,
        "perFrameDelta": stats(deltas),
        "frozenFrames": deltas.filter { abs($0) < 0.001 }.count,
        "lagAtEnd": expected - Double(b.frames.last?.off ?? 0),
        "note": "1:1 with sensitivity; smoothness is bypassed during finger contact"
    ].merging(meta) { $1 })
}

@MainActor
func runBursty(_ meta: [String: Any]) {
    let b = Bench()
    let s = SettingsStore.shared
    s.freezeOnRelease = false
    s.snapToColumn = false
    s.scrollSmoothness = 0.75
    s.trackpadNaturalScroll = false
    b.reset()
    var events = 0
    for i in 0..<60 {
        let packets = (i % 2 == 0) ? 0 : 2
        for _ in 0..<packets {
            b.c.enqueueScroll(dx: 8, dy: 0, phase: 2, momentumPhase: 0, flags: [])
            events += 1
        }
        b.step()
    }
    let deltas = b.perFrameDeltas()
    let frozen = deltas.filter { abs($0) < 0.001 }.count
    let jumps = deltas.filter { abs($0) > 12.0 }.count
    emit("direct_bursty_packets", [
        "events": events,
        "frames": 60,
        "expectedOffset": 8.0 * s.scrollSensitivity * Double(events),
        "finalOffset": b.frames.last?.off ?? 0,
        "perFrameDelta": stats(deltas),
        "frozenFrames": frozen,
        "jumpFramesOver12pt": jumps,
        "note": "same mean rate as direct_1to1, alternating 0/2 packets; frozen frames are visible stutter"
    ].merging(meta) { $1 })
}

@MainActor
func runSmoothnessTouch(_ meta: [String: Any]) {
    for smooth in [0.0, 0.75, 1.0] {
        let b = Bench()
        let s = SettingsStore.shared
        s.freezeOnRelease = false
        s.snapToColumn = false
        s.scrollSmoothness = smooth
        s.trackpadNaturalScroll = false
        b.reset()
        b.gesture(dx: 6, frames: 48)
        let ideal = 6.0 * s.scrollSensitivity * 48.0
        let lags = b.frames.map { Double($0.target - $0.off) }
        emit("smoothness_direct_touch", [
            "smoothness": smooth,
            "finalOffset": b.frames.last?.off ?? 0,
            "idealOffset": ideal,
            "lagAtEnd": ideal - Double(b.frames.last?.off ?? 0),
            "targetVsCurrentLag": stats(lags),
            "perFrameDelta": stats(b.perFrameDeltas())
        ].merging(meta) { $1 })
    }
}

@MainActor
func runSmoothnessWheel(_ meta: [String: Any]) {
    for smooth in [0.0, 0.5, 1.0] {
        let b = Bench()
        let s = SettingsStore.shared
        s.freezeOnRelease = false
        s.snapToColumn = false
        s.scrollSmoothness = smooth
        s.trackpadNaturalScroll = false
        b.reset()
        for _ in 0..<30 {
            b.c.enqueueScroll(dx: 20, dy: 0, phase: 0, momentumPhase: 0, flags: [])
            b.step()
        }
        let lags = b.frames.map { Double($0.target - $0.off) }
        let deltas = b.perFrameDeltas()
        emit("smoothness_wheel", [
            "smoothness": smooth,
            "finalOffset": b.frames.last?.off ?? 0,
            "targetVsCurrentLag": stats(lags),
            "perFrameDelta": stats(deltas),
            "firstFrameOffset": b.frames.first?.off ?? 0,
            "firstFrameTarget": b.frames.first?.target ?? 0
        ].merging(meta) { $1 })
    }
}

@MainActor
func runSpringSettle(_ meta: [String: Any]) {
    for velocity in [0.0, 800.0, -800.0] {
        let b = Bench()
        let s = SettingsStore.shared
        s.snapToColumn = true
        s.animationDuration = 0.22
        s.scrollSmoothness = 0.75
        b.reset()
        let start = CACurrentMediaTime()
        b.c.scrollTo(target: 1200, maxOffset: 20_000, duration: 0.22, initialVelocity: velocity, source: .user)
        let frame0 = b.c.currentOffset
        var steps = 1
        while b.c.isSpringAnimating && steps < 600 {
            b.step()
            steps += 1
        }
        let offs = b.frames.map { Double($0.off) }
        let maxOvershoot = offs.map { $0 - 1200.0 }.max() ?? 0
        let path = zip(offs, offs.dropFirst()).reduce(0.0) { $0 + abs($1.1 - $1.0) }
        emit("spring_settle", [
            "initialVelocity": velocity,
            "frames": steps,
            "elapsedMs": (CACurrentMediaTime() - start) * 1000.0,
            "frame0Offset": frame0,
            "finalOffset": offs.last ?? frame0,
            "finalError": 1200.0 - (offs.last ?? frame0),
            "maxOvershoot": maxOvershoot,
            "pathLength": path,
            "isMovingAfter": b.c.isMoving
        ].merging(meta) { $1 })
    }
}

/// Same 1200 pt settle stepped at 60/80/120/240 Hz with synthetic timestamps.
/// Answers: is the shipped Swift integrator frame-rate independent, and how long
/// does it really take at each refresh rate?
@MainActor
func runSpringSettleRates(_ meta: [String: Any]) {
    for hz in [60.0, 80.0, 120.0, 240.0] {
        let b = Bench()
        let s = SettingsStore.shared
        s.snapToColumn = true
        s.animationDuration = 0.22
        s.scrollSmoothness = 0.75
        b.reset()
        b.c.scrollTo(target: 1200, maxOffset: 20_000, duration: 0.22, initialVelocity: 0, source: .programmatic)
        var t = CACurrentMediaTime()
        let dt = 1.0 / hz
        var steps = 1
        var positionsAt: [Double: Double] = [:]
        // scrollTo already executed frame 0 at 1/120 s inside its own clock.
        let start = t
        while b.c.isSpringAnimating && steps < 4000 {
            t += dt
            b.c.displayLinkFired(timestamp: t)
            let elapsed = t - start
            for mark in [0.05, 0.10, 0.20, 0.35] where positionsAt[mark] == nil && elapsed >= mark {
                positionsAt[mark] = Double(b.c.currentOffset)
            }
            steps += 1
        }
        emit("spring_settle_rate_sweep", [
            "hz": hz,
            "frames": steps,
            "simulatedElapsedMs": (t - start) * 1000.0,
            "finalOffset": Double(b.c.currentOffset),
            "finalError": 1200.0 - Double(b.c.currentOffset),
            "positionAt50ms": positionsAt[0.05] ?? -1,
            "positionAt100ms": positionsAt[0.10] ?? -1,
            "positionAt200ms": positionsAt[0.20] ?? -1,
            "positionAt350ms": positionsAt[0.35] ?? -1
        ].merging(meta) { $1 })
    }
}

@MainActor
func runMaxOffsetShrink(_ meta: [String: Any]) {
    let b = Bench()
    SettingsStore.shared.scrollSmoothness = 0.75
    b.reset()
    b.c.scrollTo(target: 1200, maxOffset: 20_000, duration: 0.22, initialVelocity: 0, source: .programmatic)
    b.step(6)
    b.c.maxOffset = 100
    var steps = 0
    while b.c.isSpringAnimating && steps < 600 { b.step(); steps += 1 }
    emit("max_offset_shrink_midspring", [
        "maxOffsetAfterShrink": b.c.maxOffset,
        "finalOffset": b.c.currentOffset,
        "exceedsMaxOffsetBy": Double(b.c.currentOffset - b.c.maxOffset),
        "isMovingAfter": b.c.isMoving
    ].merging(meta) { $1 })
}

@MainActor
func runSettleSnapOff(_ meta: [String: Any]) {
    let b = Bench()
    let s = SettingsStore.shared
    s.freezeOnRelease = false
    s.snapToColumn = false
    s.scrollSmoothness = 0.75
    s.trackpadNaturalScroll = false
    b.reset()
    b.gesture(dx: 8, frames: 60)
    let before = b.c.currentOffset
    let velBefore = b.c.currentVelocity
    b.c.settle()
    let immediately = b.c.isMoving
    let springVel = b.c.springState.velocity
    let callbacksBeforeIdle = b.callbacks
    b.step(120)
    emit("settle_snap_disabled", [
        "offsetBeforeSettle": before,
        "currentVelocityBeforeSettle": velBefore,
        "isMovingImmediatelyAfterSettle": immediately,
        "springVelocityAfterSettle": springVel,
        "springIsAtRest": b.c.springState.isAtRest,
        "isMovingAfter1sIdle": b.c.isMoving,
        "callbacksDuring1sIdle": b.callbacks - callbacksBeforeIdle,
        "note": "stale springState.velocity is not cleared by settle() when snapping is off"
    ].merging(meta) { $1 })
}

@MainActor
func runSettleProjection(_ meta: [String: Any]) {
    let b = Bench()
    let s = SettingsStore.shared
    s.freezeOnRelease = false
    s.snapToColumn = true
    s.scrollSmoothness = 0.75
    s.trackpadNaturalScroll = false
    let box = NSMutableDictionary()
    b.c.onSettleRequested = { projected in
        box["projected"] = projected
        box["velocityAtCallback"] = b.c.settleVelocity
    }
    b.reset()
    b.gesture(dx: 8, frames: 60)
    let offset = b.c.currentOffset
    let velocity = b.c.currentVelocity
    b.c.settle()
    let projected = box["projected"] as? CGFloat
    emit("settle_projection", [
        "offset": offset,
        "velocity": velocity,
        "projectedOffset": projected ?? -1,
        "impliedProjectionSeconds": (projected != nil && velocity != 0) ? Double((projected! - offset) / velocity) : 0,
        "settleVelocityAtCallback": box["velocityAtCallback"] ?? -1
    ].merging(meta) { $1 })
}

@MainActor
func runLayoutCost(_ meta: [String: Any]) {
    let engine = LayoutEngine(windowGap: 12, edgeMargins: EdgeMargins(), defaultColumnWidthRatio: 0.5)
    let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    var windows: [WindowId: ManagedWindow] = [:]
    var columns: [WindowColumn] = []
    for i in 0..<24 {
        let w = ManagedWindow(
            id: WindowId(pid: 100, rawId: UInt64(1000 + i)),
            pid: 100, bundleIdentifier: "com.example.app\(i)",
            appName: "App\(i)", title: "Window \(i)",
            frame: CGRect(x: CGFloat(i) * 900, y: 0, width: 880, height: 1000)
        )
        windows[w.id] = w
        columns.append(WindowColumn(windowIds: [w.id], width: 880))
    }
    var samples: [Double] = []
    for iter in 0..<600 {
        let t0 = nowNs()
        _ = engine.computeLayout(
            columns: columns, windows: windows,
            focusedColumnIndex: iter % 24, visibleFrame: screen,
            viewportOffset: CGFloat(iter % 100) * 9.0,
            layoutMode: .scrollStrip, centerMode: .onOverflow,
            edgeMargins: EdgeMargins(), gap: 12,
            isBuiltinDisplay: false, disablePaddingOnBuiltinDisplay: false,
            smartWindowMargins: false, loopMode: false
        )
        samples.append(Double(nowNs() - t0) / 1000.0)
    }
    emit("layout_compute_cost_24_columns", [
        "windows": 24,
        "iterations": samples.count,
        "microseconds": stats(samples),
        "budgetAt120Hz_us": 8333.0
    ].merging(meta) { $1 })
}

@MainActor
func runSnapshotInfo(_ meta: [String: Any]) {
    let s = SettingsStore.shared
    emit("settings_snapshot", [
        "freezeOnRelease": s.freezeOnRelease,
        "snapToColumn": s.snapToColumn,
        "scrollSmoothness": s.scrollSmoothness,
        "scrollSensitivity": s.scrollSensitivity,
        "momentumScrolling": s.momentumScrolling,
        "animationDuration": s.animationDuration,
        "trackpadNaturalScroll": s.trackpadNaturalScroll,
        "scrollTriggerMode": String(describing: s.scrollTriggerMode),
        "note": "reads the current user defaults domain; the wrapper snapshots and restores it"
    ].merging(meta) { $1 })
}

@MainActor
func run() {
    let meta: [String: Any] = [
        "artifact": "libIumeCore.a",
        "buildConfiguration": ProcessInfo.processInfo.environment["IUME_BENCH_CONFIG"] ?? "unknown",
        "harness": "scripts/audit/scroll_bench.swift"
    ]
    runSnapshotInfo(meta)
    runDirect1to1(meta)
    runBursty(meta)
    runSmoothnessTouch(meta)
    runSmoothnessWheel(meta)
    runSpringSettle(meta)
    runSpringSettleRates(meta)
    runMaxOffsetShrink(meta)
    runSettleSnapOff(meta)
    runSettleProjection(meta)
    runLayoutCost(meta)
}

MainActor.assumeIsolated { run() }
