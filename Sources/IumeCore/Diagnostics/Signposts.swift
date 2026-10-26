import Foundation
import os
import CoreGraphics
import ApplicationServices

/// Structured latency distribution snapshot containing percentiles and bucket counts.
public struct LatencyDistribution: Sendable, CustomStringConvertible {
    public let count: Int
    public let minMs: Double
    public let p50Ms: Double
    public let p90Ms: Double
    public let p95Ms: Double
    public let p99Ms: Double
    public let maxMs: Double
    public let avgMs: Double
    public let buckets: [String: Int]

    public init(
        count: Int,
        minMs: Double,
        p50Ms: Double,
        p90Ms: Double,
        p95Ms: Double,
        p99Ms: Double,
        maxMs: Double,
        avgMs: Double,
        buckets: [String: Int]
    ) {
        self.count = count
        self.minMs = minMs
        self.p50Ms = p50Ms
        self.p90Ms = p90Ms
        self.p95Ms = p95Ms
        self.p99Ms = p99Ms
        self.maxMs = maxMs
        self.avgMs = avgMs
        self.buckets = buckets
    }

    public static let zero = LatencyDistribution(
        count: 0,
        minMs: 0,
        p50Ms: 0,
        p90Ms: 0,
        p95Ms: 0,
        p99Ms: 0,
        maxMs: 0,
        avgMs: 0,
        buckets: [:]
    )

    public var description: String {
        "Latency(count: \(count), min: \(String(format: "%.2f", minMs))ms, p50: \(String(format: "%.2f", p50Ms))ms, p90: \(String(format: "%.2f", p90Ms))ms, p95: \(String(format: "%.2f", p95Ms))ms, p99: \(String(format: "%.2f", p99Ms))ms, max: \(String(format: "%.2f", maxMs))ms, avg: \(String(format: "%.2f", avgMs))ms)"
    }
}

/// Comprehensive telemetry snapshot of window manipulation metrics and error counters.
public struct AXMetricsSnapshot: Sendable, CustomStringConvertible {
    public let totalWrites: Int
    public let successfulWrites: Int
    public let failedWrites: Int
    public let timeouts: Int
    public let repairs: Int
    public let coalescedWrites: Int
    public let persistentMismatches: Int
    public let latency: LatencyDistribution
    public let errorsByCode: [Int32: Int]

    public init(
        totalWrites: Int,
        successfulWrites: Int,
        failedWrites: Int,
        timeouts: Int,
        repairs: Int,
        coalescedWrites: Int,
        persistentMismatches: Int,
        latency: LatencyDistribution,
        errorsByCode: [Int32: Int]
    ) {
        self.totalWrites = totalWrites
        self.successfulWrites = successfulWrites
        self.failedWrites = failedWrites
        self.timeouts = timeouts
        self.repairs = repairs
        self.coalescedWrites = coalescedWrites
        self.persistentMismatches = persistentMismatches
        self.latency = latency
        self.errorsByCode = errorsByCode
    }

    public static let zero = AXMetricsSnapshot(
        totalWrites: 0,
        successfulWrites: 0,
        failedWrites: 0,
        timeouts: 0,
        repairs: 0,
        coalescedWrites: 0,
        persistentMismatches: 0,
        latency: .zero,
        errorsByCode: [:]
    )

    public var description: String {
        """
        AXMetricsSnapshot(
            writes: \(totalWrites) (ok: \(successfulWrites), fail: \(failedWrites), timeout: \(timeouts)),
            repairs: \(repairs), coalesced: \(coalescedWrites), persistentMismatches: \(persistentMismatches),
            latency: \(latency)
        )
        """
    }
}

/// Thread-safe in-memory metrics tracker for Accessibility operations.
public final class AXMetricsTracker: @unchecked Sendable {
    private let lock = NSLock()

    private var totalWrites: Int = 0
    private var successfulWrites: Int = 0
    private var failedWrites: Int = 0
    private var timeouts: Int = 0
    private var repairs: Int = 0
    private var coalescedWrites: Int = 0
    private var persistentMismatches: Int = 0
    private var errorsByCode: [Int32: Int] = [:]

    // Latency distribution ring buffer (up to 1024 samples)
    private var samples: [Double] = []
    private let maxSamples: Int = 1024
    private var sampleIndex: Int = 0
    private var isSampleBufferFull: Bool = false

