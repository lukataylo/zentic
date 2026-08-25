import Foundation

/// How much Zentic transforms a site. One control, five detents, per origin.
///
/// The three layers used to be reachable only through unrelated controls — a
/// Transformed/Original toggle, a wand button, and nothing at all for blocking —
/// so the user could not answer the one question that matters on any page: how
/// much is this browser changing what I am looking at?
///
/// This is that answer, and it is deliberately **ordered**. Every stop does
/// everything the stop below it does and one thing more, which is what makes a
/// slider an honest control for it. ``ShieldState`` and ``ReaderMode`` become
/// projections of this rather than independently settable: two controls that can
/// disagree are two controls that will.
public enum PageLevel: String, Codable, Sendable, CaseIterable, Comparable {
    /// The site exactly as it shipped. Nothing blocked, nothing dismissed.
    case original
    /// Ads and trackers blocked, and the consent wall they came with dismissed.
    /// The site's own layout, intact.
    case clean
    /// Also the annoyances — interstitials, chum, sticky furniture — hidden rather
    /// than merely blocked.
    case calm
    /// Extracted and re-rendered in Zentic's design system.
    case reader
    /// Also re-voiced by a model. Gated, badged, reversible.
    case rewritten

    public var ordinal: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.ordinal < rhs.ordinal }

    // MARK: - Projections

    /// Which compiled rule lists a tab at this level attaches.
    public var shield: ShieldState {
        switch self {
        case .original: .off
        case .clean: .blockingOnly
        case .calm, .reader, .rewritten: .standard
        }
    }

    /// The strip layer's setting, independent of everything above it.
    ///
    /// Two levels sharing a value here are indistinguishable to WebKit, which is
    /// precisely what makes moving between them free — see ``requiresReload(from:to:)``.
    public var strip: StripAxis {
        switch self {
        case .original: .none
        case .clean: .network
        case .calm, .reader, .rewritten: .cosmetic
        }
    }

    /// Whether the reader may click a consent dialog on the user's behalf.
    ///
    /// From `.clean` up, not from `.calm`. A consent wall is not part of the site's
    /// own layout — it is the tracking-consent apparatus, so it belongs with "ads
    /// and trackers blocked" rather than with the annoyances one stop higher. A
    /// level whose whole promise is that trackers are blocked, which then leaves
    /// the tracking dialog sitting on the page, is drawing the line in a place the
    /// user cannot make sense of.
    ///
    /// `.original` still may not, and that boundary is the one that matters:
    /// dismissing a cookie wall is an action taken in the user's name, and the stop
    /// that promises to change nothing must change nothing.
    ///
    /// Everything Original→Clean newly gains here also moves the strip axis, so
    /// this does not widen ``requiresReload(from:to:)`` — see the test that holds
    /// those two together.
    public var dismissesCookieWalls: Bool { self >= .clean }

    public var readerMode: ReaderMode { self >= .reader ? .restructured : .original }

    /// Whether a rewrite may be *offered*. Invariant 6 still requires the press:
    /// this grants permission, never consent.
    public var allowsRewrite: Bool { self >= .rewritten }

    /// Themes are lossless and reversible, so they carry no ceremony — but there is
    /// nothing of ours to theme until the page is ours to render.
    public var allowsTheme: Bool { self >= .reader }

    // MARK: - Transitions

    /// Whether moving between two levels needs the page reloaded to take effect.
    ///
    /// Exactly the strip delta, and for a mechanical reason: WebKit bakes
    /// `css-display-none` into a document when it loads and never re-evaluates it,
    /// and a request already on the wire cannot be recalled. So changing what is
    /// blocked changes the *next* document, not the one on screen.
    ///
    /// Everything above the strip layer is live. Entering the reader re-runs
    /// extraction against the DOM already in front of the user, and leaving it only
    /// un-hides a document that was never destroyed.
    public static func requiresReload(from old: Self, to new: Self) -> Bool {
        old.strip != new.strip
    }
}

/// The strip layer's three settings, ordered by how much they suppress.
public enum StripAxis: Int, Codable, Sendable, Comparable, CaseIterable {
    case none
    case network
    case cosmetic

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
