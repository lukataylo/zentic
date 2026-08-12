import Foundation
import SwiftData

// The persistent shape of a browsing session.
//
// Every stored property has a default value. That is not defensive style: it is
// what lets SwiftData add a property in a later schema without a hand-written
// migration stage, and a browser's session store is the last thing that should
// fail to open after an update.

/// A named workspace: its own tab set, its own sidebar tint.
///
/// Spaces are the unit of session restore. Everything the sidebar draws hangs off
/// one, so restoring a session is "fetch spaces, sort, rebuild".
@Model
public final class Space {
    /// Stable identity used by the UI and by ``TabResidency``. Distinct from
    /// SwiftData's `persistentModelID`, which is not stable across store
    /// migrations and cannot be embedded in a snapshot filename or a menu tag.
    public var id: UUID = UUID()
    public var title: String = "Space"
    /// Seed colour for the sidebar gradient, `#rrggbb`.
    public var tintHex: String = "#6E7BF2"
    /// SF Symbol shown in the space switcher.
    public var symbolName: String = "circle.fill"
    public var sortIndex: Int = 0
    public var createdAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \Tab.space)
    public var tabs: [Tab] = []

    @Relationship(deleteRule: .cascade, inverse: \TabGroup.space)
    public var groups: [TabGroup] = []

    @Relationship(deleteRule: .cascade, inverse: \Folder.space)
    public var folders: [Folder] = []

    public init(
        id: UUID = UUID(),
        title: String,
        tintHex: String = "#6E7BF2",
        symbolName: String = "circle.fill",
        sortIndex: Int = 0,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.tintHex = tintHex
        self.symbolName = symbolName
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}

/// One tab, live or suspended.
///
/// A tab's record is authoritative even while its `WKWebView` exists: the shell
/// writes URL, title and scroll position back as they change, so suspending is
/// only ever "capture what is not already here, then drop the web view".
@Model
public final class Tab {
    public var id: UUID = UUID()
    public var urlString: String = ""
    public var title: String = ""
    public var faviconData: Data?

    /// Pinned tabs render in the favicon grid at the top of the sidebar and are
    /// never closed by ⌘W (they revert to their pinned URL instead).
    public var isPinned: Bool = false
    /// Position within its container — the pinned grid, a group, or the flat list.
    public var sortIndex: Int = 0
    public var createdAt: Date = Date.now
    /// Drives LRU ordering on restore, so a restored session suspends the same
    /// tabs the previous session had suspended.
    public var lastActivatedAt: Date = Date.now

    // MARK: Suspension state

    /// Vertical scroll offset in CSS pixels.
    ///
    /// Kept alongside `interactionState` because the two have different
    /// lifetimes: `interactionState` is opaque and WebKit may reject it after an
    /// OS update, in which case a plain reload plus this offset still lands the
    /// user near where they were.
    public var scrollY: Double = 0
    /// `WKWebView.interactionState` — the session's back/forward list and scroll
    /// position in WebKit's own opaque format. Optional by design: it is a fast
    /// path, and a nil value degrades to reloading `urlString`.
    @Attribute(.externalStorage) public var interactionState: Data?
    /// JPEG of the page as it looked when suspended, shown while the restored
    /// web view loads so switching to a suspended tab does not flash empty.
    @Attribute(.externalStorage) public var snapshotData: Data?
    public var canGoBack: Bool = false
    public var canGoForward: Bool = false

    public var space: Space?
    public var group: TabGroup?

    public init(
        id: UUID = UUID(),
        urlString: String,
        title: String = "",
        isPinned: Bool = false,
        sortIndex: Int = 0,
        space: Space? = nil,
        group: TabGroup? = nil
    ) {
        self.id = id
        self.urlString = urlString
        self.title = title
        self.isPinned = isPinned
        self.sortIndex = sortIndex
        self.space = space
        self.group = group
        self.createdAt = .now
        self.lastActivatedAt = .now
    }

    public var url: URL? { URL(string: urlString) }

    /// Title for the sidebar: real title, else host, else the raw string.
    public var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host() { return host }
        return urlString.isEmpty ? "New Tab" : urlString
    }
}

