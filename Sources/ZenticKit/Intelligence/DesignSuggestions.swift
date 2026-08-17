import Foundation

/// Starting points for a prompted redesign.
///
/// A blank text field is a bad way to ask for a design. Most people do not have a
/// typographic vocabulary ready, and "describe the look you want" invites either a
/// single adjective the model cannot act on or nothing at all. So the prompt opens
/// with suggestions — and the good ones are not generic, they are about *this page*:
/// a reference page wants a tight measure and legible code, an essay wants the
/// opposite, and neither wants what the other wants.
///
/// These are plain prose because that is what the model is asked to read. They stay
/// in ZenticKit rather than the Mac target so iOS gets the same list.
public enum DesignSuggestions {

    /// Suggestions for a page, best fit first.
    ///
    /// Archetype-led, then a few evergreen looks. Deliberately a small list: twenty
    /// options is another blank field, wearing a hat.
    public static func forPage(archetype: Archetype?, isFidelitySensitive: Bool = false) -> [String] {
        var suggestions = archetypeLed(archetype)
        suggestions.append(contentsOf: evergreen)
        // A page whose exact wording matters is one to keep sober. Nothing here
        // changes a word — a theme is lossless — but a playful design on a medical
        // page reads as a claim about how seriously to take it.
        if isFidelitySensitive {
            suggestions.removeAll { $0 == Self.playful }
        }
        var seen = Set<String>()
        return suggestions.filter { seen.insert($0).inserted }
    }

    private static func archetypeLed(_ archetype: Archetype?) -> [String] {
        switch archetype {
        case .docs:
            [
                "technical documentation: tight measure, strong heading hierarchy, "
                    + "high-contrast monospace for code",
                "reference manual, printed: narrow columns, small caps headings, hairline rules",
            ]
        case .article:
            [
                "long-form reading: serif body, generous line height, wide margins, muted palette",
                "magazine feature: large display headings, a drop cap, roomy leading",
            ]
        case .feed, .thread:
            [
                "dense but calm: compact spacing, clear separation between items, quiet colour",
            ]
        case .app, nil:
            []
        }
    }

    private static let playful = "1997 personal homepage: system fonts, bevelled edges, loud accents"

    private static let evergreen = [
        "minimal and warm: off-white background, soft greys, one restrained accent",
        "high-contrast dark: near-black background, bright text, saturated links",
        "newsprint: condensed serif, tight leading, black on paper white",
        "terminal: monospace throughout, green on black, no ornament",
        playful,
    ]
}
