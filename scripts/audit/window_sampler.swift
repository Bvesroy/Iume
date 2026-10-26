// window_sampler.swift — standalone CGWindowList motion + CPU/RSS sampler.
//
// Build (no SwiftPM, no project):
//   swiftc -O -parse-as-library window_sampler.swift -o .build/window_sampler
//
// Run:
//   .build/window_sampler --out /tmp/iume.csv --duration 5 --hz 20
//   .build/window_sampler --pid 1234 --out /tmp/iume.csv --duration 60 --hz 30
//
// Emits two files:
//   --out            t_monotonic_s,window_number,pid,owner,bounds_x,bounds_y,bounds_w,bounds_h,layer
//   --out + .csv     ...cpu.csv :: t_monotonic_s,pid,cpu_percent,rss_kib
//
// Semantics that matter for interpretation (also written into the CSV header):
//   * CGWindowListCopyWindowInfo returns *committed composited* window geometry,
//     not present/vsync timing. A move the app issues mid-frame is only visible
//     once the WindowServer has committed it, so every observed delta is
//     quantized to (at best) one display refresh.
//   * t_monotonic_s is seconds since sampler start, from mach_absolute_time
//     (DispatchTime.uptimeNanoseconds). Monotonic, not wall clock.
//   * CPU% from libproc is the instantaneous delta of cumulative user+system CPU
//     time over the sampling interval; the `ps` fallback reports ps's decayed
//     average instead (flagged in the header when used).

import Foundation
import AppKit
import CoreGraphics
import Darwin

enum CSV {
    static let window = "t_monotonic_s,window_number,pid,owner,bounds_x,bounds_y,bounds_w,bounds_h,layer"
    static let cpu = "t_monotonic_s,pid,cpu_percent,rss_kib"
}

// MARK: - Clock

@inline(__always) func nowSeconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000.0
}

// MARK: - Options

struct Options {
    var pid: Int32? = nil
    var duration: Double = 10.0
    var hz: Double = 20.0
    var out: String = "window_samples.csv"

    static let usage = """
    usage: window_sampler --out <csv> [--duration <s>] [--hz <rate>] [--pid <pid>]

      --pid       target process id for CPU/RSS sampling.
                  Default: the running app named "Iume", if any.
      --duration  seconds to record (default 10)
      --hz        window sampling rate in Hz, 1...240 (default 20)
      --out       window CSV path (default ./window_samples.csv);
                  CPU CSV is written next to it as <out>.csv
    """

    static func parse(_ args: [String]) -> Options? {
        var o = Options()
        var i = 1
        while i < args.count {
            let arg = args[i]
            func value() -> String? {
                if let eq = arg.firstIndex(of: "=") {   // --flag=value
                    return String(arg[arg.index(after: eq)...])
                }
                guard i + 1 < args.count else { return nil }   // --flag value
                i += 1
                return args[i]
            }
            let flag = String(arg.split(separator: "=", maxSplits: 1).first ?? Substring(arg))
            switch flag {
            case "--pid":
                guard let v = value(), let p = Int32(v), p > 0 else { return nil }
                o.pid = p
            case "--duration":
                guard let v = value(), let d = Double(v), d > 0 else { return nil }
                o.duration = d
            case "--hz":
                guard let v = value(), let h = Double(v), h >= 1, h <= 240 else { return nil }
                o.hz = h
            case "--out":
                guard let v = value(), !v.isEmpty else { return nil }
                o.out = v
            case "-h", "--help":
                return nil
            default:
                FileHandle.standardError.write(Data("unknown argument: \(arg)\n".utf8))
                return nil
            }
            i += 1
        }
        return o
    }
}

// MARK: - Helpers

func csvField(_ s: String) -> String {
    if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return s
}

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    if sorted.count == 1 { return sorted[0] }
    let rank = p / 100.0 * Double(sorted.count - 1)
    let lo = Int(floor(rank)), hi = Int(ceil(rank))
    if lo == hi { return sorted[lo] }
    let f = rank - Double(lo)
    return sorted[lo] * (1 - f) + sorted[hi] * f
}

