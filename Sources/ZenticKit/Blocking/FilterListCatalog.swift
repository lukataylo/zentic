import Foundation

/// The filter lists Zentic ships with, and where the bundled seed lives.
public enum FilterListCatalog {
    /// Identifier of the bundled seed list. It is not a ``FilterListSource``
    /// because it is never fetched — see ``seedRules()``.
    public static let seedID = "zentic-seed"

    /// EasyList and friends, served from the canonical `easylist-downloads`
    /// mirror. AdGuard's own combined lists are larger and add scriptlet syntax
    /// that Safari cannot express, so the extra bytes convert to nothing.
    public static let defaults: [FilterListSource] = [
        FilterListSource(
            id: "easylist",
            title: "EasyList",
            url: URL(string: "https://easylist.to/easylist/easylist.txt")!,
            isDefault: true
        ),
        FilterListSource(
            id: "easyprivacy",
            title: "EasyPrivacy",
            url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!,
            isDefault: true
        ),
        FilterListSource(
            id: "easylist-cookie",
            title: "EasyList Cookie",
            url: URL(
                string: "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt"
            )!,
            isDefault: true
        ),
    ]

    /// Rules from the bundled seed list.
    ///
    /// Missing or unreadable resources return an empty array rather than throwing:
    /// a broken build should degrade to "no blocking yet", not to a browser that
    /// refuses to open a tab.
    public static func seedRules() -> [String] {
        seedRules(in: .module)
    }

    static func seedRules(in bundle: Bundle) -> [String] {
        guard
            let url = bundle.url(forResource: "seed", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return FilterListText.lines(of: text)
    }
}

/// Splitting filter-list text into rules.
public enum FilterListText {
    /// Non-empty, non-comment lines.
    ///
    /// The converter tolerates comments, but stripping them here keeps the
    /// `sourceRuleCount` we report honest — EasyList is about 8% comments, and a
    /// count that includes them makes the drop rate look better than it is.
    public static func lines(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            // `!` is an ABP comment. `[` opens an `[Adblock Plus 2.0]` header.
            if trimmed.hasPrefix("!") || trimmed.hasPrefix("[") { return nil }
            return trimmed
        }
    }
}
