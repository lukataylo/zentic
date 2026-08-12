import Darwin
import Foundation

/// This process's physical memory footprint.
///
/// Exists because the M1 memory claim is falsifiable: thirty tabs must not cost
/// thirty web views. `phys_footprint` is the figure Activity Monitor shows, and it
/// is the one that gets a process jetsammed — resident size undercounts compressed
/// pages and so flatters the result.
///
/// Note this is *our* process only. WebKit runs page content in separate
/// `com.apple.WebKit.WebContent` processes, so a full accounting needs those too:
/// `ps -axo rss,comm | grep WebKit`.
enum MemoryProbe {
    static var footprintBytes: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static var footprintDescription: String {
        String(format: "%.1fMB", Double(footprintBytes) / 1_048_576)
    }

    /// WebKit helper processes that already existed when this app started.
    ///
    /// The attribution problem: WebKit runs pages in XPC services whose parent is
    /// launchd, not us, and nothing in their arguments names the client — so a plain
    /// `ps | grep WebKit` counts Safari's processes as ours. Snapshotting the
    /// pre-existing set once and subtracting it gives an exact answer for everything
    /// except another browser *started during our session*, which a development
    /// diagnostic can live with.
    private static let preexistingHelpers: Set<Int32> = Set(helperProcesses().map(\.pid))

    /// Call once at launch, before any web view exists, to fix the baseline.
    static func captureHelperBaseline() {
        _ = preexistingHelpers
    }

    private static func helperProcesses() -> [(pid: Int32, rss: UInt64, name: String)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,rss=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        // Drained before `waitUntilExit`: `ps` output exceeds the pipe buffer, and
        // waiting first deadlocks with the child blocked on a full pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var found: [(Int32, UInt64, String)] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard line.contains("com.apple.WebKit") else { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3,
                let pid = Int32(fields[0]),
                let rss = UInt64(fields[1])
            else { continue }
            let name = fields[2].split(separator: ".").last.map(String.init) ?? "WebKit"
            found.append((pid, rss * 1024, name))
        }
        return found
    }

    /// Resident size of *this app's* WebKit helper processes, plus a count.
    ///
    /// The shell's own footprint is the least interesting number in a browser: the
    /// pages live in `com.apple.WebKit.WebContent`, and a suspension design that
    /// merely moved cost out of our address space would score perfectly while
    /// helping nobody. Shelling out to `ps` is crude, but there is no supported API
    /// for an XPC service's footprint, and this runs only when a diagnostic asks for
    /// it — never on the hot path.
    static func webContentUsage() -> (count: Int, bytes: UInt64) {
        let ours = helperProcesses().filter { !preexistingHelpers.contains($0.pid) }
        return (ours.count, ours.reduce(0) { $0 + $1.rss })
    }

    /// Shell plus WebKit helpers — the figure to compare against another browser.
    static func totalDescription() -> String {
        let web = webContentUsage()
        let total = Double(footprintBytes + web.bytes) / 1_048_576
        return String(
            format: "%.0fMB total (shell %.0fMB + %d WebKit procs %.0fMB)",
            total,
            Double(footprintBytes) / 1_048_576,
            web.count,
            Double(web.bytes) / 1_048_576
        )
    }
}