/// A collapsible run of tabs inside a space.
///
/// There is deliberately no parent link. Tab trees deeper than one level are on
/// the YAGNI list, and enforcing that in the schema means no UI code can produce
/// one by accident.
@Model
public final class TabGroup {
    public var id: UUID = UUID()
    public var title: String = "Group"
    public var isExpanded: Bool = true
    public var sortIndex: Int = 0
    public var space: Space?

    @Relationship(deleteRule: .nullify, inverse: \Tab.group)
    public var tabs: [Tab] = []

    public init(
        id: UUID = UUID(),
        title: String,
        isExpanded: Bool = true,
        sortIndex: Int = 0,
        space: Space? = nil
    ) {
        self.id = id
        self.title = title
        self.isExpanded = isExpanded
        self.sortIndex = sortIndex
        self.space = space
    }
}

/// A saved set of links. Folders hold bookmarks, not tabs — opening one creates
/// a tab, closing that tab leaves the folder untouched.
@Model
public final class Folder {
    public var id: UUID = UUID()
    public var title: String = "Folder"
    public var isExpanded: Bool = false
    public var sortIndex: Int = 0
    /// Stored as a composite attribute rather than a relationship: bookmarks are
    /// value-like, never referenced from anywhere else, and always loaded with
    /// their folder.
    public var items: [Bookmark] = []
    public var space: Space?

    public init(
        id: UUID = UUID(),
        title: String,
        isExpanded: Bool = false,
        sortIndex: Int = 0,
        items: [Bookmark] = [],
        space: Space? = nil
    ) {
        self.id = id
        self.title = title
        self.isExpanded = isExpanded
        self.sortIndex = sortIndex
        self.items = items
        self.space = space
    }
}

public struct Bookmark: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var urlString: String

    public init(id: UUID = UUID(), title: String, urlString: String) {
        self.id = id
        self.title = title
        self.urlString = urlString
    }
}

/// One visit. Feeds ⌘K search.
@Model
public final class HistoryEntry {
    public var id: UUID = UUID()
    public var urlString: String = ""
    public var title: String = ""
    public var visitedAt: Date = Date.now

    public init(id: UUID = UUID(), urlString: String, title: String, visitedAt: Date = .now) {
        self.id = id
        self.urlString = urlString
        self.title = title
        self.visitedAt = visitedAt
    }
}

/// Per-origin visit counter.
///
/// This exists for M4: recipe inference is expensive, so it runs against the
/// user's own most-visited origins rather than every site they touch once
/// (``Budget/inferenceVisitThreshold``). The counter has to start accumulating in
/// M1 or M4 ships with an empty ranking.
@Model
public final class SiteStat {
    /// Scheme + host, e.g. `https://example.com`. Unique, so the increment path
    /// can rely on fetch-or-create.
    @Attribute(.unique) public var origin: String = ""
    public var visitCount: Int = 0
    public var lastVisitedAt: Date = Date.now
    /// When a recipe was last inferred for this origin, for the 30-day refresh
    /// (``Budget/recipeMaxAge``). Unused until M4.
    public var recipeGeneratedAt: Date?

    public init(origin: String, visitCount: Int = 0, lastVisitedAt: Date = .now) {
        self.origin = origin
        self.visitCount = visitCount
        self.lastVisitedAt = lastVisitedAt
    }

    /// Whether this origin has earned background recipe inference.
    public var deservesRecipeInference: Bool {
        guard visitCount >= Budget.inferenceVisitThreshold else { return false }
        guard let generated = recipeGeneratedAt else { return true }
        return Date.now.timeIntervalSince(generated) > Budget.recipeMaxAge
    }
}

// MARK: - Origins

extension URL {
    /// Scheme + host, the key ``SiteStat`` and recipes are filed under.
    ///
    /// Port is dropped and `www.` is not stripped: recipes key off the host a
    /// user actually visits, and treating `www.` as equivalent would merge two
    /// sites that occasionally do differ in markup.
    public var zenticOrigin: String? {
        guard let scheme, let host = host(), !host.isEmpty else { return nil }
        return "\(scheme)://\(host)"
    }
}