final class StopFlag {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

struct WindowRow {
    let t: Double
    let number: Int
    let pid: Int32
    let owner: String
    let x: Double, y: Double, w: Double, h: Double
    let layer: Int
}

// MARK: - Display description

func displayDescription() -> [String] {
    var lines: [String] = []
    if let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) {
        // Swift-exposed form of CGDisplayModeCopyPixelEncoding (the C function was
        // obsoleted in Swift 3; same IOKit pixel-encoding string).
        let enc: String = mode.pixelEncoding.map { $0 as String } ?? "unavailable"
        lines.append("# display_id=\(CGMainDisplayID()) mode=\(mode.width)x\(mode.height)"
            + " pixel=\(mode.pixelWidth)x\(mode.pixelHeight)"
            + " pixel_encoding=\(enc) mode_refresh_hz=\(String(format: "%.3f", mode.refreshRate))")
        if mode.refreshRate <= 0 {
            lines.append("# note=CGDisplayMode.refreshRate is 0 for this mode"
                + " (variable refresh / external display); prefer the NSScreen value")
        }
    } else {
        lines.append("# display_id=unavailable")
    }
    let maxFPS = NSScreen.main?.maximumFramesPerSecond ?? 0
    lines.append("# nsscreen_max_fps=\(maxFPS) nsscreen_count=\(NSScreen.screens.count)")
    if maxFPS == 0 {
        lines.append("# note=NSScreen.maximumFramesPerSecond unavailable; CG mode refresh is authoritative")
    }
    return lines
}

// MARK: - Window sampling

func sampleWindows(at t: Double) -> (rows: [WindowRow], costMs: Double, totalWindows: Int) {
    let t0 = DispatchTime.now().uptimeNanoseconds
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
        return ([], Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000.0, 0)
    }
    var rows: [WindowRow] = []
    rows.reserveCapacity(raw.count)
    for info in raw {
        // Invisible (alpha 0) windows are composited but never seen; drop them.
        if let a = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, a <= 0.001 { continue }
        guard let b = info[kCGWindowBounds as String] as? NSDictionary,
              let x = (b["X"] as? NSNumber)?.doubleValue,
              let y = (b["Y"] as? NSNumber)?.doubleValue,
              let w = (b["Width"] as? NSNumber)?.doubleValue,
              let h = (b["Height"] as? NSNumber)?.doubleValue,
              w > 0, h > 0
        else { continue }
        let num = (info[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0
        let pid = Int32((info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0)
        let owner = (info[kCGWindowOwnerName as String] as? String) ?? "(pid \(pid))"
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        rows.append(WindowRow(t: t, number: num, pid: pid, owner: owner,
                              x: x, y: y, w: w, h: h, layer: layer))
    }
    rows.sort { ($0.pid, $0.number) < ($1.pid, $1.number) }
    let cost = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000.0
    return (rows, cost, raw.count)
}

// MARK: - Process CPU / RSS

typealias ProcPidRusageFn = @convention(c) (Int32, Int32, UnsafeMutableRawPointer) -> Int32

final class ProcSampler {
    let pid: Int32
    private let rusageFn: ProcPidRusageFn?
    private var prevCPUNs: UInt64?
    private var prevT: Double?
    private(set) var usingLibproc = false

    // rusage_info_v0 offsets (stable ABI in <sys/resource.h>):
    //   [0..16)  ri_uuid
    //   16       ri_user_time      (ns)
    //   24       ri_system_time    (ns)
    //   64       ri_resident_size  (bytes)
    //   72       ri_phys_footprint (bytes)
    init(pid: Int32) {
        self.pid = pid
        guard let h = dlopen("/usr/lib/libproc.dylib", RTLD_NOW),
              let sym = dlsym(h, "proc_pid_rusage") else {
            rusageFn = nil
            return
        }
        rusageFn = unsafeBitCast(sym, to: ProcPidRusageFn.self)
        usingLibproc = true
    }

    func sample(at t: Double) -> (Double?, Int?) {
        if let fn = rusageFn {
            var buf = [UInt8](repeating: 0, count: 128)
            let rc = buf.withUnsafeMutableBytes { raw -> Int32 in
                fn(pid, 0 /* RUSAGE_INFO_V0 */, raw.baseAddress!)
            }
            if rc == 0 {
                let userNs: UInt64 = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt64.self) }
                let sysNs: UInt64 = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt64.self) }
                let footprint: UInt64 = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 72, as: UInt64.self) }
                let resident: UInt64 = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 64, as: UInt64.self) }
                let cpuNs = userNs &+ sysNs
                var cpu: Double? = nil
                if let pc = prevCPUNs, let pt = prevT, t > pt, cpuNs >= pc {
                    cpu = Double(cpuNs &- pc) / (1_000_000_000.0 * (t - pt)) * 100.0
                }
                prevCPUNs = cpuNs
                prevT = t
                let bytes = footprint > 0 ? footprint : resident
                return (cpu, Int(bytes / 1024))
            }
        }
        return sampleViaPS()
    }

    private func sampleViaPS() -> (Double?, Int?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "pcpu=,rss=", "-p", String(pid)]
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (nil, nil) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return (nil, nil) }
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 2 else { return (nil, nil) }
        return (Double(parts[0]), Int(parts[1]))
    }
}

