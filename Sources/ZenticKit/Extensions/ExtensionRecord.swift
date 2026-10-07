import Foundation

/// What Zentic remembers about one Safari Web Extension: where it came from,
/// whether it is on, and what the user has allowed it to do.
///
/// WebKit keeps none of this. A `WKWebExtensionContext` starts every launch
/// with no grants and a fresh storage identity, so all of it is saved here and
/// handed back each time the extension loads.
public struct ExtensionRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Source: Codable, Sendable, Equatable, Hashable {
        /// Inside an installed app. Keyed by the extension's bundle identifier,
        /// so updating or moving the app keeps the record; `path` is only
        /// where it was last found.
        case app(bundleID: String, path: String)
        /// A folder chosen with Load Unpacked Extension.
        case folder(path: String)

        public var key: String {
            switch self {
            case .app(let bundleID, _): "app:\(bundleID)"
            case .folder(let path): "folder:\(path)"
            }
        }

        public var path: String {
            switch self {
            case .app(_, let path), .folder(let path): path
            }
        }
    }

    public var source: Source
    /// The context's `uniqueIdentifier`. WebKit files the extension's storage
    /// under it: a new one each launch would wipe the extension's data —
    /// a password manager's login, say — on every relaunch.
    public var storageID: String
    public var isEnabled: Bool
    public var allowsPrivateWindows: Bool
    public var grants: ExtensionGrants

    public var id: String { source.key }

    public init(
        source: Source, storageID: String = UUID().uuidString, isEnabled: Bool = false,
        allowsPrivateWindows: Bool = false, grants: ExtensionGrants = ExtensionGrants()
    ) {
        self.source = source
        self.storageID = storageID
        self.isEnabled = isEnabled
        self.allowsPrivateWindows = allowsPrivateWindows
        self.grants = grants
    }
}

/// An extension's answers from the user, each with the moment it lapses
/// (`Date.distantFuture` for never). Keyed by WebKit's own strings: API
/// permissions such as `tabs`, and match patterns such as `*://*.example.com/*`.
public struct ExtensionGrants: Codable, Sendable, Equatable {
    public var permissions: [String: Date] = [:]
    public var sites: [String: Date] = [:]
    public var deniedPermissions: [String: Date] = [:]
    public var deniedSites: [String: Date] = [:]

    public init(
        permissions: [String: Date] = [:], sites: [String: Date] = [:],
        deniedPermissions: [String: Date] = [:], deniedSites: [String: Date] = [:]
    ) {
        self.permissions = permissions
        self.sites = sites
        self.deniedPermissions = deniedPermissions
        self.deniedSites = deniedSites
    }

    /// Without the answers that have run out. An "allow for one day" restored
    /// a week later would otherwise come back as a standing grant.
    public func live(at now: Date) -> ExtensionGrants {
        func keep(_ grants: [String: Date]) -> [String: Date] { grants.filter { $0.value > now } }
        return ExtensionGrants(
            permissions: keep(permissions), sites: keep(sites),
            deniedPermissions: keep(deniedPermissions), deniedSites: keep(deniedSites))
    }
}

/// How far an extension reaches into websites, as Settings shows it.
///
/// Derived from the granted patterns each time, never stored beside them, so
/// the picker and what WebKit enforces cannot disagree.
public enum SiteAccess: Equatable, Sendable {
    /// It asks for no websites at all.
    case none
    /// Everywhere it asked for.
    case allSites
    /// Only on these sites (perhaps none yet), and on a page when the user
    /// clicks its button there.
    case whenClicked(sites: [String])

    public init(requested: Set<String>, granted: Set<String>) {
        if requested.isEmpty {
            self = .none
        } else if requested.isSubset(of: granted) {
            self = .allSites
        } else {
            self = .whenClicked(sites: Set(granted.compactMap(SitePattern.site(of:))).sorted())
        }
    }
}

/// Match patterns for single sites, the unit people think in when they allow
/// an extension somewhere.
public enum SitePattern {
    /// The pattern covering a site and its subdomains, from whatever the user
    /// typed: a host or a whole URL, with or without a scheme or `www.`. Nil
    /// for anything that is not plausibly a web host.
    public static func forSite(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let withScheme = text.contains("://") ? text : "https://\(text)"
        guard let url = URL(string: withScheme), ["http", "https"].contains(url.scheme ?? ""),
            let found = url.host(), !found.isEmpty
        else { return nil }
        let host = SiteKey.for(host: found)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard host.unicodeScalars.allSatisfy(allowed.contains), !host.hasPrefix("."), !host.hasSuffix("."),
            !host.contains("..")
        else { return nil }
        // An address or a bare machine name has no subdomains to include, and
        // `*.` in front of an IP is not a valid pattern.
        let isAddress = host.split(separator: ".").allSatisfy { $0.allSatisfy(\.isNumber) }
        if isAddress || !host.contains(".") {
            guard host == "localhost" || (isAddress && host.split(separator: ".").count == 4) else { return nil }
            return "*://\(host)/*"
        }
        return "*://*.\(host)/*"
    }

    /// The one site a pattern names, for listing it — nil for a pattern that
    /// spans every host or is not about websites.
    public static func site(of pattern: String) -> String? {
        guard let schemeEnd = pattern.range(of: "://") else { return nil }
        let scheme = pattern[..<schemeEnd.lowerBound]
        guard ["*", "http", "https"].contains(scheme) else { return nil }
        let rest = pattern[schemeEnd.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        var host = String(rest[..<slash])
        if host.hasPrefix("*.") { host.removeFirst(2) }
        guard !host.isEmpty, !host.contains("*") else { return nil }
        return host
    }
}
