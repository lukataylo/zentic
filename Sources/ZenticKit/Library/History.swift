import Foundation

/// One page in the history: the last time it was visited and how often.
///
/// One entry per URL rather than one per visit. That is what the address bar
/// ranks by, and it keeps a heavy user's history file to a few thousand rows.
/// It also decides how ranges are cleared: see ``HistoryRange``.
public struct HistoryEntry: Codable, Hashable, Sendable {
    public var url: URL { didSet { index() } }
    public var title: String { didSet { index() } }
    public var lastVisit: Date
    public var visits: Int

    // Lowercased once, not on every keystroke of every search.
    public private(set) var searchURL = ""
    public private(set) var searchHost = ""
    public private(set) var searchTitle = ""

    private enum CodingKeys: String, CodingKey { case url, title, lastVisit, visits }

    public init(url: URL, title: String, lastVisit: Date, visits: Int) {
        self.url = url
        self.title = title
        self.lastVisit = lastVisit
        self.visits = visits
        index()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            url: try c.decode(URL.self, forKey: .url), title: try c.decode(String.self, forKey: .title),
            lastVisit: try c.decode(Date.self, forKey: .lastVisit), visits: try c.decode(Int.self, forKey: .visits))
    }

    /// Every word of `query` appears in the title or the address. Words, not
    /// the phrase: "github zentic" should find "zentic · GitHub".
    public func matches(words: [String]) -> Bool {
        words.allSatisfy { searchTitle.contains($0) || searchURL.contains($0) }
    }

    private mutating func index() {
        searchURL = url.absoluteString.lowercased()
        searchHost = URLGuess.displayHost(url).lowercased()
        searchTitle = title.lowercased()
    }
}

/// The spans Clear History offers, as Safari does.
public enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case lastHour, today, todayAndYesterday, all
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lastHour: "Last Hour"
        case .today: "Today"
        case .todayAndYesterday: "Today and Yesterday"
        case .all: "All History"
        }
    }

    /// Entries last visited at or after this are cleared; nil clears all.
    ///
    /// Days are calendar days, not multiples of 24 hours: on the day the clocks
    /// change, "today and yesterday" must still begin at yesterday's midnight.
    ///
    /// A page visited both before and inside the range has one entry, dated
    /// by its last visit, so it goes. Clearing errs toward forgetting: a user
    /// clearing the last hour expects that page gone from the address bar.
    public func start(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .lastHour: now.addingTimeInterval(-3600)
        case .today: calendar.startOfDay(for: now)
        case .todayAndYesterday: calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        case .all: nil
        }
    }

    /// What survives clearing this range.
    public func kept(_ entries: [HistoryEntry], now: Date, calendar: Calendar) -> [HistoryEntry] {
        guard let start = start(now: now, calendar: calendar) else { return [] }
        return entries.filter { $0.lastVisit < start }
    }
}

/// One day's section of the History window.
public struct HistoryDay: Identifiable, Sendable {
    /// Midnight at the start of the day, in the calendar it was grouped by.
    public let day: Date
    /// Most recent first.
    public let entries: [HistoryEntry]
    public var id: Date { day }

    /// `entries` matching `query`, grouped by the day of their last visit,
    /// most recent day first.
    public static func group(_ entries: some Sequence<HistoryEntry>, matching query: String = "", calendar: Calendar)
        -> [HistoryDay]
    {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let matching = words.isEmpty ? Array(entries) : entries.filter { $0.matches(words: words) }
        let byDay = Dictionary(grouping: matching) { calendar.startOfDay(for: $0.lastVisit) }
        return byDay
            .map { HistoryDay(day: $0.key, entries: $0.value.sorted { $0.lastVisit > $1.lastVisit }) }
            .sorted { $0.day > $1.day }
    }
}
