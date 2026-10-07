import Foundation

/// Where a password belongs: a scheme, host and port — the page's origin.
///
/// A saved password is filled only into a page of exactly this origin.
/// `accounts.example.com` and `example.com` are different origins, and so are
/// `http://` and `https://` of the same host: a password typed into one has
/// never been shown to the other, and filling it there would be the first time.
public struct LoginOrigin: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// `https` or `http`.
    public let scheme: String
    /// Lowercased.
    public let host: String
    /// Nil for the scheme's default port.
    public let port: Int?

    public init?(scheme: String, host: String, port: Int?) {
        let scheme = scheme.lowercased()
        let host = host.lowercased()
        guard scheme == "https" || scheme == "http", !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        // WebKit reports a default port as 0; a URL may spell it out.
        let isDefault = port == nil || port == 0 || (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        self.port = isDefault ? nil : port
    }

    public init?(url: URL?) {
        guard let url, let scheme = url.scheme, let host = url.host(percentEncoded: false) else { return nil }
        self.init(scheme: scheme, host: host, port: url.port)
    }

    /// Whether a password may be filled here. Plain `http` sends what is
    /// typed across the network in the clear, so it is never filled into —
    /// except on this Mac itself, which the web platform treats as secure too.
    public var isSecure: Bool {
        scheme == "https" || host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// The key "Never Save for This Site" is remembered under: the same as a
    /// site's mode, so `www.` and the bare host are one site to the person.
    public var siteKey: String { SiteKey.for(host: host) }

    /// As the page's own `location.origin` spells it — the in-page script
    /// refuses to fill unless the two agree.
    public var serialized: String { "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "") }

    /// For people: the host, with the port only when it isn't the default.
    public var displayName: String { host + (port.map { ":\($0)" } ?? "") }

    public var description: String { serialized }

    public static func < (a: LoginOrigin, b: LoginOrigin) -> Bool {
        (a.siteKey, a.host, a.scheme, a.port ?? 0) < (b.siteKey, b.host, b.scheme, b.port ?? 0)
    }
}

/// One saved account: an origin and a username. The password itself stays in
/// the Keychain until someone asks for it, and is never held here.
public struct SavedLogin: Hashable, Sendable, Identifiable {
    public let origin: LoginOrigin
    /// May be empty: some sites sign in with a password alone.
    public let username: String

    public init(origin: LoginOrigin, username: String) {
        self.origin = origin
        self.username = username
    }

    public var id: String { origin.serialized + "\n" + username }
}
