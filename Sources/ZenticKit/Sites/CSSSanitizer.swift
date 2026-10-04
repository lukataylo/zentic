import Foundation

/// Makes a model-written stylesheet safe to replay on every visit.
///
/// The danger in CSS is not that it can run code — it cannot — but that it can
/// *fetch*. A `url()` or `@import` pointing at a third party is a beacon that
/// fires on every page load, invisibly, for as long as the version is kept. So
/// anything that can reach the network is removed, and only `data:` URLs (which
/// cannot) survive. Fonts come from the machine: `@font-face` is dropped whole.
///
/// The in-page script applies the same rules again before inserting a sheet;
/// this side exists so that what is *stored* is already clean.
public enum CSSSanitizer {
    public static let maxLength = 60_000

    public static func sanitize(_ css: String) -> String {
        var out = String(css.prefix(maxLength))
        // Repeat to a fixed point, replacing with a space rather than nothing:
        // a single pass that *deletes* a token can splice the text around it
        // into a new one (`urjavascript:l(` → `url(`). The in-page sanitizer in
        // `web/src/sanitize.ts` does the same, again, at apply time.
        for _ in 0..<8 {
            let before = out
            out = replacing(#"/\*[\s\S]*?(\*/|$)"#, in: out, with: " ")
            // No escapes at all: they are how every filter below would be spelled around.
            out = out.replacingOccurrences(of: "\\", with: " ")
            out = replacing(#"</?\s*style"#, in: out, with: " ")
            out = removeAtRuleBlocks(named: "font-face", in: out)
            out = replacing(#"@import[^;]*;?"#, in: out, with: " ")
            out = replacing(#"@namespace[^;]*;?"#, in: out, with: " ")
            out = replacing(#"url\(\s*(?!['"]?\s*data:)[^)]*\)"#, in: out, with: "none")
            out = replacing(#"(-webkit-)?image-set\([^)]*\)"#, in: out, with: "none")
            out = replacing(#"\bsrc\s*\([^)]*\)"#, in: out, with: "none")
            out = replacing(#"expression\s*\("#, in: out, with: " (")
            out = replacing(#"javascript\s*:"#, in: out, with: " ")
            out = replacing(#"-moz-binding|behaviou?r\s*:"#, in: out, with: " ")
            if out == before { break }
        }
        // Anything that can still fetch condemns the whole sheet.
        return fetchesRemotely(out) ? "" : out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether CSS still contains anything that can reach the network.
    public static func fetchesRemotely(_ css: String) -> Bool {
        let lower = css.lowercased()
        if lower.contains("@import") || lower.contains("\\") { return true }
        for pattern in [#"image-set\s*\("#, #"\bsrc\s*\("#, #"url\s*\(\s*(?!['"]?\s*data:)"#] {
            if lower.range(of: pattern, options: .regularExpression) != nil { return true }
        }
        return false
    }

    /// Selectors are inserted into a stylesheet as `sel { display: none }`, so a
    /// selector containing braces could smuggle in declarations of its own.
    public static func sanitizeSelectors(_ selectors: [String]) -> [String] {
        var seen = Set<String>()
        return selectors.compactMap { raw in
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, s.count <= 300,
                !s.contains("{"), !s.contains("}"), !s.contains(";"),
                !s.contains("</"), !s.lowercased().contains("url(")
            else { return nil }
            let lowered = s.lowercased()
            guard !["html", "body", "head", ":root", "*"].contains(lowered) else { return nil }
            return seen.insert(s).inserted ? s : nil
        }
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }

    /// Removes `@name { … }` including nested braces.
    private static func removeAtRuleBlocks(named name: String, in text: String) -> String {
        var result = ""
        var index = text.startIndex
        let needle = "@" + name
        while let found = text.range(of: needle, options: .caseInsensitive, range: index..<text.endIndex) {
            result += text[index..<found.lowerBound]
            guard let open = text[found.upperBound...].firstIndex(of: "{") else {
                index = text.endIndex
                break
            }
            var depth = 0
            var cursor = open
            while cursor < text.endIndex {
                if text[cursor] == "{" { depth += 1 }
                if text[cursor] == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                cursor = text.index(after: cursor)
            }
            index = cursor < text.endIndex ? text.index(after: cursor) : text.endIndex
        }
        result += text[index...]
        return result
    }
}
