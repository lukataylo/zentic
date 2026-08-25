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
        // In sidebar order, because the insertion point is a position in that
        // order rather than a raw `sortIndex`. `close` deletes without renumbering,
        // so a run that has lost tabs is sparse — deriving a new index from
        // `siblings.count` against a sparse run lands the tab in the middle of it.
        let siblings = space.tabs
            .filter { $0.isPinned == pinned && $0.group === group }
            .sorted { $0.sortIndex < $1.sortIndex }
        let position = min(max(index ?? siblings.count, 0), siblings.count)

        let tab = Tab(
            urlString: url?.absoluteString ?? "",
            title: title,
            isPinned: pinned,
            sortIndex: position,
            space: space,
            group: group
        )
        context.insert(tab)
        // The relationship is set through the inverse, but SwiftData only
        // materialises that after a save; the sidebar reads `space.tabs`
        // immediately, so link both sides now.
        space.tabs.append(tab)

        // Renumber the whole run so the new tab owns its slot. Without this an
        // explicit index ties with the tab already holding it, and a tie sorts
        // arbitrarily — the new tab lands either side of its neighbour by luck.
        var ordered = siblings
        ordered.insert(tab, at: position)
        for (offset, sibling) in ordered.enumerated() where sibling.sortIndex != offset {
            sibling.sortIndex = offset
        }

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
            let stat = fetchOrCreateStat(origin, at: date)
            stat.visitCount += 1
            stat.lastVisitedAt = date
        }

        save()
    }

    /// Record what the reader decided about a page, so the next visit to this
    /// origin need not re-derive it from behind a hidden page.
    ///
    /// Keyed by origin rather than by URL: the point is to answer "should the next
    /// page here be hidden on arrival", which is asked before that page's URL is
    /// known. A single restructurable page resets the streak outright — being one
    /// page late to hide costs a single unstyled pageview, whereas staying wrong
    /// costs every pageview after it.
    public func recordReaderOutcome(origin: String, wouldRestructure: Bool, at date: Date = .now) {
        let stat = fetchOrCreateStat(origin, at: date)

        if wouldRestructure {
            guard stat.passthroughStreak != 0 else { return }
            stat.passthroughStreak = 0
        } else {
            // Stops climbing once it is past the threshold. Without the clamp a
            // site visited daily for a year would need a year of articles to earn
            // its way back, which is not a memory — it is a grudge.
            guard stat.passthroughStreak < Budget.instantOriginStreak else { return }
            stat.passthroughStreak += 1
        }
        save()
    }

    // MARK: - Levels

    /// The level a page from this origin should load at.
    ///
    /// Synchronous, and that is the requirement the whole design is built around:
    /// this decides `ReaderConfiguration.mode`, which rides on a `WKUserScript` and
    /// so has to be known *before* the web view is built. An actor-isolated store —
    /// `DesignStore`, `BlockerEngine` — cannot answer in time. A saved design can be
    /// applied after the reveal; a level cannot.
    public func level(for origin: String?, isRewriteEnabled: Bool = false) -> PageLevel {
        resolution(for: origin, isRewriteEnabled: isRewriteEnabled).level
    }

    /// The level and its no-override counterpart, in one fetch.
    ///
    /// One call rather than two, because the toolbar needs both and this reads the
    /// store — and the toolbar is refreshed on every title change, every favicon
    /// and every reveal. Callers cache the result and refresh it when the origin's
    /// memory actually changes, which is once per extraction rather than per frame.
    public func resolution(for origin: String?, isRewriteEnabled: Bool = false) -> LevelResolution {
        guard let origin, let stat = siteStat(for: origin) else {
            let fallback = LevelPolicy.resolve(SiteLevelInputs(isRewriteEnabled: isRewriteEnabled))
            return LevelResolution(level: fallback, automatic: fallback)
        }
        let inputs = stat.levelInputs(isRewriteEnabled: isRewriteEnabled)
        var automatic = inputs
        automatic.preference = .auto
        return LevelResolution(
            level: LevelPolicy.resolve(inputs),
            automatic: LevelPolicy.resolve(automatic)
        )
    }

    public func preference(for origin: String) -> SitePreference {
        siteStat(for: origin)?.preference ?? .auto
    }

    /// Record what the user asked for on this origin.
    ///
    /// A choice that matches what would have happened anyway is stored as `auto`
    /// rather than as a pin — the same trick `BlockerEngine.setShield` uses for
    /// `.standard`, and it earns its keep twice here: a site whose archetype memory
    /// later changes then follows the new default, instead of being frozen by a
    /// "choice" that was only ever agreement.
    public func setPreference(
        _ preference: SitePreference,
        for origin: String,
        isRewriteEnabled: Bool = false
    ) {
        let stat = fetchOrCreateStat(origin)

        if case .pinned(let level) = preference {
            var automatic = stat.levelInputs(isRewriteEnabled: isRewriteEnabled)
            automatic.preference = .auto
            if LevelPolicy.resolve(automatic) == level {
                stat.preference = .auto
                save()
                return
            }
        }

        stat.preference = preference
        save()
    }

    /// Remember what a page here turned out to be, so the *next* page from this
    /// origin can be resolved before it has been looked at.
    public func recordExtraction(
        origin: String,
        archetype: Archetype,
        isFidelitySensitive: Bool
    ) {
        let stat = fetchOrCreateStat(origin)
        var changed = false
        if stat.archetypeRaw != archetype.rawValue {
            stat.archetypeRaw = archetype.rawValue
            changed = true
        }
        // Monotone — one medical article makes this a site that publishes them.
        if isFidelitySensitive && !stat.fidelitySensitiveSeen {
            stat.fidelitySensitiveSeen = true
            changed = true
        }
        if changed { save() }
    }

    private func fetchOrCreateStat(_ origin: String, at date: Date = .now) -> SiteStat {
        if let existing = siteStat(for: origin) { return existing }
        let created = SiteStat(origin: origin, visitCount: 0, lastVisitedAt: date)
        context.insert(created)
        return created
    }

    /// Origins whose pages should be left visible while the reader works.
    public func instantOrigins() -> Set<String> {
        let threshold = Budget.instantOriginStreak
        let descriptor = FetchDescriptor<SiteStat>(
            predicate: #Predicate { $0.passthroughStreak >= threshold }
        )
        return Set((try? context.fetch(descriptor))?.map(\.origin) ?? [])
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
