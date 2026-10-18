import Foundation

/// Applies an ``EndpointRecipe`` to a parsed response. Pure: no I/O, no clock
/// beyond the `seenAt` it is handed, so a recipe can be tested against a captured
/// response byte for byte.
public enum RecordMapper {
    /// Records for one response. Items without an id, or with neither text nor a
    /// title, are dropped: an app cannot show them and the store cannot key them.
    public static func records(
        from json: Any,
        recipe: EndpointRecipe,
        source: String,
        pageURL: URL?,
        seenAt: Date = .now
    ) -> [SourceRecord] {
        guard let itemsPath = recipe.items, let path = try? JSONPath(itemsPath) else { return [] }
        let unwrap = recipe.unwrap.compactMap { try? JSONPath($0) }

        var seen: Set<String> = []
        var out: [SourceRecord] = []
        for candidate in path.evaluate(json) {
            let item = unwrapped(candidate, using: unwrap)
            guard let record = record(
                from: item,
                recipe: recipe,
                source: source,
                pageURL: pageURL,
                seenAt: seenAt
            ) else { continue }
            // The same item routinely appears twice in one response — a thread's
            // focal tweet is also its first reply's parent module.
            guard seen.insert(record.id).inserted else { continue }
            out.append(record)
        }
        return out
    }

    /// Repeatedly replace the item with the first unwrap path that yields an
    /// object. Bounded, so a path that selects its own ancestor cannot loop.
    static func unwrapped(_ item: Any, using paths: [JSONPath]) -> Any {
        var current = item
        for _ in 0..<4 {
            guard let next = paths.lazy.compactMap({ $0.evaluate(current).first as? [String: Any] }).first
            else { break }
            current = next
        }
        return current
    }

    static func record(
        from item: Any,
        recipe: EndpointRecipe,
        source: String,
        pageURL: URL?,
        seenAt: Date
    ) -> SourceRecord? {
        let fields = recipe.fields
        guard let id = scalar(fields.id, in: item), !id.isEmpty else { return nil }
        let title = scalar(fields.title, in: item).map(decodingEntities)
        let text = scalar(fields.text, in: item).map(decodingEntities)
        guard title?.isEmpty == false || text?.isEmpty == false else { return nil }

        var record = SourceRecord(
            source: source,
            id: id,
            kind: recipe.kind,
            title: title,
            text: text,
            author: scalar(fields.author, in: item),
            authorHandle: scalar(fields.authorHandle, in: item),
            authorAvatar: scalar(fields.authorAvatar, in: item).flatMap { absolute($0, against: pageURL) },
            publishedAt: date(fields.publishedAt, in: item),
            parentID: scalar(fields.parentID, in: item),
            threadID: scalar(fields.threadID, in: item),
            media: strings(fields.media, in: item).compactMap { absolute($0, against: pageURL) },
            mentions: strings(fields.mentions, in: item).map { handle in
                String(handle.drop { $0 == "@" }).lowercased()
            },
            links: strings(fields.links, in: item).compactMap { absolute($0, against: pageURL) },
            metrics: metrics(fields.metrics, in: item),
            firstSeen: seenAt,
            lastSeen: seenAt
        )

        if let link = scalar(fields.url, in: item) {
            record.url = absolute(link, against: pageURL)
        } else if let template = fields.urlTemplate {
            record.url = fill(template, from: record).flatMap { absolute($0, against: pageURL) }
        }
        return record
    }

    // MARK: - Field reads

    /// The first alternative that yields a string or number.
    static func scalar(_ paths: [String], in item: Any) -> String? {
        for raw in paths {
            guard let path = try? JSONPath(raw) else { continue }
            for value in path.evaluate(item) {
                if let string = value as? String {
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                } else if let number = value as? NSNumber, !isBoolean(number) {
                    return number.stringValue
                }
            }
        }
        return nil
    }

    static func strings(_ paths: [String], in item: Any) -> [String] {
        var out: [String] = []
        for raw in paths {
            guard let path = try? JSONPath(raw) else { continue }
            for value in path.evaluate(item) {
                if let string = value as? String, !string.isEmpty, !out.contains(string) {
                    out.append(string)
                }
            }
        }
        return out
    }

    static func metrics(_ specs: [FieldMap.Metric], in item: Any) -> [String: Double] {
        var out: [String: Double] = [:]
        for spec in specs {
            // Numbers arrive as numbers or as strings ("views": {"count": "1204"}).
            guard let raw = scalar(spec.paths, in: item), let value = Double(raw), value.isFinite
            else { continue }
            out[spec.name] = value
        }
        return out
    }

    static func date(_ paths: [String], in item: Any) -> Date? {
        scalar(paths, in: item).flatMap(DateParsing.parse)
    }

    /// The handful of entities APIs escape in plain-text fields. X sends `&amp;`
    /// in `full_text`; without this every app would show it literally. Only these
    /// five, because a text field is not HTML and decoding more would turn a post
    /// that *talks about* `&nbsp;` into one that contains it.
    static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Resolve against the page, and keep only web URLs. A `javascript:` link in
    /// a site's JSON must not become something an app renders as a link.
    static func absolute(_ string: String, against base: URL?) -> String? {
        guard let url = URL(string: string, relativeTo: base)?.absoluteURL,
            let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return nil }
        return url.absoluteString
    }

    /// Fill `{field}` placeholders. Any placeholder left unfilled voids the URL
    /// rather than producing `https://x.com//status/123`.
    static func fill(_ template: String, from record: SourceRecord) -> String? {
        let values: [String: String?] = [
            "id": record.id,
            "authorHandle": record.authorHandle,
            "threadID": record.threadID,
            "parentID": record.parentID,
        ]
        var result = template
        for (name, value) in values where result.contains("{\(name)}") {
            guard let value, let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            else { return nil }
            result = result.replacingOccurrences(of: "{\(name)}", with: encoded)
        }
        return result.contains("{") ? nil : result
    }
}

/// Dates as sites actually send them.
public enum DateParsing {
    /// A date, or nil — never an absurd one. A field mis-mapped as a date (an id,
    /// a year, `"nan"`) must not pin a record to the top of every timeline or, worse,
    /// become a value the store cannot decode again.
    public static func parse(_ raw: String) -> Date? {
        let string = raw.trimmingCharacters(in: .whitespaces)
        let date: Date?
        if string.allSatisfy({ $0.isNumber || $0 == "." }), let number = Double(string), number.isFinite {
            // Seconds or milliseconds since the epoch. Fewer than nine digits is a
            // year or a count, not a timestamp; past 1e11 seconds is milliseconds.
            guard number >= 1e8 else { return nil }
            date = Date(timeIntervalSince1970: number > 1e11 ? number / 1000 : number)
        } else {
            date = iso.date(from: string) ?? isoFractional.date(from: string)
                ?? legacy.lazy.compactMap { $0.date(from: string) }.first
        }
        guard let date, plausible.contains(date) else { return nil }
        return date
    }

    /// 1990 to two days from now: wider than any real post, narrower than any
    /// mistake.
    static var plausible: ClosedRange<Date> {
        Date(timeIntervalSince1970: 631_152_000)...Date.now.addingTimeInterval(2 * 24 * 60 * 60)
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let legacy: [DateFormatter] = [
        // X / Twitter: `Wed Oct 10 20:19:24 +0000 2018`.
        "EEE MMM dd HH:mm:ss Z yyyy",
        // RFC 2822, as RSS and many REST APIs use.
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }
}
