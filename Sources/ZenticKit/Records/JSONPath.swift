import Foundation

/// A deliberately tiny JSONPath: enough to point at items in a site's API
/// response, and nothing that can run.
///
/// ```
/// $..itemContent[?!promotedMetadata].tweet_results.result
/// legacy.extended_entities.media[*].media_url_https
/// ```
///
/// | Step       | Meaning                                         |
/// |------------|-------------------------------------------------|
/// | `$`        | the root (optional, only as the first token)    |
/// | `.key`     | a child                                         |
/// | `..key`    | every descendant named `key`, at any depth      |
/// | `[*]`      | every element of an array, or value of an object|
/// | `[?key]`   | keep objects that have `key`                    |
/// | `[?!key]`  | keep objects that lack `key`                    |
///
/// Recursive descent is the important one. Sites nest the same item at
/// different depths depending on the screen — a timeline entry, a thread module,
/// a search result — and wrappers come and go between releases. A path that names
/// the item by what it *is* rather than where it sits survives both, which is
/// most of the difference between an adapter that lasts and one that rots.
///
/// Recipes come from a model as well as from us, so a path is data, not code:
/// there are no expressions, no functions and no way to make evaluation loop.
public struct JSONPath: Sendable, Hashable, CustomStringConvertible {
    enum Step: Sendable, Hashable {
        case child(String)
        case descendant(String)
        case all
        case has(String)
        case lacks(String)
    }

    let steps: [Step]
    public let description: String

    public enum ParseError: Error, Equatable {
        case empty
        case malformed(String)
    }

    public init(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ParseError.empty }
        description = trimmed

        var steps: [Step] = []
        var rest = Substring(trimmed)
        if rest.hasPrefix("$") { rest = rest.dropFirst() }

        func readKey() -> String {
            let key = rest.prefix { $0 != "." && $0 != "[" }
            rest = rest.dropFirst(key.count)
            return String(key)
        }

        // A bare leading key is a child step: `legacy.full_text`.
        if let first = rest.first, first != "." && first != "[" {
            steps.append(.child(readKey()))
        }

        while !rest.isEmpty {
            if rest.hasPrefix("..") {
                rest = rest.dropFirst(2)
                let key = readKey()
                guard !key.isEmpty else { throw ParseError.malformed(trimmed) }
                steps.append(.descendant(key))
            } else if rest.hasPrefix(".") {
                rest = rest.dropFirst()
                let key = readKey()
                guard !key.isEmpty else { throw ParseError.malformed(trimmed) }
                steps.append(.child(key))
            } else if rest.hasPrefix("[") {
                guard let close = rest.firstIndex(of: "]") else {
                    throw ParseError.malformed(trimmed)
                }
                let inner = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                if inner == "*" {
                    steps.append(.all)
                } else if inner.hasPrefix("?!"), inner.count > 2 {
                    steps.append(.lacks(String(inner.dropFirst(2))))
                } else if inner.hasPrefix("?"), inner.count > 1 {
                    steps.append(.has(String(inner.dropFirst())))
                } else {
                    throw ParseError.malformed(trimmed)
                }
            } else {
                throw ParseError.malformed(trimmed)
            }
        }

        guard !steps.isEmpty else { throw ParseError.empty }
        self.steps = steps
    }

    /// Every value the path selects, in document order.
    public func evaluate(_ root: Any) -> [Any] {
        var current: [Any] = [root]
        for step in steps {
            var next: [Any] = []
            for node in current {
                switch step {
                case .child(let key):
                    if let object = node as? [String: Any], let value = object[key], !(value is NSNull) {
                        next.append(value)
                    }
                case .descendant(let key):
                    Self.collect(key, in: node, into: &next, depth: 0)
                case .all:
                    if let array = node as? [Any] {
                        next.append(contentsOf: array)
                    } else if let object = node as? [String: Any] {
                        next.append(contentsOf: object.keys.sorted().compactMap { object[$0] })
                    }
                case .has(let key):
                    if let object = node as? [String: Any], object[key] != nil { next.append(node) }
                case .lacks(let key):
                    if let object = node as? [String: Any], object[key] == nil { next.append(node) }
                }
            }
            current = next
        }
        return current
    }

    /// Depth-capped so a pathological response cannot recurse without bound —
    /// `JSONSerialization` itself allows nesting far deeper than any real API.
    private static let maxDepth = 64

    private static func collect(_ key: String, in node: Any, into out: inout [Any], depth: Int) {
        guard depth < maxDepth else { return }
        if let object = node as? [String: Any] {
            // Sorted so the result order is deterministic: dictionary order is not,
            // and record order is what a timeline shows.
            for name in object.keys.sorted() {
                guard let value = object[name] else { continue }
                if name == key, !(value is NSNull) { out.append(value) }
                collect(key, in: value, into: &out, depth: depth + 1)
            }
        } else if let array = node as? [Any] {
            for element in array {
                collect(key, in: element, into: &out, depth: depth + 1)
            }
        }
    }
}
