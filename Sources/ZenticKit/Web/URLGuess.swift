import Foundation

/// Turns whatever the user typed into something loadable.
public enum URLGuess {
    public enum SearchEngine: String, Codable, Sendable, CaseIterable, Identifiable {
        case duckDuckGo, google, kagi, bing
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .duckDuckGo: "DuckDuckGo"
            case .google: "Google"
            case .kagi: "Kagi"
            case .bing: "Bing"
            }
        }
        var base: String {
            switch self {
            case .duckDuckGo: "https://duckduckgo.com/"
            case .google: "https://www.google.com/search"
            case .kagi: "https://kagi.com/search"
            case .bing: "https://www.bing.com/search"
            }
        }
    }

    public static func searchURL(for query: String, engine: SearchEngine = .duckDuckGo) -> URL {
        var components = URLComponents(string: engine.base)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url!
    }

    /// Whether `url` is a search results page `resolve` produced.
    public static func isSearch(_ url: URL, engine: SearchEngine) -> Bool {
        url.absoluteString.hasPrefix(engine.base + "?")
    }

    /// - Returns: the URL to load, or a search URL. Never nil for non-empty
    ///   input: an address bar that silently does nothing is worse than one that
    ///   searches for gibberish.
    public static func resolve(_ text: String, engine: SearchEngine = .duckDuckGo) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("://"), let url = URL(string: trimmed), url.host() != nil || url.scheme == "file" {
            return url
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("about:") || lower.hasPrefix("data:"), let url = URL(string: trimmed) {
            return url
        }
        if looksLikeHost(trimmed) {
            let scheme = isLocal(trimmed) ? "http" : "https"
            if let url = URL(string: "\(scheme)://\(trimmed)") { return url }
        }
        return searchURL(for: trimmed, engine: engine)
    }

    /// What the address bar shows when it is not being edited: the host without
    /// `www.`, the way a person would say it.
    public static func displayHost(_ url: URL?) -> String {
        guard let url else { return "" }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else {
            return url.absoluteString == "about:blank" ? "" : url.absoluteString
        }
        return SiteKey.for(host: host)
    }

    private static func isLocal(_ text: String) -> Bool {
        let host = text.split(separator: "/").first.map(String.init) ?? text
        let name = host.split(separator: ":").first.map(String.init) ?? host
        return name == "localhost" || name.hasSuffix(".local")
            || name.split(separator: ".").count == 4 && name.split(separator: ".").allSatisfy { Int($0) != nil }
    }

    /// A single token with a dot and a plausible TLD, `localhost`, or an IPv4.
    ///
    /// Conservative on purpose: misreading a search as a host produces a DNS
    /// error page, which is worse than searching for something that happened to
    /// be a domain.
    private static func looksLikeHost(_ text: String) -> Bool {
        guard !text.contains(" ") else { return false }
        if isLocal(text) { return true }
        let host = text.split(separator: "/").first.map(String.init) ?? text
        let labels = host.split(separator: ":").first.map { $0.split(separator: ".") } ?? []
        guard labels.count >= 2, let last = labels.last else { return false }
        return last.count >= 2 && last.allSatisfy { $0.isLetter }
    }
}
