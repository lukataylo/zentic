import Foundation

/// Something a site can ask to do that the user decides, per site.
///
/// The first three are WebKit's to enforce and Zentic's to answer. The rest
/// are Zentic's own policies: WebKit would otherwise open every pop-up, start
/// every download, apply one autoplay rule to every site and leave handing a
/// link to another app (`mailto:`, `zoommtg:`, `smb:`) to the browser.
public enum SitePermission: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable, Identifiable {
    case camera, microphone, location, popups, autoplay, downloads, otherApps
    public var id: String { rawValue }
}

/// A user's answer for one permission on one site.
///
/// For autoplay the three map to Safari's settings rather than to a prompt:
/// `allow` lets everything play, `ask` makes media with sound wait for a click
/// (the page "asks" by needing one) and `deny` holds back even silent video.
public enum PermissionDecision: String, CaseIterable, Codable, Sendable, Identifiable {
    case ask, allow, deny
    public var id: String { rawValue }
}

/// What to do with one request, once the stored decision and the request's
/// circumstances are both known.
public enum PermissionOutcome: Sendable, Equatable {
    case grant, deny, prompt
}

/// Every site's permission decisions, plus what other websites get.
///
/// Unlike `SiteBook`, a site set to the same value as the default is kept:
/// a decision about the camera is consent, and an explicit "Ask" must not
/// quietly become "Allow" because the default changed later.
public struct PermissionBook: Codable, Sendable, Hashable {
    /// Only what differs from ``builtInDefault(_:)`` — a later Zentic can
    /// change a built-in default without every old file pinning the old one.
    public private(set) var defaults: [SitePermission: PermissionDecision]
    public private(set) var sites: [String: [SitePermission: PermissionDecision]]

    public init(
        defaults: [SitePermission: PermissionDecision] = [:],
        sites: [String: [SitePermission: PermissionDecision]] = [:]
    ) {
        self.defaults = defaults
        self.sites = sites
    }

    /// Safari's defaults: everything asks, pop-ups opened without a click are
    /// held back with a notice, and media with sound waits for a click.
    public static func builtInDefault(_ permission: SitePermission) -> PermissionDecision { .ask }

    public func defaultDecision(for permission: SitePermission) -> PermissionDecision {
        defaults[permission] ?? Self.builtInDefault(permission)
    }

    public mutating func setDefault(_ decision: PermissionDecision, for permission: SitePermission) {
        defaults[permission] = decision == Self.builtInDefault(permission) ? nil : decision
    }

    /// The site's own decision, if it has one.
    public func decision(_ permission: SitePermission, explicitlyFor site: String?) -> PermissionDecision? {
        site.flatMap { sites[$0]?[permission] }
    }

    /// What applies to `site`: its own decision, else the default.
    public func decision(_ permission: SitePermission, for site: String?) -> PermissionDecision {
        decision(permission, explicitlyFor: site) ?? defaultDecision(for: permission)
    }

    /// Record a decision; nil removes the site's own one.
    public mutating func set(_ decision: PermissionDecision?, _ permission: SitePermission, for site: String) {
        var entry = sites[site] ?? [:]
        entry[permission] = decision
        sites[site] = entry.isEmpty ? nil : entry
    }

    /// Forget everything decided for a site.
    public mutating func forget(_ site: String) { sites[site] = nil }

    /// The sites with their own decision for `permission`, sorted by name.
    public func sites(for permission: SitePermission) -> [(site: String, decision: PermissionDecision)] {
        sites.compactMap { site, entry in entry[permission].map { (site, $0) } }.sorted { $0.site < $1.site }
    }

    /// This book with a private window's own decisions laid over it.
    public func overlaying(_ overrides: [String: [SitePermission: PermissionDecision]]) -> PermissionBook {
        var book = self
        for (site, entry) in overrides {
            book.sites[site, default: [:]].merge(entry) { _, new in new }
        }
        return book
    }

    /// How to answer a request for `permission` from `site`.
    ///
    /// `userInitiated` matters only to pop-ups: one opened by a click always
    /// opens, as in every browser, or "Sign in with…" buttons would break on
    /// every site with pop-ups blocked. The policy is about the ones that
    /// open by themselves.
    public func outcome(_ permission: SitePermission, for site: String?, userInitiated: Bool = false)
        -> PermissionOutcome
    {
        if permission == .popups && userInitiated { return .grant }
        switch decision(permission, for: site) {
        case .allow: return .grant
        case .deny: return .deny
        case .ask: return .prompt
        }
    }

    // A file written by a later Zentic may name permissions this one has never
    // heard of. Decoding them strictly would make `JSONFile` set the whole file
    // aside and lose every decision; dropping only the unknown ones keeps the rest.
    private enum CodingKeys: String, CodingKey { case defaults, sites }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawDefaults = try c.decodeIfPresent([String: String].self, forKey: .defaults) ?? [:]
        let rawSites = try c.decodeIfPresent([String: [String: String]].self, forKey: .sites) ?? [:]
        defaults = Self.known(rawDefaults)
        sites = rawSites.compactMapValues { entry in
            let known = Self.known(entry)
            return known.isEmpty ? nil : known
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(defaults, forKey: .defaults)
        try c.encode(sites, forKey: .sites)
    }

    private static func known(_ raw: [String: String]) -> [SitePermission: PermissionDecision] {
        var result: [SitePermission: PermissionDecision] = [:]
        for (key, value) in raw {
            guard let permission = SitePermission(rawValue: key), let decision = PermissionDecision(rawValue: value)
            else { continue }
            result[permission] = decision
        }
        return result
    }
}

/// Whether a pop-up was opened by the person rather than by the page.
///
/// WebKit does not tell its client whether `window.open` came from a user
/// gesture, so Zentic notes when the last click or key press aimed at the
/// page arrived. One second is the window a page gets to act on a click:
/// long enough for a handler that awaits a little work, short enough that a
/// timer-driven pop-up does not ride on a click from a minute ago.
public enum UserGesture {
    public static let window: TimeInterval = 1

    /// Whether input at `input` lets the page open a pop-up at `now`. Input
    /// from before the current document began was aimed at the one before:
    /// a pop-up fired at load must not ride on the ⌘R or click that loaded it.
    public static func counts(inputAt input: TimeInterval, now: TimeInterval, documentStart: TimeInterval) -> Bool {
        input > documentStart && now >= input && now - input <= window
    }
}
