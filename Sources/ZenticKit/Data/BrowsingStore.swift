import Foundation
import SwiftData

/// The session store: spaces, tabs, history, per-origin stats.
///
/// Main-actor bound on purpose. SwiftData's model objects are not `Sendable`, and
/// every one of them here is either being drawn by the sidebar or about to be, so
/// a background context would buy nothing but a class of crash. Everything is
/// single digits to low thousands of rows.
@MainActor
public final class BrowsingStore {
    public let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    /// The schema, in one place, so the store and its tests cannot disagree.
    public static let schema = Schema([
        Space.self, Tab.self, TabGroup.self, Folder.self, HistoryEntry.self, SiteStat.self,
    ])

    /// - Parameter url: store location, or nil for an in-memory store (tests).
    public init(url: URL?) throws {
        let configuration =
            if let url {
                ModelConfiguration(schema: Self.schema, url: url)
            } else {
                ModelConfiguration(schema: Self.schema, isStoredInMemoryOnly: true)
            }
        container = try ModelContainer(for: Self.schema, configurations: configuration)
    }

    /// `~/Library/Application Support/Zentic/Session.store`.
    ///
    /// Named explicitly rather than left to SwiftData's default, which derives a
    /// path from the main bundle identifier — nil for a SwiftPM executable, so the
    /// default lands somewhere unpredictable and moves when the app is bundled.
    public static func defaultStoreURL() throws -> URL {
        let directory = URL.applicationSupportDirectory.appending(
            path: "Zentic",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "Session.store")
    }

    public func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            // Losing a session is survivable; crashing the browser to report it is not.
            print("[zentic] store save failed: \(error)")
        }
    }

    // MARK: - Spaces

    public func spaces() -> [Space] {
        let descriptor = FetchDescriptor<Space>(sortBy: [SortDescriptor(\.sortIndex)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Fetch spaces, seeding the first-run set if the store is empty.
    ///
    /// Returning an empty list would be a broken window with no sidebar, so this
    /// is the one place that guarantees at least one space exists.
    public func spacesEnsuringDefault() -> [Space] {
        let existing = spaces()
        guard existing.isEmpty else { return existing }

        for (index, seed) in Space.firstRunSeeds.enumerated() {
            let space = Space(
                title: seed.title,
                tintHex: seed.tintHex,
                symbolName: seed.symbolName,
                sortIndex: index
            )
            context.insert(space)
        }
        save()
        return spaces()
    }

    @discardableResult
    public func addSpace(title: String, tintHex: String, symbolName: String) -> Space {
        let space = Space(
            title: title,
            tintHex: tintHex,
            symbolName: symbolName,
            sortIndex: spaces().count
        )
        context.insert(space)
        save()
        return space
    }

    // MARK: - Tabs

    /// Unpinned, ungrouped tabs of a space, in sidebar order.
    public func loadedTabs(in space: Space) -> [Tab] {
        space.tabs.sorted { $0.sortIndex < $1.sortIndex }
    }

    @discardableResult
    public func addTab(
        to space: Space,
        url: URL?,
        title: String = "",
        pinned: Bool = false,
        group: TabGroup? = nil,
        at index: Int? = nil
    ) -> Tab {
        let siblings = space.tabs.filter { $0.isPinned == pinned && $0.group === group }
        let tab = Tab(
            urlString: url?.absoluteString ?? "",
            title: title,
            isPinned: pinned,
            sortIndex: index ?? siblings.count,
            space: space,
            group: group
        )
        context.insert(tab)
        // The relationship is set through the inverse, but SwiftData only
        // materialises that after a save; the sidebar reads `space.tabs`
        // immediately, so link both sides now.
        space.tabs.append(tab)
        save()
        return tab
    }

    public func close(_ tab: Tab) {
        context.delete(tab)
        save()
    }

    /// Renumber `sortIndex` to match the given order. Called after a drag.
    public func reorder(_ tabs: [Tab]) {
        for (index, tab) in tabs.enumerated() where tab.sortIndex != index {
            tab.sortIndex = index
        }
        save()
    }

    public func tab(id: UUID) -> Tab? {
        var descriptor = FetchDescriptor<Tab>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: - Groups and folders

    @discardableResult
    public func addGroup(to space: Space, title: String) -> TabGroup {
        let group = TabGroup(title: title, sortIndex: space.groups.count, space: space)
        context.insert(group)
        space.groups.append(group)
        save()
        return group
    }

    @discardableResult
    public func addFolder(to space: Space, title: String, items: [Bookmark] = []) -> Folder {
        let folder = Folder(
            title: title,
            sortIndex: space.folders.count,
            items: items,
            space: space
        )
        context.insert(folder)
        space.folders.append(folder)
        save()
        return folder
    }

    // MARK: - History and stats

    /// Record a visit: append history and bump the origin's counter.
    ///
    /// Consecutive visits to the same URL collapse into the existing entry rather
    /// than appending — a page that redirects or fires `pushState` three times is
    /// one visit to a person, and three rows would flood ⌘K results.
    public func recordVisit(url: URL, title: String, at date: Date = .now) {
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }

        var recent = FetchDescriptor<HistoryEntry>(sortBy: [SortDescriptor(\.visitedAt, order: .reverse)])
        recent.fetchLimit = 1
        let latest = try? context.fetch(recent).first

        if let latest, latest.urlString == url.absoluteString {
            latest.visitedAt = date
            if !title.isEmpty { latest.title = title }
        } else {
            context.insert(
                HistoryEntry(urlString: url.absoluteString, title: title, visitedAt: date)
            )
        }

        if let origin = url.zenticOrigin {
            let stat = siteStat(for: origin) ?? {
                let created = SiteStat(origin: origin, visitCount: 0, lastVisitedAt: date)
                context.insert(created)
                return created
            }()
            stat.visitCount += 1
            stat.lastVisitedAt = date
        }

        save()
    }

    public func siteStat(for origin: String) -> SiteStat? {
        var descriptor = FetchDescriptor<SiteStat>(predicate: #Predicate { $0.origin == origin })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Most-visited origins first. M4's recipe-inference queue reads this.
    public func topSites(limit: Int = 50) -> [SiteStat] {
        var descriptor = FetchDescriptor<SiteStat>(
            sortBy: [SortDescriptor(\.visitCount, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Recent history, newest first. Capped because ⌘K only ever ranks a window
    /// of it and loading a year of browsing to score it would stall the palette.
    public func recentHistory(limit: Int = 2_000) -> [HistoryEntry] {
        var descriptor = FetchDescriptor<HistoryEntry>(
            sortBy: [SortDescriptor(\.visitedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    public func clearHistory() {
        try? context.delete(model: HistoryEntry.self)
        save()
    }
}

extension Space {
    /// First-run spaces. Two, not one, because a single space hides the fact that
    /// spaces exist at all.
    public static let firstRunSeeds:
        [(title: String, tintHex: String, symbolName: String)] = [
            (title: "Personal", tintHex: "#6E7BF2", symbolName: "house.fill"),
            (title: "Work", tintHex: "#E0764A", symbolName: "briefcase.fill"),
        ]
}
