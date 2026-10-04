import AppKit
import Foundation
import Observation
import SwiftUI
import ZenticKit

/// State that outlives any one window: what the user chose for each site,
/// favourites, history and preferences. Saved as it changes.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: Sites

    private(set) var book: SiteBook {
        didSet {
            guard book != oldValue else { return }
            bookFile.save(book)
            onSitesChanged.forEach { $0(oldValue, book) }
        }
    }
    @ObservationIgnored var onSitesChanged: [(SiteBook, SiteBook) -> Void] = []

    func mode(for url: URL?) -> SiteMode {
        SiteKey.isWeb(url) ? book.mode(for: SiteKey.for(url)) : .original
    }

    func custom(for url: URL?) -> CustomVersion? { book.custom(for: SiteKey.for(url)) }

    func setMode(_ mode: SiteMode, for url: URL?) {
        guard let key = SiteKey.for(url) else { return }
        book.setMode(mode, for: key)
    }

    func saveCustom(_ version: CustomVersion, for url: URL?) {
        guard let key = SiteKey.for(url) else { return }
        book.saveCustom(version, for: key)
    }

    func removeCustom(forKey key: String) { book.removeCustom(for: key) }
    func forgetSite(_ key: String) { book.forget(key) }

    var defaultMode: SiteMode {
        get { book.defaultMode }
        set { book.defaultMode = newValue == .custom ? .clean : newValue }
    }

    var sites: [(key: String, settings: SiteSettings)] {
        book.sites.map { ($0.key, $0.value) }.sorted { $0.key < $1.key }
    }

    // MARK: Favourites

    private(set) var favorites: [Favorite] { didSet { favoritesFile.save(favorites) } }

    func isFavorite(_ url: URL?) -> Bool {
        guard let key = SiteKey.for(url) else { return false }
        return favorites.contains { SiteKey.for($0.url) == key }
    }

    /// From a tab in `browser`. Never a private window's page: favourites are
    /// written to disk and shown in every window.
    func addFavorite(url: URL, title: String, from browser: Browser) {
        guard !browser.isPrivate, !isFavorite(url) else { return }
        favorites.append(Favorite(id: UUID(), url: url, title: title))
    }

    func removeFavorite(_ id: UUID) { favorites.removeAll { $0.id == id } }

    // MARK: History

    @ObservationIgnored private var history: [String: HistoryEntry]
    @ObservationIgnored private var historySaveTask: Task<Void, Never>?
    /// Bumped on every change, so the History window — the one view that
    /// shows history rather than searching it — redraws without observing a
    /// dictionary of thousands of entries.
    private(set) var historyRevision = 0
    /// History writes, in order, off the main thread: a clear must never be
    /// overtaken by an older save still on its way to disk.
    @ObservationIgnored private let historyIO = DispatchQueue(label: "Zentic.history", qos: .utility)

    var historyEntries: Dictionary<String, HistoryEntry>.Values { history.values }

    func recordVisit(url: URL, title: String) {
        guard SiteKey.isWeb(url) else { return }
        let key = url.absoluteString
        var entry = history[key] ?? HistoryEntry(url: url, title: title, lastVisit: .now, visits: 0)
        entry.visits += 1
        entry.lastVisit = .now
        if !title.isEmpty { entry.title = title }
        history[key] = entry
        historyRevision += 1
        scheduleHistorySave()
    }

    func searchHistory(_ query: String, limit: Int = 6) -> [HistoryEntry] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return history.values
            .compactMap { entry -> (HistoryEntry, Double)? in
                let url = entry.searchURL
                let host = entry.searchHost
                let title = entry.searchTitle
                var score = 0.0
                if host.hasPrefix(q) { score += 6 }
                else if url.contains(q) { score += 2 }
                if title.hasPrefix(q) { score += 4 }
                else if title.contains(q) { score += 2 }
                guard score > 0 else { return nil }
                let age = Date.now.timeIntervalSince(entry.lastVisit) / 86_400
                score += log2(Double(entry.visits) + 1) - min(age / 14, 3)
                // Shorter URLs first among equals: the site, not a deep page on it.
                score -= Double(url.count) / 400
                return (entry, score)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    func removeHistory(_ urls: some Sequence<URL>) {
        for url in urls { history[url.absoluteString] = nil }
        historyRevision += 1
        saveHistorySoon()
    }

    func clearHistory(_ range: HistoryRange) {
        let kept = range.kept(Array(history.values), now: .now, calendar: .current)
        history = Dictionary(kept.map { ($0.url.absoluteString, $0) }, uniquingKeysWith: { a, _ in a })
        historyRevision += 1
        saveHistorySoon()
        // Site icons too, but those of what is still in use: open tabs,
        // favourites, saved passwords and the history that is left.
        let tabs = (Windows.shared.open + Windows.shared.waitingToOpen).flatMap(\.allTabs)
        let urls = kept.map(\.url) + favorites.map(\.url) + tabs.compactMap(\.url) + tabs.compactMap(\.pinnedURL)
        var sites = Set(urls.compactMap(SiteKey.for))
        sites.formUnion(Passwords.shared.logins.map(\.origin.siteKey))
        Favicons.shared.forget(keeping: sites)
    }

    /// After the user deleted something: now, not in two seconds, so a crash
    /// in between cannot bring it back.
    private func saveHistorySoon() {
        historySaveTask?.cancel()
        guard historyLoaded else { return }
        let entries = historySnapshot()
        let file = historyFile
        historyIO.async { file.save(entries) }
    }

    private func scheduleHistorySave() {
        historySaveTask?.cancel()
        historySaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.historyLoaded else { return }
            // Encoding thousands of entries is off the main thread: a page
            // visit must never cost a frame.
            let entries = self.historySnapshot()
            let file = self.historyFile
            self.historyIO.async { file.save(entries) }
        }
    }

    /// Not until the file has been read: saving a half-loaded history would
    /// overwrite the rest of it — and clearing it would be undone by the load.
    private(set) var historyLoaded = false

    /// Synchronous, for app termination.
    func saveHistoryNow() {
        guard historyLoaded else { return }
        historySaveTask?.cancel()
        let entries = historySnapshot()
        let file = historyFile
        historyIO.sync { file.save(entries) }
    }

    private func historySnapshot() -> [HistoryEntry] {
        let kept = Array(history.values.sorted { $0.lastVisit > $1.lastVisit }.prefix(Self.historyLimit))
        // The file is capped; memory is kept to the same cap.
        if kept.count < history.count {
            history = Dictionary(kept.map { ($0.url.absoluteString, $0) }, uniquingKeysWith: { a, _ in a })
        }
        return kept
    }

    static let historyLimit = 5000

    // MARK: Preferences

    var searchEngine: URLGuess.SearchEngine {
        didSet { defaults.set(searchEngine.rawValue, forKey: "searchEngine") }
    }
    var model: String {
        didSet { defaults.set(model, forKey: "openAIModel") }
    }
    /// How much of the desktop shows through the window frame, 0…1.
    var translucency: Double {
        didSet { defaults.set(translucency, forKey: "translucency") }
    }
    var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appearance")
            appearance.apply()
        }
    }
    /// Bookmarks are hidden unless asked for: no menu, no window, nothing in
    /// the address bar. Favourites and history do most of their job.
    var showsBookmarks: Bool {
        didSet { defaults.set(showsBookmarks, forKey: "showsBookmarks") }
    }
    /// Whether a key is stored, kept here so views never ask the Keychain on
    /// every redraw.
    private(set) var hasAPIKey: Bool

    func saveAPIKey(_ key: String) throws {
        try APIKeyStore.save(key, for: .openAI)
        hasAPIKey = APIKeyStore.has(.openAI)
    }

    func removeAPIKey() {
        APIKeyStore.remove(.openAI)
        hasAPIKey = false
    }

    func designer() throws -> OpenAIDesigner {
        guard let key = APIKeyStore.load(.openAI) else { throw DesignError.noKey }
        return OpenAIDesigner(apiKey: key, model: model)
    }

    // MARK: -

    @ObservationIgnored private let defaults = DataDirectory.defaults
    @ObservationIgnored private let bookFile = JSONFile<SiteBook>(name: "sites.json")
    @ObservationIgnored private let favoritesFile = JSONFile<[Favorite]>(name: "favorites.json")
    @ObservationIgnored private let historyFile = JSONFile<[HistoryEntry]>(name: "history.json")

    private init() {
        book = bookFile.load() ?? SiteBook()
        favorites =
            favoritesFile.load() ?? [
                Favorite(id: UUID(), url: URL(string: "https://en.wikipedia.org")!, title: "Wikipedia"),
                Favorite(id: UUID(), url: URL(string: "https://news.ycombinator.com")!, title: "Hacker News"),
                Favorite(id: UUID(), url: URL(string: "https://www.theguardian.com")!, title: "The Guardian"),
                Favorite(id: UUID(), url: URL(string: "https://github.com")!, title: "GitHub"),
            ]
        history = [:]
        searchEngine = defaults.string(forKey: "searchEngine").flatMap(URLGuess.SearchEngine.init) ?? .duckDuckGo
        model = defaults.string(forKey: "openAIModel") ?? OpenAIDesigner.defaultModel
        hasAPIKey = APIKeyStore.has(.openAI)
        translucency = defaults.object(forKey: "translucency") as? Double ?? 0.85
        appearance = defaults.string(forKey: "appearance").flatMap(AppAppearance.init) ?? .system
        showsBookmarks = defaults.bool(forKey: "showsBookmarks")
        appearance.apply()

        // History is not shown at launch: decode it off the
        // main thread so it never delays the first window.
        let file = historyFile
        Task { [weak self] in
            let entries = await Task.detached(priority: .utility) { file.load() ?? [] }.value
            guard let self else { return }
            for entry in entries where self.history[entry.url.absoluteString] == nil {
                self.history[entry.url.absoluteString] = entry
            }
            self.historyLoaded = true
            self.historyRevision += 1
        }
    }
}