// MARK: - Target resolution

func explicitOwner(_ pid: Int32) -> String? {
    NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }?.localizedName
}

func resolveTargetPid(_ explicit: Int32?) -> (pid: Int32, owner: String) {
    if let p = explicit { return (p, explicitOwner(p) ?? "(pid \(p))") }
    for a in NSWorkspace.shared.runningApplications
    where (a.localizedName == "Iume") || ((a.bundleIdentifier ?? "").lowercased().contains("iume")) {
        return (a.processIdentifier, a.localizedName ?? "Iume")
    }
    // Fallback: an on-screen window owned by something called Iume.
    if let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                            kCGNullWindowID) as? [[String: Any]] {
        for info in raw where (info[kCGWindowOwnerName as String] as? String) == "Iume" {
            if let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value {
                return (pid, "Iume")
            }
        }
    }
    return (0, "(none)")
}

// MARK: - Main

@main
struct WindowSamplerMain {
    static func main() {
        guard let opts = Options.parse(CommandLine.arguments) else {
            FileHandle.standardError.write(Data((Options.usage + "\n").utf8))
            exit(2)
        }

        let fm = FileManager.default
        let outURL = URL(fileURLWithPath: opts.out)
        try? fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cpuURL = URL(fileURLWithPath: opts.out + ".csv")
        try? fm.removeItem(at: outURL)
        try? fm.removeItem(at: cpuURL)
        guard fm.createFile(atPath: outURL.path, contents: nil),
              fm.createFile(atPath: cpuURL.path, contents: nil),
              let winFH = try? FileHandle(forWritingTo: outURL),
              let cpuFH = try? FileHandle(forWritingTo: cpuURL) else {
            FileHandle.standardError.write(Data("cannot create output files at \(outURL.path)\n".utf8))
            exit(1)
        }
        defer { try? winFH.close(); try? cpuFH.close() }

        let t0 = nowSeconds()
        let (targetPid, targetOwner) = resolveTargetPid(opts.pid)
        let proc = targetPid > 0 ? ProcSampler(pid: targetPid) : nil
        let cpuSource = proc?.usingLibproc == true ? "proc_pid_rusage(RUSAGE_INFO_V0)" : "ps -o pcpu=,rss="

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var header: [String] = [
            "# window_sampler v1 (scripts/audit/window_sampler.swift)",
            "# start_iso8601=\(iso.string(from: Date()))",
            "# target_pid=\(targetPid) target_owner=\(csvField(targetOwner))",
            "# sampling_hz=\(opts.hz) requested_duration_s=\(opts.duration)",
            "# columns=" + CSV.window,
            "# caveat=CGWindowListCopyWindowInfo reports committed/composited window state,"
                + " not vsync or present timing; observed deltas are quantized to display refresh"
                + " and floored by sampler wakeup jitter plus per-sample call cost.",
            "# units=bounds in Quartz global points, origin top-left, y down;"
                + " t in seconds since start (monotonic).",
        ]
        header.append(contentsOf: displayDescription())
        winFH.write(Data((header.joined(separator: "\n") + "\n" + CSV.window + "\n").utf8))
        cpuFH.write(Data((
            "# cpu_sampler interval_ms=250 pid=\(targetPid) source=\(cpuSource)\n"
            + "# cpu_percent=" + (proc?.usingLibproc == true
                ? "instantaneous delta of cumulative user+system CPU ns over the interval"
                : "ps %cpu (decayed recent average, not instantaneous)")
            + "\n# rss_kib=" + (proc?.usingLibproc == true ? "ri_phys_footprint" : "ps rss")
            + "\n" + CSV.cpu + "\n").utf8))

        if targetPid == 0 {
            FileHandle.standardError.write(Data("warning: no target pid (pass --pid); CPU CSV will have no rows\n".utf8))
        }

        // ---- CPU timer: independent queue, does not block window sampling ----
        let stop = StopFlag()
        let cpuQ = DispatchQueue(label: "window_sampler.cpu")
        let timer = DispatchSource.makeTimerSource(queue: cpuQ)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(5))
        timer.setEventHandler {
            guard let proc = proc, !stop.isSet else { return }
            let t = nowSeconds()
            let (cpu, rss) = proc.sample(at: t)
            let cpuStr = cpu.map { String(format: "%.2f", $0) } ?? ""
            let rssStr = rss.map(String.init) ?? ""
            let line = String(format: "%.6f,%d,", t - t0, proc.pid) + cpuStr + "," + rssStr + "\n"
            cpuFH.write(Data(line.utf8))
        }
        timer.resume()

