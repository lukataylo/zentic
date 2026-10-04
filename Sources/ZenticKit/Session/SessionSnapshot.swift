import Foundation

/// Everything needed to put the user's windows back: each ordinary window's
/// frame and sidebar, its spaces, and every pinned and open tab in them.
/// Private windows are never in it.
///
/// Versioned. A file with no `version` is the single-window session Zentic
/// wrote before spaces existed, and is migrated rather than discarded. A file
/// from a *newer* Zentic fails to decode, which makes `JSONFile` set it aside
/// instead of letting the next save overwrite it.
public struct SessionSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 2

    public var version: Int
    public var windows: [Window]

    public init(windows: [Window]) {
        self.version = Self.currentVersion
        self.windows = windows
    }

    public struct Window: Codable, Sendable, Equatable {
        public var id: UUID
        /// Screen coordinates, AppKit's (origin bottom-left).
        public var frame: Frame?
        public var sidebarWidth: Double
        public var sidebarVisible: Bool
        public var spaces: [Space]
        public var selectedSpace: UUID?

        public init(
            id: UUID, frame: Frame?, sidebarWidth: Double, sidebarVisible: Bool, spaces: [Space],
            selectedSpace: UUID?
        ) {
            self.id = id
            self.frame = frame
            self.sidebarWidth = sidebarWidth
            self.sidebarVisible = sidebarVisible
            self.spaces = spaces
            self.selectedSpace = selectedSpace
        }
    }

    public struct Frame: Codable, Sendable, Equatable {
        public var x, y, width, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            (self.x, self.y, self.width, self.height) = (x, y, width, height)
        }
    }

    public struct Space: Codable, Sendable, Equatable {
        public var id: UUID
        public var name: String
        /// An SF Symbol name, or a single emoji.
        public var icon: String
        /// A `SidebarTint` raw value; nil means the app's default tint.
        public var tint: String?
        public var pinned: [Tab]
        public var tabs: [Tab]
        public var selected: UUID?

        public init(
            id: UUID, name: String, icon: String, tint: String?, pinned: [Tab], tabs: [Tab], selected: UUID?
        ) {
            self.id = id
            self.name = name
            self.icon = icon
            self.tint = tint
            self.pinned = pinned
            self.tabs = tabs
            self.selected = selected
        }
    }

    public struct Tab: Codable, Sendable, Equatable {
        public var id: UUID
        public var url: URL?
        public var title: String
        /// Where a pinned tab returns to when closed. Nil for an ordinary tab.
        public var pinnedURL: URL?

        public init(id: UUID, url: URL?, title: String, pinnedURL: URL? = nil) {
            self.id = id
            self.url = url
            self.title = title
            self.pinnedURL = pinnedURL
        }
    }

    /// Every tab id in the session — what the per-tab state files are pruned
    /// against.
    public var tabIDs: Set<UUID> {
        Set(windows.flatMap { $0.spaces.flatMap { ($0.pinned + $0.tabs).map(\.id) } })
    }

    // MARK: - Coding

    private enum CodingKeys: String, CodingKey { case version, windows }

    /// The pre-spaces session: one window, one list of tabs.
    private struct Version1: Decodable {
        var tabs: [Tab]
        var selected: UUID?
        var sidebarWidth: Double?
        var sidebarVisible: Bool?
    }

    public struct UnsupportedVersion: Error {
        public let version: Int
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let version = try container.decodeIfPresent(Int.self, forKey: .version) else {
            let legacy = try Version1(from: decoder)
            self.init(windows: [
                Window(
                    id: UUID(), frame: nil, sidebarWidth: legacy.sidebarWidth ?? 260,
                    sidebarVisible: legacy.sidebarVisible ?? true,
                    spaces: [
                        Space(
                            id: UUID(), name: Self.defaultSpaceName, icon: Self.defaultSpaceIcon, tint: nil,
                            pinned: [], tabs: legacy.tabs, selected: legacy.selected)
                    ],
                    selectedSpace: nil)
            ])
            return
        }
        guard version <= Self.currentVersion else { throw UnsupportedVersion(version: version) }
        self.init(windows: try container.decode([Window].self, forKey: .windows))
    }

    public static let defaultSpaceName = "Personal"
    public static let defaultSpaceIcon = "person.crop.circle"
}