    // Fixed histogram buckets
    private var bucketUnder0_5ms: Int = 0
    private var bucket0_5to1ms: Int = 0
    private var bucket1to2ms: Int = 0
    private var bucket2to5ms: Int = 0
    private var bucket5to10ms: Int = 0
    private var bucket10to20ms: Int = 0
    private var bucket20to50ms: Int = 0
    private var bucketOver50ms: Int = 0

    public init() {
        samples.reserveCapacity(maxSamples)
    }

    public func recordWrite(pid: pid_t, windowId: UInt64, durationMs: Double, error: AXError) {
        lock.lock()
        defer { lock.unlock() }

        totalWrites += 1
        if error == .success {
            successfulWrites += 1
        } else {
            failedWrites += 1
            errorsByCode[error.rawValue, default: 0] += 1
            if error == .cannotComplete || durationMs >= 40.0 {
                timeouts += 1
            }
        }

        // Record sample in circular buffer
        if !isSampleBufferFull {
            if samples.count < maxSamples {
                samples.append(durationMs)
            } else {
                isSampleBufferFull = true
                samples[sampleIndex] = durationMs
                sampleIndex = (sampleIndex + 1) % maxSamples
            }
        } else {
            samples[sampleIndex] = durationMs
            sampleIndex = (sampleIndex + 1) % maxSamples
        }

        // Categorize into histogram bucket
        if durationMs < 0.5 {
            bucketUnder0_5ms += 1
        } else if durationMs < 1.0 {
            bucket0_5to1ms += 1
        } else if durationMs < 2.0 {
            bucket1to2ms += 1
        } else if durationMs < 5.0 {
            bucket2to5ms += 1
        } else if durationMs < 10.0 {
            bucket5to10ms += 1
        } else if durationMs < 20.0 {
            bucket10to20ms += 1
        } else if durationMs < 50.0 {
            bucket20to50ms += 1
        } else {
            bucketOver50ms += 1
        }
    }

    public func recordRepair(pid: pid_t, windowId: UInt64, discrepancy: CGFloat) {
        lock.lock()
        defer { lock.unlock() }
        repairs += 1
    }

    public func recordCoalesced(pid: pid_t, windowId: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        coalescedWrites += 1
    }

    public func recordPersistentMismatch(pid: pid_t, windowId: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        persistentMismatches += 1
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        totalWrites = 0
        successfulWrites = 0
        failedWrites = 0
        timeouts = 0
        repairs = 0
        coalescedWrites = 0
        persistentMismatches = 0
        errorsByCode.removeAll()
        samples.removeAll(keepingCapacity: true)
        sampleIndex = 0
        isSampleBufferFull = false
        bucketUnder0_5ms = 0
        bucket0_5to1ms = 0
        bucket1to2ms = 0
        bucket2to5ms = 0
        bucket5to10ms = 0
        bucket10to20ms = 0
        bucket20to50ms = 0
        bucketOver50ms = 0
    }

    public func latencyDistribution() -> LatencyDistribution {
        lock.lock()
        let count = samples.count
        guard count > 0 else {
            lock.unlock()
            return .zero
        }

        let sorted = samples.sorted()
        let minVal = sorted.first ?? 0
        let maxVal = sorted.last ?? 0
        let sum = sorted.reduce(0, +)
        let avgVal = sum / Double(count)

        func percentile(_ p: Double) -> Double {
            guard count > 1 else { return sorted[0] }
            let rank = p * Double(count - 1)
            let lower = Int(rank)
            let upper = min(lower + 1, count - 1)
            let fraction = rank - Double(lower)
            return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
        }

        let p50 = percentile(0.50)
        let p90 = percentile(0.90)
        let p95 = percentile(0.95)
        let p99 = percentile(0.99)

        let bucketMap: [String: Int] = [
            "<0.5ms": bucketUnder0_5ms,
            "0.5-1.0ms": bucket0_5to1ms,
            "1.0-2.0ms": bucket1to2ms,
            "2.0-5.0ms": bucket2to5ms,
            "5.0-10.0ms": bucket5to10ms,
            "10.0-20.0ms": bucket10to20ms,
            "20.0-50.0ms": bucket20to50ms,
            ">=50.0ms": bucketOver50ms
        ]

        lock.unlock()

        return LatencyDistribution(
            count: count,
            minMs: minVal,
            p50Ms: p50,
            p90Ms: p90,
            p95Ms: p95,
            p99Ms: p99,
            maxMs: maxVal,
            avgMs: avgVal,
            buckets: bucketMap
        )
    }