        // ---- Window sampling loop ----
        let interval = 1.0 / opts.hz
        var nextDeadline = t0
        var costs: [Double] = []
        var sampleTimes: [Double] = []
        var rowsWritten = 0
        var totalSampledWindows = 0
        var overruns = 0

        while nowSeconds() - t0 < opts.duration {
            let t = nowSeconds() - t0
            let (rows, cost, total) = sampleWindows(at: t)
            costs.append(cost)
            totalSampledWindows += total
            sampleTimes.append(t)

            var buf = ""
            buf.reserveCapacity(rows.count * 72)
            for r in rows {
                buf += String(format: "%.6f,%d,%d,", r.t, r.number, Int(r.pid))
                buf += csvField(r.owner)
                buf += String(format: ",%.2f,%.2f,%.2f,%.2f,%d\n", r.x, r.y, r.w, r.h, r.layer)
            }
            if !buf.isEmpty { winFH.write(Data(buf.utf8)); rowsWritten += rows.count }

            nextDeadline += interval
            let slack = nextDeadline - nowSeconds()
            if slack > 0 {
                Thread.sleep(forTimeInterval: slack)
            } else {
                overruns += 1
                nextDeadline = nowSeconds()   // never burst-catch-up: that would distort intervals
            }
        }

        stop.set()
        timer.cancel()
        cpuQ.sync {}   // drain in-flight CPU writes before closing

        // ---- Trailer: measured cost/interval stats (analyze.py reads these) ----
        let sortedCosts = costs.sorted()
        var intervals: [Double] = []
        if sampleTimes.count > 1 {
            for i in 1..<sampleTimes.count { intervals.append(sampleTimes[i] - sampleTimes[i - 1]) }
        }
        intervals.sort()
        var trailer = String(
            format: "# trailer samples=%d rows=%d windows_per_sample_mean=%.1f"
                + " sample_call_cost_ms_p50=%.3f sample_call_cost_ms_p95=%.3f sample_call_cost_ms_max=%.3f"
                + " interval_ms_p50=%.3f interval_ms_p95=%.3f interval_ms_max=%.3f"
                + " deadline_overruns=%d cpu_source=",
            sampleTimes.count, rowsWritten,
            sampleTimes.isEmpty ? 0 : Double(totalSampledWindows) / Double(sampleTimes.count),
            percentile(sortedCosts, 50), percentile(sortedCosts, 95), sortedCosts.last ?? 0,
            percentile(intervals, 50) * 1000, percentile(intervals, 95) * 1000,
            (intervals.last ?? 0) * 1000, overruns)
        trailer += (proc?.usingLibproc == true ? "libproc" : "ps") + "\n"
        winFH.write(Data(trailer.utf8))
        winFH.synchronizeFile()
        cpuFH.synchronizeFile()

        let achieved = sampleTimes.count > 1
            ? Double(sampleTimes.count - 1) / (sampleTimes.last! - sampleTimes[0]) : 0
        print("wrote \(outURL.path) (\(rowsWritten) rows, \(sampleTimes.count) samples, ~\(String(format: "%.1f", achieved)) Hz actual)")
        print("wrote \(cpuURL.path) (CPU/RSS every 250 ms; target pid \(targetPid) \(targetOwner); source \(cpuSource))")
        print("sample call cost p50/p95/max ms: "
            + String(format: "%.3f / %.3f / %.3f",
                     percentile(sortedCosts, 50), percentile(sortedCosts, 95), sortedCosts.last ?? 0))
    }
}
