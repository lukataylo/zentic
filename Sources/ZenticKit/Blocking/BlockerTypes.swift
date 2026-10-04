import Foundation

public struct BlockerRefreshReport: Sendable, Hashable {
    public var listsUpdated: [String]
    public var rulesCompiled: Int
    /// Rules the converter dropped because Safari's syntax cannot express them.
    /// Expected to be non-zero: `WKContentRuleList` supports a subset of
    /// Adblock Plus syntax. A sudden jump means an upstream list changed shape.
    public var rulesDropped: Int
    public var duration: Duration

    public init(
        listsUpdated: [String],
        rulesCompiled: Int,
        rulesDropped: Int,
        duration: Duration
    ) {
        self.listsUpdated = listsUpdated
        self.rulesCompiled = rulesCompiled
        self.rulesDropped = rulesDropped
        self.duration = duration
    }
}

/// An upstream filter list.
public struct FilterListSource: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var url: URL
    /// Whether this list is on by default.
    public var isDefault: Bool

    public init(id: String, title: String, url: URL, isDefault: Bool) {
        self.id = id
        self.title = title
        self.url = url
        self.isDefault = isDefault
    }
}

public enum BlockerError: Error, Sendable, Equatable {
    case compilationFailed(list: String, message: String)
    case downloadFailed(list: String, message: String)
    /// WebKit imposes a ceiling on rules per compiled list, so large lists are
    /// split into several `WKContentRuleList`s rather than one.
    case ruleLimitExceeded(list: String, count: Int)
}
