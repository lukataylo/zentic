import Foundation

// Sites change; a kept custom version does not. These types decide, from a
// cheap measurement of the page, whether a version still does what it did when
// it was kept — without a model, and without crying wolf: the page a version
// was kept on is rarely the page it is checked on, so a selector finding
// nothing on a different *kind* of page is not yet evidence of anything.

/// One measurement of a custom version on a page. See `web/src/recheck.ts`.
public struct PageCheck: Sendable, Hashable {
    /// Elements each hide selector matches, by selector.
    public var matches: [String: Int]
    public var visibleText: Int
    public var totalText: Int
    public var overflowsX: Bool
    /// Counts of header, nav, main, article, aside, footer and h1.
    public var landmarks: [String: Int]

    public init(
        matches: [String: Int], visibleText: Int, totalText: Int, overflowsX: Bool, landmarks: [String: Int]
    ) {
        self.matches = matches
        self.visibleText = visibleText
        self.totalText = totalText
        self.overflowsX = overflowsX
        self.landmarks = landmarks
    }

    /// From what `zentic.recheck()` hands back to Swift. Nil for anything else.
    public init?(script value: Any?) {
        guard let value = value as? [String: Any],
            let visible = (value["visibleText"] as? NSNumber)?.intValue,
            let total = (value["totalText"] as? NSNumber)?.intValue
        else { return nil }
        func counts(_ key: String) -> [String: Int] {
            (value[key] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
        }
        self.init(
            matches: counts("matches"), visibleText: visible, totalText: total,
            overflowsX: (value["overflowsX"] as? NSNumber)?.boolValue ?? false, landmarks: counts("landmarks"))
    }

    /// Whether this page can stand as the baseline for a version kept before
    /// baselines existed: a real page, with something on it the version
    /// acts on. An error page or a half-loaded shell would otherwise record
    /// that every selector matches nothing — and none would be judged again.
    public func canBeBaseline(for hide: [String]) -> Bool {
        totalText >= Drift.minimumText && (hide.isEmpty || hide.contains { (matches[$0] ?? 0) > 0 })
    }

    /// The share of the page's text left visible. Nil on a page with too
    /// little text for a share to mean anything.
    public var textShare: Double? {
        totalText >= Drift.minimumText ? Double(visibleText) / Double(totalText) : nil
    }
}

/// What a custom version did to the page it was kept on, stored with it.
public struct CustomBaseline: Codable, Sendable, Hashable {
    /// Elements each hide selector matched.
    public var matches: [String: Int]
    /// The share of the page's text the version left visible.
    public var textShare: Double?
    public var overflowsX: Bool
    public var landmarks: [String: Int]

    public init(_ check: PageCheck) {
        matches = check.matches
        textShare = check.textShare
        overflowsX = check.overflowsX
        landmarks = check.landmarks
    }

    /// Whether `landmarks` describe the same kind of page — an article, a
    /// listing, a front page — as the one the version was kept on. Counts are
    /// bucketed (none, a few, many) so two articles with different sidebars
    /// still agree, while an article and a front page full of cards do not.
    public func isSameKind(as landmarks: [String: Int]) -> Bool {
        func bucket(_ n: Int) -> Int { n <= 0 ? 0 : n < 5 ? 1 : 2 }
        let names = Set(self.landmarks.keys).union(landmarks.keys)
        return names.allSatisfy { bucket(self.landmarks[$0] ?? 0) == bucket(landmarks[$0] ?? 0) }
    }
}

/// How a kept version has drifted from what it did when kept.
public struct Drift: Sendable, Hashable {
    /// Hide selectors that found something when the version was kept and now
    /// find nothing, in the version's order.
    public var lost: [String]
    /// How many of the version's hide selectors are judged at all: those that
    /// found something when it was kept.
    public var changes: Int
    /// The visible share of the page's text, when kept and now — set only
    /// when it fell sharply.
    public var hiddenText: TextShares?
    /// The page scrolls sideways, and did not when the version was kept.
    public var scrollsSideways: Bool

    public struct TextShares: Sendable, Hashable {
        public var kept: Double
        public var now: Double
    }

    public init(lost: [String], changes: Int, hiddenText: TextShares? = nil, scrollsSideways: Bool = false) {
        self.lost = lost
        self.changes = changes
        self.hiddenText = hiddenText
        self.scrollsSideways = scrollsSideways
    }

    /// Below this many characters of text a page is too sparse to judge by share.
    public static let minimumText = 500
    /// Visible text falling below this fraction of what it was is a drop.
    public static let textDrop = 0.5
    /// Checks of the same kind of page a selector must miss on before it
    /// counts as lost — and that the page must newly scroll sideways on. Not
    /// one: an A/B test, or a page with its own wide table, would cry wolf.
    public static let missesOnSameKind = 2
    /// Pages of a different kind a selector must miss on, all of them distinct,
    /// before it counts as lost. One kind of page lacking a sidebar says
    /// nothing; three different pages lacking it is a redesign.
    public static let missesOnOtherPages = 3
    /// A site is checked at most this often. Drift is slow; a check costs a
    /// layout pass.
    public static let checkInterval: TimeInterval = 180

