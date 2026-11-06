import Foundation
import os.signpost

enum Perf {
    static let log = OSLog(subsystem: "com.hazam.filepicker", category: .pointsOfInterest)
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    static func now() -> UInt64 { mach_absolute_time() }

    static func ms(since start: UInt64) -> Double {
        Double((mach_absolute_time() - start) * UInt64(timebase.numer)) / Double(timebase.denom) / 1_000_000
    }

    private static let lock = NSLock()
    private static var recent: [String] = []

    /// Last 200 timing events, newest last, for the debug report.
    static var recentEvents: [String] {
        lock.lock(); defer { lock.unlock() }
        return recent
    }

    static func report(_ label: StaticString, since start: UInt64) {
        let elapsed = ms(since: start)
        os_signpost(.event, log: log, name: label, "%{public}.3f ms", elapsed)
        lock.lock()
        recent.append("\(ISO8601DateFormatter().string(from: Date())) \(label) \(String(format: "%.3f", elapsed)) ms")
        if recent.count > 200 { recent.removeFirst(recent.count - 200) }
        lock.unlock()
        if ProcessInfo.processInfo.environment["FP_PERF"] != nil {
            NSLog("[perf] \(label): \(String(format: "%.3f", elapsed)) ms")
        }
    }
}
