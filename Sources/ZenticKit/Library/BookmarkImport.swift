import Foundation

/// Reads the bookmarks file Safari, Chrome, Firefox and Edge all export: the
/// "Netscape bookmark file", HTML of the shape
///
///     <DL><p>
///       <DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
///       <DL><p>
///         <DT><A HREF="https://example.com" ADD_DATE="…">Example</A>
///       </DL><p>
///     </DL><p>
///
/// It is not well-formed HTML (`<DT>` and `<p>` are never closed), so this
/// scans tags rather than parsing a document.
public enum BookmarkImport {
    /// Top-level folders become folders; deeper ones are flattened into
    /// their top-level folder. The browser's toolbar folder ("Bookmarks bar")
    /// is see-through: what is on it lands at the top level, because in
    /// Chrome that is where nearly everything lives. Only web addresses are
    /// kept — bookmarklets (`javascript:`) and browser-internal pages are not
    /// pages Zentic can open.
    public static func parse(_ html: String) -> [Bookmark] {
        enum Level {
            case transparent
            /// A top-level folder, by its index in `result`.
            case folder(Int)
            /// A folder inside a folder: its links go to the outer one.
            case nested
        }
        var result: [Bookmark] = []
        var stack: [Level] = []
        /// The folder heading just read, waiting for its `<DL>`.
        var heading: (title: String, isToolbar: Bool)?

        var folderIndex: Int? {
            for level in stack { if case .folder(let index) = level { return index } }
            return nil
        }

        var cursor = html.startIndex
        while let open = html[cursor...].firstIndex(of: "<"),
            let close = html[open...].firstIndex(of: ">")
        {
            let tag = html[html.index(after: open)..<close]
            cursor = html.index(after: close)
            let name = tag.prefix { !$0.isWhitespace }.lowercased()

            switch name {
            case "dl":
                if let pending = heading {
                    if pending.isToolbar {
                        stack.append(.transparent)
                    } else if folderIndex == nil {
                        result.append(.folder(pending.title))
                        stack.append(.folder(result.count - 1))
                    } else {
                        stack.append(.nested)
                    }
                } else {
                    // The outermost list, or a list with no heading.
                    stack.append(.transparent)
                }
                heading = nil
            case "/dl":
                if !stack.isEmpty { stack.removeLast() }
            case "h3":
                let (text, end) = content(of: "h3", in: html, from: cursor)
                cursor = end
                heading = (decodeEntities(text), attribute("personal_toolbar_folder", in: tag)?.lowercased() == "true")
            case "a":
                let (text, end) = content(of: "a", in: html, from: cursor)
                cursor = end
                guard let href = attribute("href", in: tag).map(decodeEntities),
                    let url = URL(string: href.trimmingCharacters(in: .whitespaces)),
                    let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil
                else { continue }
                var title = decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty { title = URLGuess.displayHost(url) }
                let bookmark = Bookmark(title: title, url: url)
                if let index = folderIndex {
                    result[index].children.append(bookmark)
                } else {
                    result.append(bookmark)
                }
            default:
                break
            }
        }
        // A folder that held only bookmarklets, or nothing, is noise.
        return result.filter { !$0.isFolder || !$0.children.isEmpty }
    }

    /// The text up to `</name>`, and where scanning resumes.
    private static func content(of name: String, in html: String, from start: String.Index) -> (String, String.Index) {
        guard let end = html.range(of: "</\(name)", options: .caseInsensitive, range: start..<html.endIndex) else {
            return ("", start)
        }
        let text = String(html[start..<end.lowerBound])
        let resume = html[end.upperBound...].firstIndex(of: ">").map(html.index(after:)) ?? html.endIndex
        // Titles hold no markup; drop any that crept in rather than show it.
        return (text.replacing(/<[^>]*>/, with: ""), resume)
    }

    /// An attribute's value: quoted with either quote, or bare.
    static func attribute(_ name: String, in tag: Substring) -> String? {
        guard let range = tag.range(of: #"(?:^|\s)\#(name)\s*=\s*"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let rest = tag[range.upperBound...]
        guard let first = rest.first else { return nil }
        if first == "\"" || first == "'" {
            let body = rest.dropFirst()
            return String(body.prefix { $0 != first })
        }
        return String(rest.prefix { !$0.isWhitespace })
    }

    /// The handful of entities exporters write, and numeric references.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            output += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            guard let semi = after.prefix(10).firstIndex(of: ";") else {
                output += "&"
                rest = after
                continue
            }
            let entity = after[..<semi].lowercased()
            let decoded: String? =
                switch entity {
                case "amp": "&"
                case "lt": "<"
                case "gt": ">"
                case "quot": "\""
                case "apos": "'"
                case "nbsp": "\u{00A0}"
                default:
                    if entity.hasPrefix("#x") {
                        UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
                    } else if entity.hasPrefix("#") {
                        UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
                    } else {
                        nil
                    }
                }
            if let decoded {
                output += decoded
                rest = after[after.index(after: semi)...]
            } else {
                output += "&"
                rest = after
            }
        }
        return output + rest
    }
}
