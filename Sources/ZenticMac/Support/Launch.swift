import Darwin
import Foundation

/// Launch timing.
///
/// Exists because "launches fast" is the kind of claim that rots silently. The
/// figure that matters is the one the user perceives — from the moment the process
/// was created to the moment there is a window to look at — so the clock starts at
/// the kernel's process-start time rather than at `main`, which would hide dyld and
/// framework loading. On this app that gap is not small, and reporting only the
/// part we control would flatter the result.
enum Launch {
    /// Set by `main.swift` before anything else.
    nonisolated(unsafe) static var mainEntered = Date()

    /// Process creation time, from the kernel.
    static var processStart: Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return Date(
            timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        )
    }

    /// Milliseconds from process creation to now.
    static var sinceProcessStartMs: Double? {
        processStart.map { Date().timeIntervalSince($0) * 1_000 }
    }

    /// Milliseconds from `main` to now — the part of launch this code owns.
    static var sinceMainMs: Double {
        Date().timeIntervalSince(mainEntered) * 1_000
    }

    /// Reports a launch milestone, with both clocks.
    static func mark(_ stage: String) {
        let total = sinceProcessStartMs.map { String(format: "%.0fms", $0) } ?? "?"
        trace("launch", String(format: "%@ · %@ since exec · %.0fms since main", stage, total, sinceMainMs))
    }
}