    public func snapshot() -> AXMetricsSnapshot {
        lock.lock()
        let tw = totalWrites
        let sw = successfulWrites
        let fw = failedWrites
        let to = timeouts
        let rp = repairs
        let cw = coalescedWrites
        let pm = persistentMismatches
        let errs = errorsByCode
        lock.unlock()

        return AXMetricsSnapshot(
            totalWrites: tw,
            successfulWrites: sw,
            failedWrites: fw,
            timeouts: to,
            repairs: rp,
            coalescedWrites: cw,
            persistentMismatches: pm,
            latency: latencyDistribution(),
            errorsByCode: errs
        )
    }
}

/// Lightweight, decoupled bridge forwarding diagnostic anomalies to registered handlers (such as `Diagnostics.shared`)
/// without creating rigid build-time dependencies when compiling files in isolation.
public final class IumeTelemetryBridge: @unchecked Sendable {
    public static let shared = IumeTelemetryBridge()
    private let lock = NSLock()
    private var sinks: [(@Sendable (String, String, String) -> Void)] = []

    public init() {}

    public func registerSink(_ sink: @escaping @Sendable (_ message: String, _ level: String, _ category: String) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        sinks.append(sink)
    }

    public func forward(message: String, level: String = "ERROR", category: String = "AX") {
        lock.lock()
        let currentSinks = sinks
        lock.unlock()
        for sink in currentSinks {
            sink(message, level, category)
        }
    }
}

/// Modern Apple `OSSignposter` signpost provider and AX telemetry engine under subsystem `"com.iume.Iume"`.
public enum IumeSignpost {
    public static let subsystem = "com.iume.Iume"