struct Favorite: Codable, Identifiable, Hashable {
    var id: UUID
    var url: URL
    var title: String
}

/// The colour the window frame and sidebar are washed with — each space has one.
enum SidebarTint: String, CaseIterable, Identifiable {
    case indigo, graphite, rose, forest, ocean, ember
    var id: String { rawValue }

    /// For a space with no tint of its own: the one window tint Zentic had
    /// before spaces, if the user picked one.
    static var `default`: SidebarTint {
        DataDirectory.defaults.string(forKey: "sidebarTint").flatMap(SidebarTint.init) ?? .indigo
    }

    var title: String { rawValue.capitalized }

    /// Top-leading → bottom-trailing gradient, per appearance.
    func colors(dark: Bool) -> [Color] {
        switch (self, dark) {
        case (.indigo, true): [Color(red: 0.20, green: 0.13, blue: 0.48), Color(red: 0.11, green: 0.10, blue: 0.36)]
        case (.indigo, false): [Color(red: 0.80, green: 0.79, blue: 0.97), Color(red: 0.89, green: 0.84, blue: 0.98)]
        case (.graphite, true): [Color(white: 0.17), Color(white: 0.11)]
        case (.graphite, false): [Color(white: 0.90), Color(white: 0.86)]
        case (.rose, true): [Color(red: 0.36, green: 0.12, blue: 0.24), Color(red: 0.22, green: 0.09, blue: 0.20)]
        case (.rose, false): [Color(red: 0.98, green: 0.85, blue: 0.89), Color(red: 0.96, green: 0.88, blue: 0.94)]
        case (.forest, true): [Color(red: 0.08, green: 0.24, blue: 0.19), Color(red: 0.06, green: 0.15, blue: 0.14)]
        case (.forest, false): [Color(red: 0.82, green: 0.93, blue: 0.87), Color(red: 0.88, green: 0.94, blue: 0.90)]
        case (.ocean, true): [Color(red: 0.06, green: 0.20, blue: 0.36), Color(red: 0.05, green: 0.12, blue: 0.26)]
        case (.ocean, false): [Color(red: 0.80, green: 0.90, blue: 0.98), Color(red: 0.86, green: 0.92, blue: 0.98)]
        case (.ember, true): [Color(red: 0.36, green: 0.16, blue: 0.08), Color(red: 0.22, green: 0.10, blue: 0.08)]
        case (.ember, false): [Color(red: 0.99, green: 0.88, blue: 0.80), Color(red: 0.98, green: 0.92, blue: 0.86)]
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    @MainActor func apply() {
        NSApp?.appearance =
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
    }
}
