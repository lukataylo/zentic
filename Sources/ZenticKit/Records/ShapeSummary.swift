import Foundation

/// The structure of a JSON response with every value removed.
///
/// This is what recipe inference sends to a model, and the reason it is safe to
/// send: keys, types, lengths, and a coarse *class* for each string — `date`,
/// `url`, `number`, `id`, `text` — computed locally. Never a character of the
/// value itself. The same promise ``DOMSkeleton`` makes about a page, held to the
/// same standard: `PrivacyContractTests` feeds this a response full of sentinel
/// strings and fails if any of them survives.
///
/// Keys *are* included, and keys can be content: some APIs key objects by id,
/// email or URL. Keys that look like values — id-shaped
/// (``EndpointKey/looksLikeID(_:)``) or not identifier-shaped at all — are
/// collapsed to `<key ×n>`, so a map of user ids is described as a map. A map
/// keyed by bare usernames (`{"alice": …}`) is *not* caught: `alice` is
/// indistinguishable from a field name by form. That residue is the stated limit
/// of this summary, and why it is sent only for sources the user added.
public enum ShapeSummary {
    /// A compact, deterministic, human-readable description.
    ///
    /// ```
    /// {data: {home: {timeline: {instructions: [×3 {entries: [×20 {content: …}]}]}}}}
    /// ```
    public static func describe(_ json: Any, maxDepth: Int = 28, maxKeys: Int = 48) -> String {
        var out = ""
        write(json, into: &out, depth: 0, maxDepth: maxDepth, maxKeys: maxKeys)
        return out
    }

    private static func write(_ node: Any, into out: inout String, depth: Int, maxDepth: Int, maxKeys: Int) {
        guard depth < maxDepth else {
            out += "…"
            return
        }
        switch node {
        case let object as [String: Any]:
            let keys = object.keys.sorted()
            let named = keys.filter(isIdentifierShaped)
            let collapsed = keys.count - named.count
            out += "{"
            var first = true
            for key in named.prefix(maxKeys) {
                if !first { out += ", " }
                first = false
                out += key + ": "
                write(object[key]!, into: &out, depth: depth + 1, maxDepth: maxDepth, maxKeys: maxKeys)
            }
            if collapsed > 0, let sample = keys.first(where: { !isIdentifierShaped($0) }) {
                if !first { out += ", " }
                first = false
                out += "<key ×\(collapsed)>: "
                write(object[sample]!, into: &out, depth: depth + 1, maxDepth: maxDepth, maxKeys: maxKeys)
            }
            if named.count > maxKeys { out += ", …\(named.count - maxKeys) more" }
            out += "}"

        case let array as [Any]:
            out += "[×\(array.count)"
            if !array.isEmpty {
                out += " "
                // Merge the first few elements so an optional field present on only
                // some items is still visible. Ten is enough to see a timeline's
                // entry variants without describing all forty.
                write(merged(Array(array.prefix(10))), into: &out, depth: depth + 1, maxDepth: maxDepth, maxKeys: maxKeys)
            }
            out += "]"

        case let string as String:
            out += "\(classify(string))(\(lengthBucket(string.count)))"

        case let number as NSNumber:
            out += CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"

        case is NSNull:
            out += "null"

        default:
            out += "?"
        }
    }

    /// Union of the elements' keys, keeping the first element's value for each —
    /// so an object array is described once rather than once per element.
    private static func merged(_ elements: [Any]) -> Any {
        let objects = elements.compactMap { $0 as? [String: Any] }
        guard objects.count == elements.count, !objects.isEmpty else { return elements[0] }
        var union: [String: Any] = [:]
        for object in objects {
            for (key, value) in object where union[key] == nil || union[key] is NSNull {
                union[key] = value
            }
        }
        return union
    }

    /// The class of a string, from its form alone.
    static func classify(_ string: String) -> String {
        let value = string.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return "empty" }
        if value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("/") {
            return looksLikeImage(value) ? "imageURL" : "url"
        }
        if Double(value) != nil { return value.count >= 12 ? "id" : "numeric" }
        if DateParsing.parse(value) != nil { return "date" }
        if !value.contains(" "), EndpointKey.looksLikeID(value) { return "id" }
        return value.contains(" ") ? "text" : "word"
    }

    private static func looksLikeImage(_ url: String) -> Bool {
        let lower = url.lowercased()
        return [".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", "format=jpg", "format=png"]
            .contains { lower.contains($0) }
    }

    /// Order of magnitude, not the length: `text(~100)` distinguishes a caption
    /// from a body without saying how long this particular post was.
    static func lengthBucket(_ count: Int) -> String {
        switch count {
        case 0: "0"
        case 1..<10: "<10"
        case 10..<40: "~20"
        case 40..<160: "~100"
        case 160..<600: "~300"
        case 600..<3000: "~1k"
        default: ">3k"
        }
    }

    /// `camelCase`, `snake_case`, `kebab-case`, `__typename` — the shapes an API
    /// author gives a field. Anything else (a handle, an id, an email) is treated
    /// as data that happened to be used as a key.
    static func isIdentifierShaped(_ key: String) -> Bool {
        guard (1...40).contains(key.count), !EndpointKey.looksLikeID(key) else { return false }
        guard let first = key.unicodeScalars.first,
            CharacterSet.letters.contains(first) || first == "_" || first == "$" || first == "@"
        else { return false }
        return key.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_" || $0 == "-" || $0 == "$"
                || $0 == "@"
        }
    }
}
