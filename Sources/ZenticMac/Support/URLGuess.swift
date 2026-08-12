import Foundation

/// Turns whatever the user typed into something loadable.
enum URLGuess {
    /// Search used when the input is clearly not an address.
    ///
    /// DuckDuckGo because it needs no API key and sets no tracking cookie, which
    /// matters for a browser whose pitch is that nothing about browsing leaves the
    /// device.
    static func searchURL(for query: String) -> URL {
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url!
    }

    /// - Returns: the URL to load, or a search URL. Never nil for non-empty input,
    ///   because an address bar that silently does nothing is worse than one that
    ///   searches for gibberish.
    static func resolve(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("://"), let url = URL(string: trimmed) {
            return url
        }
        // `about:blank`, `data:`, `file:/…` — anything with a scheme but no authority.
        if let colon = trimmed.firstIndex(of: ":"), !trimmed.contains(" "),
            let url = URL(string: trimmed), url.scheme != nil, colon > trimmed.startIndex
        {
            return url
        }
        if looksLikeHost(trimmed), let url = URL(string: "https://\(trimmed)") {
            return url
        }
        return searchURL(for: trimmed)
    }

    /// A single token with a dot and a plausible TLD, or `localhost`.
    ///
    /// Deliberately conservative: misreading a search as a host produces a DNS
    /// error page, which is a worse failure than searching for something that
    /// happened to be a domain.
    private static func looksLikeHost(_ text: String) -> Bool {
        if text == "localhost" || text.hasPrefix("localhost:") { return true }
        guard !text.contains(" ") else { return false }

        let host = text.split(separator: "/").first.map(String.init) ?? text
        let labels = host.split(separator: ":").first.map { $0.split(separator: ".") } ?? []
        guard labels.count >= 2, let last = labels.last else { return false }
        return last.count >= 2 && last.allSatisfy { $0.isLetter }
    }
}
