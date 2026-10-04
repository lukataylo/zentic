import Foundation

/// What the app was doing just before it last stopped: a few counts and the
/// last handful of actions, kept in memory and written with the unclean-exit
/// marker (see `LaunchGuard`), so a crash that leaves no other trace still
/// says something about how it happened.
///
/// Actions are fixed phrases chosen by the app ("Closed a tab"), never a URL,
/// a title or anything typed — a report is something a person may email.
/// Private windows record nothing.
public struct Breadcrumb: Codable, Equatable, Sendable {
    public struct Event: Codable, Equatable, Sendable {
        public var date: Date
        public var action: String
        /// The same action in a row (a run of closed tabs) is one line.
        public var times = 1
    }

    /// Enough to see the lead-up; a report is read by a person, not mined.
    public static let eventLimit = 12

    public var appVersion: String
    public var launched: Date
    public var windows = 0
    public var tabs = 0
    /// Tabs with a live web view; the rest are suspended.
    public var liveTabs = 0
    public private(set) var events: [Event] = []

    public init(appVersion: String, launched: Date = .now) {
        self.appVersion = appVersion
        self.launched = launched
    }

    public mutating func note(_ action: String, at date: Date = .now) {
        if events.last?.action == action {
            events[events.count - 1].date = date
            events[events.count - 1].times += 1
            return
        }
        events.append(Event(date: date, action: action))
        if events.count > Self.eventLimit { events.removeFirst(events.count - Self.eventLimit) }
    }

    /// As it appears in a report.
    public func rendered(timeZone: TimeZone = .current) -> String {
        var lines = [
            "Zentic \(appVersion), running since \(ProblemReport.timestamp(launched, timeZone: timeZone))",
            "\(windows) window\(windows == 1 ? "" : "s"), \(tabs) tab\(tabs == 1 ? "" : "s") (\(liveTabs) loaded)",
        ]
        if events.isEmpty {
            lines.append("No actions recorded.")
        } else {
            let time = Date.FormatStyle(date: .omitted, time: .standard, timeZone: timeZone)
                .locale(Locale(identifier: "en_GB"))
            lines.append("")
            lines += events.map { "\($0.date.formatted(time))  \($0.action)\($0.times > 1 ? " ×\($0.times)" : "")" }
        }
        return lines.joined(separator: "\n")
    }
}
