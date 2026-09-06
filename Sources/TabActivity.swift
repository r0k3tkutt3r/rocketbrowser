import Cocoa
import WebKit
import Darwin

/// What each open tab actually costs: CPU burned since the last sample, and the memory
/// footprint of the web content process rendering it.
///
/// The figures come from the kernel (`proc_pid_rusage` on the tab's own web process),
/// not from anything the page says about itself, so a page cannot flatter its own
/// numbers. There is no public API for a web view's process id, so
/// `_webProcessIdentifier` is read through KVC behind a `responds(to:)` guard — an OS
/// that stops answering costs the reading, not the tab.
///
/// Bytes transferred are deliberately absent. WebKit zeroes `transferSize` on every
/// cross-origin resource whose server does not send `Timing-Allow-Origin`, which is most
/// of what a heavy page pulls, and there is no per-view network counter underneath it. A
/// column reading 0.2 MB for a tab that fetched 12 MB is worse than no column.
enum TabActivity {

    /// How often the sampler re-reads every web process. A CPU *rate* needs two samples,
    /// so this runs on a timer rather than when someone opens the menu: a menu opened
    /// cold would otherwise have nothing to subtract from.
    static let sampleInterval: TimeInterval = 30

    struct Reading {
        let cpuPercent: Double
        let memoryBytes: UInt64
    }

    /// One core fully busy reads as 100%.
    static func cpuPercent(previous: UInt64, current: UInt64, elapsed: TimeInterval) -> Double {
        // The counters are unsigned and a pid can be reused by an unrelated process,
        // which then reports *less* CPU than the sample before it. That has to read as
        // zero rather than wrap around to 1.8e19%.
        guard elapsed > 0, current > previous else { return 0 }
        return Double(current - previous) / (elapsed * 1_000_000_000) * 100
    }

    static func processID(of webView: WKWebView) -> pid_t? {
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard webView.responds(to: selector),
              let pid = webView.value(forKey: "_webProcessIdentifier") as? pid_t,
              pid > 0 else { return nil }
        return pid
    }

    /// Cumulative CPU time and current footprint for a process, straight from the kernel.
    static func kernelUsage(pid: pid_t) -> (cpuNanos: UInt64, memoryBytes: UInt64)? {
        guard pid > 0 else { return nil }
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard result == 0 else { return nil }
        return (info.ri_user_time + info.ri_system_time, info.ri_phys_footprint)
    }

    private static var lastSample: [pid_t: (nanos: UInt64, at: Date)] = [:]
    private static var readings: [pid_t: Reading] = [:]

    static func refresh(pids: [pid_t], now: Date = Date()) {
        var fresh: [pid_t: Reading] = [:]
        var stamps: [pid_t: (nanos: UInt64, at: Date)] = [:]
        for pid in Set(pids) {
            guard let usage = kernelUsage(pid: pid) else { continue }
            let percent = lastSample[pid].map {
                cpuPercent(previous: $0.nanos, current: usage.cpuNanos,
                           elapsed: now.timeIntervalSince($0.at))
            } ?? 0
            fresh[pid] = Reading(cpuPercent: percent, memoryBytes: usage.memoryBytes)
            stamps[pid] = (usage.cpuNanos, now)
        }
        // Replacing rather than merging is what prunes the processes of closed tabs.
        readings = fresh
        lastSample = stamps
    }

    static func reading(for pid: pid_t) -> Reading? { readings[pid] }

    static func describe(_ reading: Reading?) -> String {
        guard let reading else { return "not measured yet" }
        let memory = ByteCountFormatter.string(fromByteCount: Int64(reading.memoryBytes),
                                               countStyle: .memory)
        return String(format: "%.1f%% CPU · %@", reading.cpuPercent, memory)
    }
}
