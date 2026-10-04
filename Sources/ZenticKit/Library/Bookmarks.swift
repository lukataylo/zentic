import Foundation

/// A bookmark, or a folder of them.
///
/// Folders go one level deep and no further: a basic list someone can keep
/// tidy without a tree to manage. Anything deeper — from an import, or a file
/// edited by hand — is flattened into its top-level folder.
public struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    /// Nil for a folder.
    public var url: URL?
    /// A folder's bookmarks. Always empty for a bookmark.
    public var children: [Bookmark]

    public var isFolder: Bool { url == nil }

    public init(id: UUID = UUID(), title: String, url: URL?, children: [Bookmark] = []) {
        self.id = id
        self.title = title
        self.url = url
        self.children = url == nil ? children.flatMap(\.flattened) : []
    }

    public static func folder(_ title: String, _ children: [Bookmark] = []) -> Bookmark {
        Bookmark(title: title, url: nil, children: children)
    }

    /// The bookmarks in this item: itself, or a folder's contents at any depth.
    var flattened: [Bookmark] {
        isFolder ? children.flatMap(\.flattened) : [self]
    }

    private enum CodingKeys: String, CodingKey { case id, title, url, children }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id), title: try c.decode(String.self, forKey: .title),
            url: try c.decodeIfPresent(URL.self, forKey: .url),
            children: try c.decodeIfPresent([Bookmark].self, forKey: .children) ?? [])
    }
}

/// Every bookmark, in the user's order. Bookmarks and folders mix at the top
/// level; folders hold only bookmarks.
public struct BookmarkList: Codable, Equatable, Sendable {
    public private(set) var items: [Bookmark]

    public init(items: [Bookmark] = []) {
        self.items = items
    }

    /// Every bookmark, folders' contents included, in order.
    public var all: [Bookmark] { items.flatMap(\.flattened) }

    public var folders: [Bookmark] { items.filter(\.isFolder) }

    public func contains(_ url: URL) -> Bool {
        all.contains { $0.url?.absoluteString == url.absoluteString }
    }

    public func item(_ id: UUID) -> Bookmark? {
        for item in items {
            if item.id == id { return item }
            if let child = item.children.first(where: { $0.id == id }) { return child }
        }
        return nil
    }

    // MARK: Editing

    /// Add at the end of `folder`, or of the top level.
    @discardableResult
    public mutating func add(_ url: URL, title: String, in folder: UUID? = nil) -> UUID {
        let bookmark = Bookmark(title: title, url: url)
        append(bookmark, in: folder)
        return bookmark.id
    }

    @discardableResult
    public mutating func addFolder(_ title: String) -> UUID {
        let folder = Bookmark.folder(title)
        items.append(folder)
        return folder.id
    }

    public mutating func rename(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        update(id) { $0.title = title }
    }

    /// Removing a folder removes what is in it.
    public mutating func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        for index in items.indices { items[index].children.removeAll { ids.contains($0.id) } }
    }

    /// Reorder within one level, as `List.onMove` reports it.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int, in folder: UUID? = nil) {
        if let folder {
            guard let index = items.firstIndex(where: { $0.id == folder }) else { return }
            items[index].children.reorder(source, to: destination)
        } else {
            items.reorder(source, to: destination)
        }
    }

    /// Move a bookmark into `folder`, or out to the top level. Folders stay
    /// where they are: they cannot go inside one another.
    public mutating func move(_ id: UUID, into folder: UUID?) {
        guard let bookmark = item(id), !bookmark.isFolder, folder != id else { return }
        if let folder, item(folder)?.isFolder != true { return }
        remove([id])
        append(bookmark, in: folder)
    }

    /// Add what an import found, leaving out pages already bookmarked — so
    /// importing the same file twice adds nothing the second time. A folder
    /// with the name of an existing one is added to it. Returns how many
    /// bookmarks were added.
    @discardableResult
    public mutating func merge(_ imported: [Bookmark]) -> Int {
        var known = Set(all.compactMap { $0.url?.absoluteString })
        var added = 0
        func fresh(_ bookmarks: [Bookmark]) -> [Bookmark] {
            bookmarks.filter { bookmark in
                guard let key = bookmark.url?.absoluteString, known.insert(key).inserted else { return false }
                added += 1
                return true
            }
        }
        for item in imported {
            if item.isFolder {
                let children = fresh(item.children)
                guard !children.isEmpty else { continue }
                if let index = items.firstIndex(where: { $0.isFolder && $0.title == item.title }) {
                    items[index].children += children
                } else {
                    items.append(Bookmark(id: item.id, title: item.title, url: nil, children: children))
                }
            } else {
                items += fresh([item])
            }
        }
        return added
    }

    private mutating func append(_ bookmark: Bookmark, in folder: UUID?) {
        if let folder, let index = items.firstIndex(where: { $0.id == folder && $0.isFolder }) {
            items[index].children.append(bookmark)
        } else {
            items.append(bookmark)
        }
    }

    private mutating func update(_ id: UUID, _ change: (inout Bookmark) -> Void) {
        for index in items.indices {
            if items[index].id == id { return change(&items[index]) }
            if let child = items[index].children.firstIndex(where: { $0.id == id }) {
                return change(&items[index].children[child])
            }
        }
    }
}

extension Array {
    /// `List.onMove`'s reorder, which lives in SwiftUI; ZenticKit has no UI.
    mutating func reorder(_ source: IndexSet, to destination: Int) {
        let source = source.filter(indices.contains)
        let moving = source.map { self[$0] }
        let above = source.filter { $0 < destination }.count
        for index in source.reversed() { remove(at: index) }
        insert(contentsOf: moving, at: Swift.min(destination - above, count))
    }
}
