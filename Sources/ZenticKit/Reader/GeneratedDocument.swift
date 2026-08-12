import Foundation

/// A model-authored rendering of the page, as plain HTML.
///
/// This is the one place a model produces markup rather than tokens, and it is
/// why every field here passes through ``GeneratedHTML/sanitize(_:allowing:)``
/// before it can reach a page. Invariant 5 exists because free-form markup can
/// reach the network — `url()`, `<link>`, a remote `<img>`, an `@import` — and a
/// beacon that fires on every page read is silent when it works. A theme cannot
/// express a request; markup can, so the request has to be taken away from it
/// rather than trusted not to appear.
///
/// The original DOM is still only hidden, never destroyed: ⌘\ restores the site's
/// own page from a generated one exactly as it does from a restructured one.
public struct GeneratedDocument: Codable, Sendable, Hashable {
    /// Sanitised markup for the reading view, including its own `<style>`.
    ///
    /// Non-rewritable sections are *not* in here. They arrive as
    /// `<zentic-section section="…">` placeholders, which the bundle replaces with
    /// its own rendering of that section — see ``DocumentRequest``.
    public var html: String

    public init(html: String) {
        self.html = html
    }
}

/// What the model is given to design a page.
///
/// Invariant 3 holds here as it does for rewriting: code, tables, math and embeds
/// are never sent. The model is told a placeholder exists at that point in the
/// document and emits a tag for it; the bundle renders the real content locally.
/// So a model can lay out a page containing a code block without ever seeing the
/// code — and cannot rename an identifier inside it, because it never had it.
public struct DocumentRequest: Sendable, Hashable {
    public var extraction: ExtractionResult
    /// The look the user asked for, in their words.
    public var prompt: String

    public init(extraction: ExtractionResult, prompt: String) {
        self.extraction = extraction
        self.prompt = prompt
    }

    /// Sections the model may see the text of.
    public var rewritableSections: [ContentSection] {
        extraction.sections.filter(\.kind.isRewritable)
    }

    /// Every URL that already appears in this page's own content.
    ///
    /// The allow-list for images in the generated markup. A model that invents an
    /// image URL gets it dropped rather than fetched, so a generated design can
    /// never introduce a host the page was not already talking to.
    public var contentURLs: Set<String> {
        var found: Set<String> = []
        for section in extraction.sections {
            found.formUnion(GeneratedHTML.urls(in: section.markdown))
            if let html = section.html { found.formUnion(GeneratedHTML.urls(in: html)) }
        }
        return found
    }
}

// MARK: - Sanitising

/// Strips everything from model-authored markup that could reach the network or
/// run.
///
/// Deliberately a small allow-listing pass over strings rather than a full HTML
/// parser: the output is inserted into a shadow root inside our own
/// `WKContentWorld`, where `innerHTML` will not execute a `<script>` anyway. This
/// is the layer that stops the *quiet* failures — a tracking pixel, a webfont, a
/// `url()` in a style block — which no amount of world isolation would catch.
public enum GeneratedHTML {
    /// Elements dropped whole, with their contents.
    ///
    /// `<style>` is *not* here: a design the model cannot style is not a design.
    /// Its content is defanged instead — `url()`, `@import` and `@font-face` all
    /// go, which is every way a stylesheet can reach the network.
    private static let strippedElements = ["script", "iframe", "object", "embed", "svg"]
    /// Elements dropped as tags, keeping any text between them.
    private static let strippedTags = ["link", "base", "meta", "form", "input", "button", "video", "audio", "source", "track", "applet", "frame", "frameset", "portal"]

    /// Sanitise generated markup.
    ///
    /// - Parameter allowing: image URLs that already appear in the page's own
    ///   content. An `<img>` whose `src` is not in this set is removed.
    public static func sanitize(_ html: String, allowing allowedURLs: Set<String>) -> String {
        var result = html

        // Fenced code blocks around the whole answer are the single most common
        // shape a model returns markup in.
        result = unfence(result)

        for element in strippedElements {
            result = removeElement(element, from: result)
        }
        for tag in strippedTags {
            result = removeTags(tag, from: result)
        }

        result = removeMatches(of: "\\son[a-zA-Z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", in: result)
        result = removeMatches(of: "\\s(?:href|src|action|formaction|data|poster|xlink:href)\\s*=\\s*(\"|')?\\s*(?:javascript|vbscript|data)\\s*:[^\"'>]*(\"|')?", in: result)
        // Any remaining `url(` — in a leftover style attribute, or smuggled into
        // an attribute we do keep.
        result = replaceMatches(of: "url\\s*\\([^)]*\\)", in: result, with: "none")
        result = removeMatches(of: "@import[^;]*;", in: result)
        // A webfont is a request to a font host on every page read, and the whole
        // font list is local anyway (see `FontKey`).
        result = removeMatches(of: "@font-face\\s*\\{[^}]*\\}", in: result)

        result = dropDisallowedImages(in: result, allowing: allowedURLs)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Absolute http(s) URLs in a string.
    public static func urls(in text: String) -> Set<String> {
        Set(matches(of: "https?://[^\\s\"'<>)\\]]+", in: text))
    }

    // MARK: Steps

    /// Unwrap ```html … ``` if the whole answer is one fenced block.
    private static func unfence(_ html: String) -> String {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return html }
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private static func removeElement(_ name: String, from html: String) -> String {
        removeMatches(of: "<\\s*\(name)\\b[^>]*>[\\s\\S]*?<\\s*/\\s*\(name)\\s*>", in: html)
            // Unclosed or self-closing forms of the same element.
            .replacingMatches(of: "<\\s*\(name)\\b[^>]*/?>", with: "")
    }

    private static func removeTags(_ name: String, from html: String) -> String {
        removeMatches(of: "<\\s*/?\\s*\(name)\\b[^>]*>", in: html)
    }

    /// Remove any `<img>` whose `src` is not a URL the page already loads.
    private static func dropDisallowedImages(in html: String, allowing allowed: Set<String>) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<\\s*img\\b[^>]*>", options: [.caseInsensitive])
        else { return html }

        let text = html as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let tag = text.substring(with: match.range)
            output += text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if let src = attribute("src", in: tag), allowed.contains(src) {
                output += tag
            }
            cursor = match.range.location + match.range.length
        }
        output += text.substring(from: cursor)
        return output
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        matches(of: "\(name)\\s*=\\s*\"([^\"]*)\"", in: tag, group: 1).first
            ?? matches(of: "\(name)\\s*=\\s*'([^']*)'", in: tag, group: 1).first
    }

    // MARK: Regex helpers

    private static func matches(of pattern: String, in text: String, group: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { match in
                let range = match.range(at: group)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
    }

    private static func removeMatches(of pattern: String, in text: String) -> String {
        replaceMatches(of: pattern, in: text, with: "")
    }

    private static func replaceMatches(of pattern: String, in text: String, with replacement: String) -> String {
        text.replacingMatches(of: pattern, with: replacement)
    }
}

extension String {
    fileprivate func replacingMatches(of pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return self }
        return regex.stringByReplacingMatches(
            in: self,
            range: NSRange(location: 0, length: (self as NSString).length),
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }
}
