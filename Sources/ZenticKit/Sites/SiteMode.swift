import Foundation

/// How much Zentic changes a site. One choice per site, remembered.
///
/// The four are ordered by how far the page moves from what the publisher
/// shipped, but they are a picker, not a slider: Custom is not "more Minimal",
/// it is the user's own version, built on whichever base suits it.
public enum SiteMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The site exactly as it shipped. Nothing blocked, nothing injected that
    /// changes the page.
    case original
    /// Ads and trackers blocked, cookie walls answered. The site's own design.
    case clean
    /// Clean, then the site's own styling replaced by Zentic's calm design —
    /// every element kept and still live.
    case minimal
    /// The user's own version of the site, described in words and kept.
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original: "Original"
        case .clean: "Clean"
        case .minimal: "Minimal"
        case .custom: "Custom"
        }
    }

    public var subtitle: String {
        switch self {
        case .original: "Exactly as the site ships it"
        case .clean: "No ads, trackers or cookie banners"
        case .minimal: "A calm redesign, every element kept"
        case .custom: "Your own version, described in words"
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .original: "doc.richtext"
        case .clean: "shield.lefthalf.filled"
        case .minimal: "circle.lefthalf.filled"
        case .custom: "wand.and.sparkles"
        }
    }

    /// Whether content blocking is attached. Only Original turns it off.
    ///
    /// This is the one part of a mode that cannot change on a live page:
    /// WebKit applies rule lists as a document loads, so moving across this
    /// line reloads.
    public var blocks: Bool { self != .original }
}

/// The base a custom version is built on.
public enum CustomBase: String, Codable, Sendable, CaseIterable {
    /// The site's own styling, with the custom stylesheet layered over it.
    case clean
    /// Zentic's minimal design, with the custom stylesheet layered over it.
    case minimal
}

/// A site's own version: what the user asked for, and the stylesheet a model
/// wrote for it. Replayed on every visit with no model call.
public struct CustomVersion: Codable, Sendable, Hashable {
    public var base: CustomBase
    /// Sanitized before it is ever stored. See ``CSSSanitizer``.
    public var css: String
    /// Selectors hidden outright.
    public var hide: [String]
    /// One sentence from the model saying what changed.
    public var summary: String
    /// Every instruction the user gave, oldest first. A refinement is sent with
    /// its history so the model revises rather than starts over.
    public var prompts: [String]
    public var updatedAt: Date
    /// What the version did to the page it was kept on, for noticing when the
    /// site changes under it (``DriftTracker``). Nil until first measured —
    /// versions kept before re-checking existed are measured on next visit.
    public var baseline: CustomBaseline?

    public init(
        base: CustomBase,
        css: String,
        hide: [String],
        summary: String,
        prompts: [String],
        updatedAt: Date = Date(),
        baseline: CustomBaseline? = nil
    ) {
        self.base = base
        self.css = CSSSanitizer.sanitize(css)
        self.hide = CSSSanitizer.sanitizeSelectors(hide)
        self.summary = summary
        self.prompts = prompts
        self.updatedAt = updatedAt
        self.baseline = baseline
    }
}

extension CustomVersion {
    private enum CodingKeys: String, CodingKey { case base, css, hide, summary, prompts, updatedAt, baseline }

    /// Decoding goes through the sanitizing initializer, so a version stored by
    /// an older, weaker sanitizer is cleaned on load rather than replayed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            base: try c.decode(CustomBase.self, forKey: .base),
            css: try c.decode(String.self, forKey: .css),
            hide: try c.decodeIfPresent([String].self, forKey: .hide) ?? [],
            summary: try c.decodeIfPresent(String.self, forKey: .summary) ?? "",
            prompts: try c.decodeIfPresent([String].self, forKey: .prompts) ?? [],
            updatedAt: try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(),
            // A baseline that no longer decodes is re-measured, never a reason
            // to lose the version it belongs to.
            baseline: (try? c.decodeIfPresent(CustomBaseline.self, forKey: .baseline)) ?? nil)
    }
}

/// What the user chose for one site.
public struct SiteSettings: Codable, Sendable, Hashable {
    public var mode: SiteMode
    public var custom: CustomVersion?

    public init(mode: SiteMode, custom: CustomVersion? = nil) {
        self.mode = mode
        self.custom = custom
    }
}

public enum SiteKey {
    /// The key a site's settings live under: the host, lowercased, without a
    /// leading `www.`. `www.apple.com` and `apple.com` are one site to a person.
    ///
    /// The in-page script derives the same key from `location.hostname`, so the
    /// two must agree — see `InPageScript.bootstrap`.
    public static func `for`(_ url: URL?) -> String? {
        guard let host = url?.host(percentEncoded: false), !host.isEmpty else { return nil }
        return self.for(host: host)
    }

    /// The same key, from a host alone. Everything that names a site by its
    /// host — a saved password's origin, the address bar, an extension's site
    /// pattern — goes through here, so they all agree on what one site is.
    public static func `for`(host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A web page with a host: what may come in from a link or a saved bookmark.
    public static func isWebPage(_ url: URL?) -> Bool {
        isWeb(url) && url?.host?.isEmpty == false
    }

    /// Only web pages have a mode. `about:blank`, `file:` and friends are shown
    /// as they are.
    public static func isWeb(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
