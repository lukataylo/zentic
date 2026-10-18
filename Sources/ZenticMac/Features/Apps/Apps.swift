import AppKit
import Observation
import ZenticKit

/// Sites the user keeps a database of, what has been captured from them, and the
/// apps prompted over the result.
///
/// ## The model boundary
///
/// Two calls leave the Mac, both with the user's own key: recipe inference (a
/// response's shape, never its values; see `ShapeSummary`) and app generation
/// (an `AppBrief`, which the composer describes before it is sent). Generated
/// apps have no route to a model or the network — see `AppSandbox`. The guard is
/// a place: ``generate(prompt:sources:revising:)`` is the only function that
/// sends a brief.
@MainActor
@Observable
final class Apps {
    static let shared = Apps()

    /// Sources, in the order they were added.
    private(set) var sources: [Source] = []
    private(set) var apps: [GeneratedApp] = []
    /// Records per source, as stored — a count of things the user saw, never an
    /// estimate.
    private(set) var recordCounts: [String: Int] = [:]
    /// The app being designed, while it is. One at a time.
    private(set) var generation: Generation?
    /// Icons drawn for apps, by app id. An app without one shows its symbol.
    private(set) var icons: [String: NSImage] = [:]
    /// Apps whose icon is being drawn right now.
    private(set) var drawingIcons: Set<String> = []

    struct Generation: Equatable {
        enum Phase: Equatable {
            case working
            case failed(String)
        }
        let id = UUID()
        let prompt: String
        let origins: [String]
        let started: Date
        /// The app being revised, or nil for a new one.
        let revising: String?
        var phase: Phase = .working
    }

    @ObservationIgnored private let library: SourceLibrary?
    @ObservationIgnored let store = AppStore()
    @ObservationIgnored let media = MediaCache()
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var pendingChanges: Set<String> = []
    @ObservationIgnored private var changeFlush: Task<Void, Never>?
    @ObservationIgnored private lazy var refresher = SourceRefresher(apps: self)
    @ObservationIgnored private var loaded = false

    private init() {
        do {
            library = try SourceLibrary(url: RecordStore.defaultURL, inferrer: KeyedInferrer())
        } catch {
            // A library that will not open must not cost the user a browser.
            trace("apps", "library unavailable: \(error)")
            library = nil
        }
    }

    /// Read what is on disk. Called once, after the first window is up.
    func load() async {
        guard !loaded, let library else { return }
        loaded = true
        sources = await library.sources()
        apps = await store.all()
        await loadIcons()
        await refreshCounts()
        refresher.start()
    }

    /// Re-read the apps on disk — after a test or another copy of the app wrote one.
    func reloadApps() async {
        apps = await store.all()
        await loadIcons()
    }

    private func loadIcons() async {
        var loaded: [String: NSImage] = [:]
        for app in apps {
            if let data = await store.icon(id: app.id), let image = NSImage(data: data) { loaded[app.id] = image }
        }
        icons = loaded
    }

    // MARK: - Sources

    /// The key the library files a site under: scheme and host without `www.`,
    /// so `www.example.com` and `example.com` are one source, as they are one
    /// site everywhere else in Zentic.
    nonisolated static func originKey(scheme: String, host: String) -> String {
        "\(scheme.lowercased())://\(SiteKey.for(host: host))"
    }

    nonisolated static func originKey(_ url: URL?) -> String? {
        guard let url, SiteKey.isWeb(url), let scheme = url.scheme, let host = url.host(percentEncoded: false), !host.isEmpty
        else { return nil }
        return originKey(scheme: scheme, host: host)
    }

    func isSource(_ url: URL?) -> Bool {
        guard let key = Self.originKey(url) else { return false }
        return sources.contains { $0.origin == key }
    }

    func source(_ origin: String) -> Source? { sources.first { $0.origin == origin } }

    /// Site keys of every source, for the recorder's gate in each page.
    var sourceSites: Set<String> {
        Set(sources.compactMap { URL(string: $0.origin)?.host(percentEncoded: false) }.map { SiteKey.for(host: $0) })
    }

    /// Start keeping a database of a site. Signed-in sites update only as the
    /// user browses them; refreshing signed out is the user's choice to make, in
    /// the site's popover or Settings, never a default.
    func addSource(url: URL, title: String) async {
        guard let library, let origin = Self.originKey(url), let host = url.host(percentEncoded: false) else { return }
        _ = try? await library.addSource(
            origin: origin, title: SiteKey.for(host: host), homeURL: url.absoluteString, refresh: .browse)
        sources = await library.sources()
        Windows.shared.librarySourcesChanged()
        Breadcrumbs.note("Added a source", in: nil)
    }

    func removeSource(_ origin: String) async {
        guard let library else { return }
        try? await library.removeSource(origin: origin)
        sources = await library.sources()
        recordCounts[origin] = nil
        Windows.shared.librarySourcesChanged()
        noteChange(in: [origin])
    }

