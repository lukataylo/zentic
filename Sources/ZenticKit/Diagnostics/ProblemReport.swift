import Foundation

/// One problem report, kept on this Mac.
///
/// `text` is the whole report: what the viewer shows is exactly what Copy,
/// Save and Email hand over, so nobody sends something they could not read.
public struct ProblemReport: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Zentic's own record of a run that ended without quitting, with what
        /// it was doing and the crash log macOS wrote, if there is one.
        case unexpectedQuit
        case crash
        case hang
        case cpuUsage
        case diskWrites

        public var title: String {
            switch self {
            case .unexpectedQuit: "Unexpected Quit"
            case .crash: "Crash"
            case .hang: "Hang"
            case .cpuUsage: "High CPU Use"
            case .diskWrites: "Excessive Disk Writes"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var date: Date
    /// One line for a list: "EXC_BAD_ACCESS (SIGSEGV)", "Not responding for 4 sec".
    public var summary: String
    public var text: String
    /// The process the report is about, when known: one crash can arrive
    /// twice, as macOS's crash log and later as a MetricKit diagnostic.
    public var processID: Int?

    public init(
        id: UUID = UUID(), kind: Kind, date: Date, summary: String, text: String, processID: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.date = date
        self.summary = summary
        self.text = text
        self.processID = processID
    }

    /// Whether this says nothing `existing` does not: the same problem in the
    /// same process, or a crash that an unexpected-quit report already covers
    /// with macOS's own (symbolicated) log and what Zentic was doing.
    public func isCovered(by existing: ProblemReport) -> Bool {
        guard let processID, processID == existing.processID else { return false }
        return kind == existing.kind || (kind == .crash && existing.kind == .unexpectedQuit)
    }

    /// A name for the report as a file: "Zentic Crash 2026-10-04 10.41.txt".
    public var fileName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let stamp = formatter.string(from: date)
        return "Zentic \(kind.title) \(stamp).txt"
    }

    /// Lays a report out the same way whatever its source: a header of
    /// facts, then titled sections.
    static func compose(
        kind: Kind, date: Date, summary: String, facts: [(String, String)], sections: [(String, String)]
    ) -> String {
        let header = [("Report", kind.title), ("Date", timestamp(date)), ("Summary", summary)] + facts
        let width = header.map(\.0.count).max() ?? 0
        var text = header.map { $0.0.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.1 }
            .joined(separator: "\n")
        for (title, body) in sections where !body.isEmpty {
            text += "\n\n\(title)\n\(String(repeating: "-", count: title.count))\n\(body)"
        }
        return text + "\n"
    }

    /// Unambiguous across time zones, for whoever reads it later.
    public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        var style = Date.ISO8601FormatStyle(timeZone: timeZone)
        style = style.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false)
            .timeSeparator(.colon).timeZone(separator: .colon)
        return date.formatted(style)
    }

    static var thisMac: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    // MARK: - An unexpected quit

    /// The report written at launch after the previous run ended without
    /// quitting: what Zentic was doing, and macOS's crash log if it wrote one.
    public static func unexpectedQuit(
        previousRun: Breadcrumb?, crashLog: SystemCrashLog?, now: Date = .now
    ) -> ProblemReport {
        let date = crashLog?.date ?? previousRun?.events.last?.date ?? now
        let summary = crashLog?.summary ?? "No crash log: force quit, stopped by macOS or lost power"
        var facts = [("App", previousRun.map { "Zentic \($0.appVersion)" } ?? "Zentic"), ("System", thisMac)]
        if let crashLog { facts.append(("Crash log", crashLog.fileName)) }
        let text = compose(
            kind: .unexpectedQuit, date: date, summary: summary, facts: facts,
            sections: [
                ("What Zentic was doing", previousRun?.rendered() ?? "Nothing was recorded before it quit."),
                ("Crashed thread", crashLog?.crashedThread ?? ""),
                ("Crash log from macOS", crashLog?.contents ?? ""),
            ])
        return ProblemReport(
            kind: .unexpectedQuit, date: date, summary: summary, text: text, processID: crashLog?.processID)
    }
}
