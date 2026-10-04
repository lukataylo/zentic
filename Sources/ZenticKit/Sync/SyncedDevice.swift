import Foundation

/// One Mac's open tabs, as the others see them: its name, what kind of Mac it
/// is, and its spaces with their pinned and open tabs. Titles and addresses
/// only — never history, site choices, passwords or anything from a private
/// window (the session it is built from never contains one).
///
/// One per device, replaced whole each time that device sends: there is
/// nothing to merge inside a record, because only its own Mac ever writes it.
public struct SyncedDevice: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case laptop, desktop

        public var symbol: String { self == .laptop ? "laptopcomputer" : "desktopcomputer" }
    }

    public struct Space: Codable, Sendable, Equatable {
        public var name: String
        /// An SF Symbol name or a single emoji, as the space on that Mac has.
        public var icon: String
        public var pinned: [Tab]
        public var tabs: [Tab]

        public init(name: String, icon: String, pinned: [Tab], tabs: [Tab]) {
            self.name = name
            self.icon = icon
            self.pinned = pinned
            self.tabs = tabs
        }

        public var allTabs: [Tab] { pinned + tabs }
    }

    public struct Tab: Codable, Sendable, Hashable {
        public var title: String
        public var url: URL

        public init(title: String, url: URL) {
            self.title = title
            self.url = url
        }
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// When that Mac last sent its tabs.
    public var modified: Date
    public var spaces: [Space]

    public init(id: String, name: String, kind: Kind, modified: Date, spaces: [Space]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.modified = modified
        self.spaces = spaces
    }

    public var allTabs: [Tab] { spaces.flatMap(\.allTabs) }
    public var tabCount: Int { spaces.reduce(0) { $0 + $1.pinned.count + $1.tabs.count } }

    /// Whether sending `other` would tell the other Macs anything new. The
    /// send time is not news: without this, every tab switch would be a write.
    public func hasSameContent(as other: SyncedDevice) -> Bool {
        name == other.name && kind == other.kind && spaces == other.spaces
    }
}

// MARK: - From the session

extension SyncedDevice {
    /// Roughly how many bytes of tabs one record may carry. CloudKit refuses a
    /// record over 1 MB; this leaves room for the rest of the record and for
    /// JSON's escaping, and is still hundreds of ordinary tabs.
    public static let byteBudget = 300_000
    /// Titles past this are cut. Nobody reads a 2 000-character title in a
    /// sidebar, and a page can set any title it likes.
    public static let maxTitleLength = 200

    /// The tabs worth sending from a session: every window's spaces, merged by
    /// name (two windows each with a "Work" space are one "Work" to someone
    /// reading them from another Mac), web pages only, each address once per
    /// space, a pinned tab's current page rather than its pinned one.
    ///
    /// Stops adding tabs once `byteBudget` is spent, so a vast session sends
    /// its first spaces whole rather than failing to send at all.
    public static func spaces(from session: SessionSnapshot) -> [Space] {
        var spaces: [Space] = []
        var seen: [String: Set<URL>] = [:]
        var bytes = 0

        func admit(_ tab: SessionSnapshot.Tab) -> Tab? {
            guard let url = tab.url ?? tab.pinnedURL, SiteKey.isWeb(url) else { return nil }
            let title = String(tab.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTitleLength))
            // The fields' own bytes plus a little for the JSON around them.
            let cost = url.absoluteString.utf8.count + title.utf8.count + 32
            guard bytes + cost <= byteBudget else { return nil }
            bytes += cost
            return Tab(title: title, url: url)
        }

        for window in session.windows {
            for space in window.spaces {
                let index: Int
                if let existing = spaces.firstIndex(where: { $0.name == space.name }) {
                    index = existing
                } else {
                    spaces.append(Space(name: space.name, icon: space.icon, pinned: [], tabs: []))
                    index = spaces.count - 1
                }
                for (tabs, pinned) in [(space.pinned, true), (space.tabs, false)] {
                    for saved in tabs {
                        // Checked before admitting, so a duplicate spends none of the budget.
                        guard let url = saved.url ?? saved.pinnedURL, !seen[space.name, default: []].contains(url),
                            let tab = admit(saved)
                        else { continue }
                        seen[space.name, default: []].insert(url)
                        if pinned { spaces[index].pinned.append(tab) } else { spaces[index].tabs.append(tab) }
                    }
                }
            }
        }
        return spaces.filter { !$0.allTabs.isEmpty }
    }
}