    /// How a source stays fresh. Signed out revisits the front page — what a
    /// stranger sees; signed in revisits the page the source was added from, which
    /// is the view the user wanted kept (their timeline, not x.com's landing page).
    func setRefresh(_ refresh: Source.Refresh, for origin: String) async {
        guard let library, var source = await library.source(origin) else { return }
        source.refresh = refresh
        if refresh == .background { source.homeURL = origin + "/" }
        await library.update(source)
        sources = await library.sources()
    }

    // MARK: - Ingest

    /// A response a source page fetched.
    ///
    /// - Parameters:
    ///   - frameOrigin: The sending frame's origin, as WebKit reported it. The
    ///     capture is filed under this and nothing else: not the payload's URL,
    ///     which page script wrote, and not the tab's URL, which moves to the
    ///     next page before the last messages from this one arrive.
    ///   - pageURL: For resolving relative links, and only when it is still the
    ///     same site as the frame.
    func ingest(_ capture: CapturePayload, frameScheme: String, frameHost: String, pageURL: URL?) {
        let origin = Self.originKey(scheme: frameScheme, host: frameHost)
        guard let library, sources.contains(where: { $0.origin == origin }) else { return }
        let page = Self.originKey(pageURL) == origin ? pageURL : URL(string: origin + "/")
        Task {
            let outcome = await library.ingest(capture, pageOrigin: origin, pageURL: page)
            switch outcome {
            case .mapped(let count) where count > 0:
                sources = await library.sources()
                noteChange(in: [origin])
            case .awaitingRecipe:
                // Inference ran inside `ingest`; if it produced a recipe, the
                // stored responses were re-mapped and there may be records now.
                sources = await library.sources()
                noteChange(in: [origin])
            default:
                break
            }
            await fetchPendingMedia(for: origin)
        }
    }

    /// Cache the images captures just referred to, then tell apps they are there.
    private func fetchPendingMedia(for origin: String) async {
        guard let library else { return }
        let urls = await library.takePendingMedia()
        guard !urls.isEmpty else { return }
        if await media.fetch(urls) > 0 { noteChange(in: [origin]) }
    }

