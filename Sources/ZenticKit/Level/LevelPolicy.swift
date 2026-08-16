import Foundation

/// What a site's level is resolved from.
///
/// A struct rather than a pile of arguments so the resolution stays a pure
/// function of declared inputs: everything that can move the answer is visible
/// here, and a test can hold all of it still.
public struct SiteLevelInputs: Sendable, Hashable {
    /// The user's choice for this origin, if they made one.
    public var preference: SitePreference
    /// The archetype last observed here. Nil means this origin has never been
    /// extracted — a genuinely different state from "extracted, and it was an app".
    public var archetype: Archetype?
    /// Whether fidelity-sensitive content has been seen at this origin.
    public var isFidelitySensitive: Bool
    /// The global rewrite opt-in. Off by default (invariant 6).
    public var isRewriteEnabled: Bool

    public init(
        preference: SitePreference = .auto,
        archetype: Archetype? = nil,
        isFidelitySensitive: Bool = false,
        isRewriteEnabled: Bool = false
    ) {
        self.preference = preference
        self.archetype = archetype
        self.isFidelitySensitive = isFidelitySensitive
        self.isRewriteEnabled = isRewriteEnabled
    }
}

/// What the user asked for on a site, if anything.
///
/// Three states rather than two because one site is not one kind of page. A
/// registrar's front door is marketing and its blog is prose; pinning the origin
/// to either is wrong half the time, so `auto` — resolved per page — has to be a
/// first-class answer rather than merely the absence of a choice.
public enum SitePreference: Codable, Sendable, Hashable {
    /// Follow the page. The default.
    case auto
    /// Always this level here, whatever the page turns out to be.
    case pinned(PageLevel)
    /// Follow the page, but never above this. "Block ads here, never restructure
    /// it" is a common and otherwise inexpressible intent.
    case ceiling(PageLevel)
}

/// A level and the answer it would have had with no override.
///
/// Returned as a pair because the caller needs both to draw the control, and
/// deriving them separately means two fetches on a path that runs on every title
/// change, favicon and reveal.
public struct LevelResolution: Sendable, Hashable {
    public var level: PageLevel
    public var automatic: PageLevel

    public init(level: PageLevel, automatic: PageLevel) {
        self.level = level
        self.automatic = automatic
    }
}

public enum LevelPolicy {

    /// The level a page should load at.
    public static func resolve(_ inputs: SiteLevelInputs) -> PageLevel {
        let automatic = defaultLevel(
            archetype: inputs.archetype,
            isFidelitySensitive: inputs.isFidelitySensitive
        )

        let chosen: PageLevel =
            switch inputs.preference {
            case .auto: automatic
            case .pinned(let level): level
            case .ceiling(let cap): min(automatic, cap)
            }

        // The one clamp applied to an explicit choice. Everything else the user
        // asks for is honoured — including `.original` on an article and `.reader`
        // on an app, because the bundle still gets to decline the latter and a
        // control that quietly ignores you is worse than one that tries and reports.
        return chosen == .rewritten && !inputs.isRewriteEnabled ? .reader : chosen
    }

    /// Where `auto` lands, before any per-site preference.
    public static func defaultLevel(
        archetype: Archetype?,
        isFidelitySensitive: Bool
    ) -> PageLevel {
        // Never restructured (invariant 2), but blocking and cookie walls are
        // perfectly safe on a mail client — declining to restructure an app should
        // not also mean serving its ads.
        if archetype == .app { return .calm }

        // A feed or a thread has no layout of its own until M4. Rendering one as an
        // article yields a list of orphaned sentences.
        if archetype == .feed || archetype == .thread { return .calm }

        // Nil — an origin never extracted here — resolves to `.reader`, and that is
        // deliberate rather than optimistic. Every page already boots at
        // `.restructured` and the *bundle* declines: app detection, confidence,
        // `minWordCount`. In this system failing open means letting the bundle
        // decide, so booting an unknown origin at `.calm` would not be cautious —
        // it would render the first article on every new site raw, and the reader
        // would only ever appear on the second visit.
        //
        // `instantOrigins` stays orthogonal to this: it decides whether to *hide*,
        // not what to do once we have looked.
        return .reader
    }
}
