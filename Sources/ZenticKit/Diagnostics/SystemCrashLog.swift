import Foundation

/// A crash log macOS wrote for Zentic (`~/Library/Logs/DiagnosticReports/*.ips`).
///
/// macOS writes one for every crash, already symbolicated, whether or not
/// MetricKit later delivers its own diagnostic — so after an unexpected quit
/// this is the most useful thing to look at. Read locally, never uploaded.
public struct SystemCrashLog: Equatable, Sendable {
    public var fileName: String
    public var date: Date
    /// "EXC_BAD_ACCESS (SIGSEGV)".
    public var summary: String
    /// The thread that crashed, one frame per line, after any message the
    /// runtime left ("Fatal error: Index out of range").
    public var crashedThread: String
    /// The log as macOS wrote it, for anyone who wants to open it in Console.
    public var contents: String
    public var processID: Int?

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports")
    }

    /// The newest crash log for `processName` written at or after `since`
    /// (the launch of the run that quit): older ones belong to other runs.
    public static func newest(
        for processName: String, since: Date, in directory: URL = directory,
        symbolicate: (String, UInt64) -> String? = Symbolicator.symbol
    ) -> SystemCrashLog? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys))
        else { return nil }
        let candidates = files
            .filter { $0.lastPathComponent.hasPrefix(processName + "-") && $0.pathExtension == "ips" }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: keys).contentModificationDate, date >= since
                else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
        for (url, _) in candidates {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let log = parse(contents, fileName: url.lastPathComponent, symbolicate: symbolicate) { return log }
        }
        return nil
    }

    /// An `.ips` file is a one-line JSON header, then a JSON body. Only crash
    /// logs (bug type 309) are read; anything else is not ours to interpret.
    public static func parse(
        _ contents: String, fileName: String, symbolicate: (String, UInt64) -> String?
    ) -> SystemCrashLog? {
        guard let newline = contents.firstIndex(of: "\n"),
            let header = json(contents[..<newline]),
            header["bug_type"] as? String == "309",
            let body = json(contents[contents.index(after: newline)...])
        else { return nil }

        let exception = body["exception"] as? [String: Any]
        let type = exception?["type"] as? String ?? "Unknown exception"
        let summary = (exception?["signal"] as? String).map { "\(type) (\($0))" } ?? type

        var lines: [String] = []
        // Application-specific information: where a Swift runtime trap says why.
        if let asi = body["asi"] as? [String: [String]] {
            lines += asi.keys.sorted().flatMap { asi[$0] ?? [] }
            if !lines.isEmpty { lines.append("") }
        }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = body["faultingThread"] as? Int ?? threads.firstIndex { $0["triggered"] as? Bool == true } ?? 0
        if threads.indices.contains(faulting) {
            let thread = threads[faulting]
            let images = body["usedImages"] as? [[String: Any]] ?? []
            lines.append("Thread \(faulting)" + ((thread["queue"] as? String).map { " (\($0))" } ?? ""))
            let frames = thread["frames"] as? [[String: Any]] ?? []
            for (index, frame) in frames.enumerated() {
                let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil }
                let offset = (frame["imageOffset"] as? NSNumber)?.uint64Value ?? 0
                let symbol =
                    (frame["symbol"] as? String).map { name in
                        "\(name) + \((frame["symbolLocation"] as? NSNumber)?.intValue ?? 0)"
                    }
                    ?? (image?["uuid"] as? String).flatMap { symbolicate($0, offset) }
                    ?? String(format: "0x%llx", offset)
                let source = (frame["sourceFile"] as? String).map { file in
                    " (\(file)" + ((frame["sourceLine"] as? Int).map { ":\($0)" } ?? "") + ")"
                } ?? ""
                lines.append(StackLine.format(index: index, binary: image?["name"] as? String ?? "???", symbol: symbol + source))
            }
        }

        return SystemCrashLog(
            fileName: fileName,
            date: (header["timestamp"] as? String).flatMap(parseTimestamp) ?? .now,
            summary: summary,
            crashedThread: lines.joined(separator: "\n"),
            contents: contents,
            processID: body["pid"] as? Int)
    }

    private static func json(_ text: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// "2026-10-04 10:41:00.00 +0100"
    static func parseTimestamp(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

/// One frame of a stack, laid out the way crash reports have always been,
/// so a developer's eye finds the binary column without looking.
enum StackLine {
    static func format(index: Int, binary: String, symbol: String) -> String {
        let number = String(index).padding(toLength: 4, withPad: " ", startingAt: 0)
        let name = binary.count >= 28 ? binary + " " : binary.padding(toLength: 28, withPad: " ", startingAt: 0)
        return number + name + symbol
    }
}