    /// Coalesced: a scroll on a source lands as a burst of captures.
    func noteChange(in origins: Set<String>) {
        pendingChanges.formUnion(origins)
        guard changeFlush == nil else { return }
        changeFlush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            let changed = pendingChanges
            pendingChanges = []
            changeFlush = nil
            await refreshCounts()
            for tab in Windows.shared.everyTab {
                guard let id = tab.appID, let app = apps.first(where: { $0.id == id }),
                    !changed.isDisjoint(with: app.sources)
                else { continue }
                tab.notifyLibraryChanged()
            }
        }
    }

    private func refreshCounts() async {
        guard let library else { return }
        var counts: [String: Int] = [:]
        for source in sources { counts[source.origin] = await library.recordCount(source: source.origin) }
        if counts != recordCounts { recordCounts = counts }
    }

    // MARK: - Reads for apps

    /// What an app has been served this session, for its links (``linkAllowance(for:)``)
    /// and its images (``mayServeMedia(_:to:)``). In memory only: after a relaunch
    /// an app queries again before it can show a link to anything.
    @ObservationIgnored private var allowances: [String: AppSandbox.LinkAllowance] = [:]
    @ObservationIgnored private var servedMedia: [String: Set<String>] = [:]

    func records(_ query: RecordQuery, for app: GeneratedApp) async -> [SourceRecord] {
        let records = await library?.records(matching: query, allowedSources: Set(app.sources)) ?? []
        allowances[app.id, default: AppSandbox.LinkAllowance()].note(records)
        return records
    }

    func linkAllowance(for appID: String) -> AppSandbox.LinkAllowance {
        allowances[appID] ?? AppSandbox.LinkAllowance()
    }

    func noteServedMedia(_ keys: some Sequence<String>, for appID: String) {
        servedMedia[appID, default: []].formUnion(keys)
    }

    func mayServeMedia(_ key: String, to appID: String) -> Bool {
        servedMedia[appID]?.contains(key) ?? false
    }

    func app(_ id: String?) -> GeneratedApp? {
        guard let id else { return nil }
        return apps.first { $0.id == id }
    }

    /// Whether nothing has arrived from any of an app's sources for a day.
    func isStale(_ app: GeneratedApp) -> Bool {
        let newest = app.sources.compactMap { source($0)?.lastCapturedAt }.max()
        return newest.map { Date.now.timeIntervalSince($0) > LibraryBudget.staleSourceAge } ?? true
    }

    // MARK: - Apps

    /// Design a new app, or the next version of one.
    ///
    /// The only place an `AppBrief` is built and sent; it contains exactly what
    /// the composer tells the user it will. Runs on its own — closing the
    /// composer does not stop it — and lands in the sidebar when done.
    ///
    /// - Parameter opening: called with the app once it is saved, if the user is
    ///   still waiting for it.
    func generate(
        prompt: String, sources origins: [String], revising existing: GeneratedApp?,
        opening: @escaping @MainActor (GeneratedApp) -> Void
    ) {
        guard generation?.phase != .working, let library else { return }
        let generation = Generation(prompt: prompt, origins: origins, started: .now, revising: existing?.id)
        self.generation = generation
        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let key = APIKeyStore.load(.openAI) else { throw DesignError.noKey }
                var summaries: [AppBrief.SourceSummary] = []
                for origin in origins {
                    let some = await library.records(matching: RecordQuery(limit: 400), allowedSources: [origin])
                    summaries.append(
                        .init(
                            origin: origin, title: source(origin)?.title ?? origin,
                            recordCount: await library.recordCount(source: origin),
                            kinds: SourceRecord.Kind.allCases.filter { kind in some.contains { $0.kind == kind } }))
                }
                let brief = AppBrief(
                    request: prompt,
                    earlierPrompts: existing?.prompts ?? [],
                    previousHTML: existing == nil ? nil : await store.html(id: existing!.id),
                    sources: summaries,
                    samples: await library.samples(for: origins))
                let librarian = OpenAILibrarian(
                    apiKey: key, appModel: AppModel.shared.appModel, recipeModel: AppModel.shared.model)
                let draft = try await librarian.generateApp(brief)
                // Before anything is saved: a generation stopped after the answer
                // arrived must not leave an app behind, or replace the version on
                // screen.
                try Task.checkCancellation()
                var app = existing ?? GeneratedApp(name: draft.name, symbol: draft.symbol, sources: origins, prompts: [])
                app.sources = origins
                app = try await store.save(app, draft: draft, prompt: prompt)
                replace(app)
                self.generation = nil
                reloadTabs(showing: app)
                opening(app)
                if existing == nil, AppModel.shared.drawsAppIcons { drawIcon(for: app, request: prompt) }
                Breadcrumbs.note(existing == nil ? "Made an app" : "Revised an app", in: nil)
            } catch is CancellationError {
                if self.generation?.id == generation.id { self.generation = nil }
            } catch {
                guard self.generation?.id == generation.id else { return }
                self.generation?.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Draw an app's icon with OpenAI's image model, from its name and the user's
    /// own words — never its data (``AppIconBrief``). A failure leaves the symbol;
    /// an icon is a nicety, not something to put an error in front of anyone for.
    func drawIcon(for app: GeneratedApp, request: String? = nil) {
        guard !drawingIcons.contains(app.id), let key = APIKeyStore.load(.openAI) else { return }
        drawingIcons.insert(app.id)
        let brief = AppIconBrief(name: app.name, request: request ?? app.prompts.first ?? app.name)
        let model = AppModel.shared.imageModel
        Task {
            defer { drawingIcons.remove(app.id) }
            do {
                let png = try await OpenAILibrarian(apiKey: key).generateIcon(brief, model: model)
                guard self.app(app.id) != nil else { return }
                try await store.saveIcon(png, id: app.id)
                icons[app.id] = NSImage(data: png)
            } catch {
                trace("apps", "icon for \(app.name) not drawn: \(error.localizedDescription)")
            }
        }
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        generation = nil
    }

    func dismissFailure() {
        if case .failed = generation?.phase { generation = nil }
    }

    func showVersion(_ version: Int, of app: GeneratedApp) async {
        guard let updated = try? await store.setCurrentVersion(version, id: app.id) else { return }
        replace(updated)
        reloadTabs(showing: updated)
    }

    func delete(_ app: GeneratedApp) async {
        await store.delete(id: app.id)
        apps.removeAll { $0.id == app.id }
        icons[app.id] = nil
        allowances[app.id] = nil
        servedMedia[app.id] = nil
        for tab in Windows.shared.everyTab where tab.appID == app.id { tab.browser?.closeApp(tab) }
    }

    private func replace(_ app: GeneratedApp) {
        if let index = apps.firstIndex(where: { $0.id == app.id }) { apps[index] = app } else { apps.append(app) }
    }

    private func reloadTabs(showing app: GeneratedApp) {
        for tab in Windows.shared.everyTab where tab.appID == app.id { tab.reload() }
    }
}

/// Recipe inference with whatever key is stored at the moment it is needed — the
/// user may add or change it after the library has opened.
private struct KeyedInferrer: RecipeInferring {
    func inferEndpointRecipe(shape: String) async throws -> EndpointRecipe {
        guard let key = APIKeyStore.load(.openAI) else { throw DesignError.noKey }
        let model = await MainActor.run { AppModel.shared.model }
        return try await OpenAILibrarian(apiKey: key, recipeModel: model).inferEndpointRecipe(shape: shape)
    }
}