    // Signposters by category
    public static let scroll = OSSignposter(subsystem: subsystem, category: "Scroll")
    public static let workspace = OSSignposter(subsystem: subsystem, category: "Workspace")
    public static let window = OSSignposter(subsystem: subsystem, category: "Window")
    public static let pointsOfInterest = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)

    // Shared metrics engine
    public static let metrics = AXMetricsTracker()

    // MARK: - Interval 1: scroll.frame
    /// Measures time inside display link tick / frame computation.
    public static func beginScrollFrame() -> OSSignpostIntervalState {
        scroll.beginInterval("scroll.frame")
    }

    public static func endScrollFrame(_ state: OSSignpostIntervalState) {
        scroll.endInterval("scroll.frame", state)
    }

    public static func withScrollFrame<T>(_ work: () throws -> T) rethrows -> T {
        let state = beginScrollFrame()
        defer { endScrollFrame(state) }
        return try work()
    }

    // MARK: - Interval 2: workspace.apply
    /// Measures `applyPhysicalWindowPositions` execution duration.
    public static func beginWorkspaceApply() -> OSSignpostIntervalState {
        workspace.beginInterval("workspace.apply")
    }

    public static func endWorkspaceApply(_ state: OSSignpostIntervalState) {
        workspace.endInterval("workspace.apply", state)
    }

    public static func withWorkspaceApply<T>(_ work: () throws -> T) rethrows -> T {
        let state = beginWorkspaceApply()
        defer { endWorkspaceApply(state) }
        return try work()
    }

    // MARK: - Interval 3: window.axWrite
    /// Begins measuring an individual window write operation (duration, pid, windowId).
    public static func beginWindowAXWrite(pid: pid_t, windowId: UInt64) -> (OSSignpostID, OSSignpostIntervalState) {
        let id = window.makeSignpostID()
        let state = window.beginInterval(
            "window.axWrite",
            id: id,
            "pid: \(pid, privacy: .public), windowId: \(windowId, privacy: .public)"
        )
        return (id, state)
    }

    public static func endWindowAXWrite(
        id: OSSignpostID,
        state: OSSignpostIntervalState,
        pid: pid_t,
        windowId: UInt64,
        status: AXError,
        durationMs: Double
    ) {
        window.endInterval(
            "window.axWrite",
            state,
            "pid: \(pid, privacy: .public), windowId: \(windowId, privacy: .public), status: \(status.rawValue, privacy: .public), durationMs: \(durationMs, privacy: .public)"
        )

        // Emit corresponding event point
        emitAXWrite(pid: pid, windowId: windowId, error: status, durationMs: durationMs)

        // Record metrics
        metrics.recordWrite(pid: pid, windowId: windowId, durationMs: durationMs, error: status)

        // Forward non-success AX errors and timeouts into Diagnostics ring buffer without spamming normal ticks
        if status != .success {
            if status == .cannotComplete || durationMs >= 40.0 {
                IumeTelemetryBridge.shared.forward(
                    message: "AX write timeout (\(String(format: "%.2f", durationMs))ms) for PID \(pid), window \(windowId): AXError(\(status.rawValue))",
                    level: "ERROR",
                    category: "Error"
                )
            } else {
                IumeTelemetryBridge.shared.forward(
                    message: "AX write failed for PID \(pid), window \(windowId): AXError(\(status.rawValue))",
                    level: "ERROR",
                    category: "Error"
                )
            }
        }
    }

    // MARK: - Interval 4: window.settle
    /// Begins measuring the entire settle pass until verification completes.
    public static func beginWindowSettle(pid: pid_t, windowId: UInt64) -> (OSSignpostID, OSSignpostIntervalState) {
        let id = window.makeSignpostID()
        let state = window.beginInterval(
            "window.settle",
            id: id,
            "pid: \(pid, privacy: .public), windowId: \(windowId, privacy: .public)"
        )
        return (id, state)
    }

    public static func endWindowSettle(
        id: OSSignpostID,
        state: OSSignpostIntervalState,
        pid: pid_t,
        windowId: UInt64,
        success: Bool
    ) {
        window.endInterval(
            "window.settle",
            state,
            "pid: \(pid, privacy: .public), windowId: \(windowId, privacy: .public), success: \(success, privacy: .public)"
        )
    }

    // MARK: - Event Point 1: window.axWrite
    /// Records success/failure (`AXError`), pid, windowId for an AX write operation.
    public static func emitAXWrite(pid: pid_t, windowId: UInt64, error: AXError, durationMs: Double? = nil) {
        let durStr = durationMs.map { String(format: " (%.2fms)", $0) } ?? ""
        window.emitEvent(
            "window.axWrite",
            "pid: \(pid, privacy: .public), windowId: \(windowId, privacy: .public), error: \(error.rawValue, privacy: .public)\(durStr)"
        )
    }

    // MARK: - Event Point 2: window.axRepair
    /// Records when a coordinate discrepancy > 1.0 pt triggered a repair write.
    public static func emitAXRepair(
        pid: pid_t,
        windowId: UInt64,
        discrepancy: CGFloat,
        expected: CGRect,
        actual: CGRect
    ) {
        window.emitEvent(
            "window.axRepair",
            "pid: \(pid, privacy: .public), windowId: \(windowId, privacy: .public), discrepancy: \(discrepancy, privacy: .public)pt, expected: \(expected.debugDescription, privacy: .public), actual: \(actual.debugDescription, privacy: .public)"
        )
        metrics.recordRepair(pid: pid, windowId: windowId, discrepancy: discrepancy)

        // Forward to ring buffer only on significant discrepancy (> 1.0 pt)
        if discrepancy > 1.0 {
            IumeTelemetryBridge.shared.forward(
                message: "AX repair triggered: discrepancy \(String(format: "%.1f", discrepancy))pt for PID \(pid), window \(windowId)",
                level: "WARN",
                category: "AX"
            )
        }
    }

    // MARK: - Event Point 3: window.coalesced
    /// Records when a newer desired frame superseded an in-flight write.
    public static func emitCoalesced(pid: pid_t, windowId: UInt64, superseded: String) {
        window.emitEvent(
            "window.coalesced",
            "pid: \(pid, privacy: .public), windowId: \(windowId, privacy: .public), superseded: \(superseded, privacy: .public)"
        )
        metrics.recordCoalesced(pid: pid, windowId: windowId)
    }

    // MARK: - Anomaly Reporting: Persistent Mismatch
    /// Records when a post-repair verification check fails (persistent mismatch).
    public static func recordPersistentMismatch(
        pid: pid_t,
        windowId: UInt64,
        expected: CGRect,
        actual: CGRect
    ) {
        metrics.recordPersistentMismatch(pid: pid, windowId: windowId)
        IumeTelemetryBridge.shared.forward(
            message: "Persistent AX frame mismatch for PID \(pid), window \(windowId): expected \(expected), actual \(actual)",
            level: "ERROR",
            category: "Error"
        )
    }

    // MARK: - Anomaly Reporting: Generic Error / Timeout
    public static func recordAXError(pid: pid_t, windowId: UInt64, error: AXError, operation: String) {
        metrics.recordWrite(pid: pid, windowId: windowId, durationMs: 0, error: error)
        IumeTelemetryBridge.shared.forward(
            message: "AX \(operation) error for PID \(pid), window \(windowId): AXError(\(error.rawValue))",
            level: "ERROR",
            category: "Error"
        )
    }

    // MARK: - CustomStringConvertible Overloads (accepts WindowId or any identifier)
    @inline(__always)
    public static func beginWindowAXWrite<W: CustomStringConvertible>(pid: pid_t, windowId: W) -> (OSSignpostID, OSSignpostIntervalState) {
        let rawId = (windowId as? UInt64) ?? UInt64(pid)
        return beginWindowAXWrite(pid: pid, windowId: rawId)
    }

    @inline(__always)
    public static func endWindowAXWrite<W: CustomStringConvertible>(
        id: OSSignpostID,
        state: OSSignpostIntervalState,
        pid: pid_t,
        windowId: W,
        status: AXError,
        durationMs: Double
    ) {
        let rawId = (windowId as? UInt64) ?? UInt64(pid)
        endWindowAXWrite(id: id, state: state, pid: pid, windowId: rawId, status: status, durationMs: durationMs)
    }

    @inline(__always)
    public static func beginWindowSettle<W: CustomStringConvertible>(pid: pid_t, windowId: W) -> (OSSignpostID, OSSignpostIntervalState) {
        let rawId = (windowId as? UInt64) ?? UInt64(pid)
        return beginWindowSettle(pid: pid, windowId: rawId)
    }

    @inline(__always)
    public static func endWindowSettle<W: CustomStringConvertible>(
        id: OSSignpostID,
        state: OSSignpostIntervalState,
        pid: pid_t,
        windowId: W,
        success: Bool
    ) {
        let rawId = (windowId as? UInt64) ?? UInt64(pid)
        endWindowSettle(id: id, state: state, pid: pid, windowId: rawId, success: success)
    }

    @inline(__always)
    public static func emitAXWrite<W: CustomStringConvertible>(pid: pid_t, windowId: W, error: AXError, durationMs: Double? = nil) {
        let rawId = (windowId as? UInt64) ?? UInt64(pid)
        emitAXWrite(pid: pid, windowId: rawId, error: error, durationMs: durationMs)
    }

    @inline(__always)
    public static func emitAXRepair<W: CustomStringConvertible>(
        pid: pid_t,
        windowId: W,
        discrepancy: CGFloat,
        expected: CGRect,
        actual: CGRect
    ) {
        let rawId = (windowId as? UInt64) ?? UInt64(pid)
        emitAXRepair(pid: pid, windowId: rawId, discrepancy: discrepancy, expected: expected, actual: actual)
    }

    @inline(__always)
    public static func emitCoalesced<W: CustomStringConvertible>(pid: pid_t, windowId: W, superseded: String) {
        let rawId = (windowId as? UInt64) ?? UInt64(pid)
        emitCoalesced(pid: pid, windowId: rawId, superseded: superseded)
    }

    @inline(__always)
    public static func recordPersistentMismatch<W: CustomStringConvertible>(
        pid: pid_t,
        windowId: W,
        expected: CGRect,
        actual: CGRect
    ) {
        let rawId = (windowId as? UInt64) ?? UInt64(pid)
        recordPersistentMismatch(pid: pid, windowId: rawId, expected: expected, actual: actual)
    }

    @inline(__always)
    public static func recordAXError<W: CustomStringConvertible>(pid: pid_t, windowId: W, error: AXError, operation: String) {
        let rawId = (windowId as? UInt64) ?? UInt64(pid)
        recordAXError(pid: pid, windowId: rawId, error: error, operation: operation)
    }
}