    /// Plain sentences, most telling first.
    public var reasons: [String] {
        var reasons: [String] = []
        if !lost.isEmpty {
            reasons.append(
                changes == 1
                    ? "Its change no longer matches this site’s layout"
                    : "\(lost.count) of \(changes) changes no longer match this site’s layout")
        }
        if hiddenText != nil { reasons.append("It hides much more of the page than when you kept it") }
        if scrollsSideways { reasons.append("The page now scrolls sideways") }
        return reasons
    }

    /// What broke, for the model asked to repair the version.
    public var problem: String {
        var parts: [String] = []
        if !lost.isEmpty {
            parts.append("these hide selectors no longer match anything on the page: \(lost.joined(separator: ", "))")
        }
        if let hiddenText {
            parts.append(
                "only \(Int(hiddenText.now * 100))% of the page's text is visible, against \(Int(hiddenText.kept * 100))% when it was kept")
        }
        if scrollsSideways { parts.append("the page now scrolls sideways") }
        return parts.joined(separator: "; ")
    }
}

/// One kept version's checks over time, for one site.
///
/// A selector is lost once it has missed on `Drift.missesOnSameKind` checks of
/// the kind of page the version was kept on, or on `Drift.missesOnOtherPages`
/// distinct pages of other kinds, without being found on any in between.
///
/// Only a selector a check has found is judged. The baseline is measured at
/// Keep, seconds or minutes into the page's life; a check runs as the page
/// first idles. A newsletter modal on a timer, a chat launcher or a lazily
/// inserted ad matched at Keep and is not there yet when checked — every
/// time — so its misses would be the moment, not drift.
///
/// Text share is judged on each check alone; new sideways scrolling, like a
/// selector, on `Drift.missesOnSameKind` checks of the kept kind of page in a
/// row, so a page with its own wide table does not raise it. A page with too
/// little text to be a real one — an error page, a bot challenge — is no
/// evidence at all.
public struct DriftTracker: Sendable {
    public let baseline: CustomBaseline
    private let judged: [String]
    /// Judged selectors some check has found: the only ones whose misses count.
    private var seen: Set<String> = []
    private var lost: Set<String> = []
    private var misses: [String: Misses] = [:]
    /// Checks of the kept kind of page in a row that newly scrolled sideways.
    private var sideways = 0

    private struct Misses: Sendable {
        var sameKind = 0
        var otherPages: Set<String> = []
    }

    public init(hide: [String], baseline: CustomBaseline) {
        self.baseline = baseline
        judged = hide.filter { (baseline.matches[$0] ?? 0) > 0 }
    }

    /// Fold in a check of the page at `path`. Nil while the version holds up.
    public mutating func record(_ check: PageCheck, path: String) -> Drift? {
        var drift = Drift(lost: [], changes: judged.count)
        if check.totalText >= Drift.minimumText {
            let sameKind = baseline.isSameKind(as: check.landmarks)
            for selector in judged {
                if (check.matches[selector] ?? 0) > 0 {
                    seen.insert(selector)
                    lost.remove(selector)
                    misses[selector] = nil
                } else if seen.contains(selector), !lost.contains(selector) {
                    // Counted only until lost, so evidence never grows past the thresholds.
                    var missed = misses[selector] ?? Misses()
                    if sameKind { missed.sameKind += 1 } else { missed.otherPages.insert(path) }
                    if missed.sameKind >= Drift.missesOnSameKind || missed.otherPages.count >= Drift.missesOnOtherPages {
                        lost.insert(selector)
                        misses[selector] = nil
                    } else {
                        misses[selector] = missed
                    }
                }
            }
            // Text share only compares like with like: a front page of cards
            // and an article never left the same share of their text visible.
            if sameKind, let kept = baseline.textShare, let now = check.textShare, now < kept * Drift.textDrop {
                drift.hiddenText = .init(kept: kept, now: now)
            }
            // Only the kept kind of page can say the version made it overflow.
            if sameKind { sideways = check.overflowsX && !baseline.overflowsX ? sideways + 1 : 0 }
        }
        drift.scrollsSideways = sideways >= Drift.missesOnSameKind
        drift.lost = judged.filter(lost.contains)
        return drift.reasons.isEmpty ? nil : drift
    }
}

extension CustomVersion {
    /// Whether two versions change the page in the same way. A new baseline
    /// is a measurement, not a change: re-applying over it would drop a
    /// preview in progress in another tab for nothing.
    public static func sameDesign(_ a: CustomVersion?, _ b: CustomVersion?) -> Bool {
        var a = a, b = b
        a?.baseline = nil
        b?.baseline = nil
        return a == b
    }
}
