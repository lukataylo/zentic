import Foundation
import WebKit

/// Compiles filter lists into `WKContentRuleList`s and tracks per-origin shields.
///
/// WebKit's content-blocking API is *declarative*: rules are compiled ahead of
/// time and enforced inside the network process. That has two consequences the
/// whole design has to live with.
///
/// First, it is fast — matching costs nothing at request time, which is why this
/// approach beats a JavaScript-level blocker. Second, **it reports nothing back**.
/// There is no callback, no count, no list of what was blocked. So Zentic shows
/// shield *state*, never a "127 trackers blocked" number, because any such number
/// would be invented. See the YAGNI list in the plan.
///
/// Cosmetic filtering (hiding elements that did load) and cookie-wall dismissal
/// therefore happen in the injected bundle, not here.
public protocol ContentBlockerService: Sendable {
    /// Compiled lists to attach to a web view's `WKUserContentController`.
    /// Cached on disk by WebKit; recompiling is expensive, so this is cheap to
    /// call repeatedly and expensive only on first run and after a refresh.
    func installedRuleLists() async throws -> [WKContentRuleList]

    /// Re-fetch upstream filter lists and recompile if they changed.
    /// - Parameter force: Recompile even when the upstream content is unchanged.
    func refresh(force: Bool) async throws -> BlockerRefreshReport

    func setShield(_ state: ShieldState, for origin: String) async
    func shield(for origin: String) async -> ShieldState
}

/// Per-origin blocking level. Users need an escape hatch for the sites that
/// break, and the escape hatch has to be one click from the toolbar.
public enum ShieldState: String, Codable, Sendable, CaseIterable {
    /// Ads, trackers and cookie walls all handled.
    case standard
    /// Blocking on, cosmetic filtering off. For sites whose layout breaks when
    /// elements are hidden.
    case blockingOnly
    /// Nothing blocked on this origin.
    case off
}

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
