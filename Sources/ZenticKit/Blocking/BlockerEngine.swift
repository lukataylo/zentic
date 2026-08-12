import Foundation
import WebKit

/// The ``ContentBlockerService`` implementation.
///
/// Generic over ``RuleListCompiling`` only so the tests can substitute a compiler
/// that counts calls instead of driving WebKit; production always uses
/// ``WebKitContentBlocker``.
///
/// ## First run
///
/// A cold launch cannot wait for EasyList. Downloading three lists, converting ~90k
/// Adblock rules and handing the result to WebKit takes seconds, and a browser whose
/// first tab is blocked on that is a broken browser. Nor can the wait be skipped by
/// shipping a pre-compiled ruleset: `WKContentRuleList` bytecode only ever comes out
/// of `WKContentRuleListStore` on the device that made it, so there is nothing
/// compilable to put in the app bundle. Bundling the converted *JSON* would save the
/// download and the conversion but not WebKit's compile, which is the slow part.
///
/// So: a small hand-curated seed list ships in the bundle, converts and compiles in
/// well under a second, and is what protects the first pageview. The full set is
/// fetched, converted and compiled in the background, and once it is in place the
/// seed is dropped as redundant. Every later launch is a manifest read plus a
/// `lookUpContentRuleList` per list — milliseconds, no conversion, no compilation.
///
/// The load path is therefore *never* allowed to convert a large list, even when the
/// filter text is already on disk. If WebKit has evicted our compiled lists, the
/// load path falls back to the seed and lets the background refresh rebuild.
public actor BlockerEngine<Compiler: RuleListCompiling> {
    private let compiler: Compiler
    private let fetcher: any FilterListFetching
    private let storage: BlockerStorage
    private let sources: [FilterListSource]
    private let seedRules: [String]
    private let entriesPerRuleList: Int
    private let refreshesInBackground: Bool
    private let now: @Sendable () -> Date

    private var installed: Installed?
    private var loadTask: Task<Installed, any Error>?
    private var refreshTask: Task<BlockerRefreshReport, any Error>?
    private var backgroundTask: Task<Void, Never>?
    /// Whether every configured source is currently compiled and installed. False
    /// means the seed is carrying us and a background refresh is worth starting.
    private var isComplete = false
    private var shields: [String: ShieldState]?
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(
        compiler: Compiler,
        fetcher: any FilterListFetching = URLSessionFilterListFetcher(),
        directory: URL? = nil,
        sources: [FilterListSource] = FilterListCatalog.defaults.filter(\.isDefault),
        seedRules: [String] = FilterListCatalog.seedRules(),
        entriesPerRuleList: Int = BlockerLimits.entriesPerRuleList,
        refreshesInBackground: Bool = true,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.compiler = compiler
        self.fetcher = fetcher
        self.storage = BlockerStorage(directory: directory ?? BlockerStorage.applicationSupport())
        self.sources = sources
        self.seedRules = seedRules
        self.entriesPerRuleList = entriesPerRuleList
        self.refreshesInBackground = refreshesInBackground
        self.now = now
    }

    /// Compiled lists split by class, in attach order.
    struct Installed: Sendable {
        var network: [Compiler.CompiledList] = []
        var cosmetic: [Compiler.CompiledList] = []

        mutating func add(_ lists: [(RuleClass, Compiler.CompiledList)]) {
            for (ruleClass, list) in lists {
                switch ruleClass {
                case .network: network.append(list)
                case .cosmetic: cosmetic.append(list)
                }
            }
        }
    }

    // MARK: - Rule lists

    /// Lists to attach to a tab whose origin has the given shield.
    ///
    /// This is the API ``ContentBlockerService/installedRuleLists()`` cannot be:
    /// the protocol has no origin parameter, and per-origin shields cannot be
    /// implemented any other way. WebKit evaluates each `WKContentRuleList`
    /// independently, so an allowlist entry in a fourth list cannot cancel a rule in
    /// the other three — the only per-origin lever is which lists a tab attaches.
    public func ruleLists(for shield: ShieldState) async throws -> [Compiler.CompiledList] {
        guard shield != .off else { return [] }
        let installed = try await loaded()
        switch shield {
        case .standard: return installed.network + installed.cosmetic
        case .blockingOnly: return installed.network
        case .off: return []
        }
    }

    /// Fires after a refresh changes the installed set, so a shell that attached
    /// lists during the seed-only window can re-attach the full set. Without it the
    /// first tab of a first launch would keep seed-only protection until reloaded.
    public func updates() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    /// Awaits the first-run background refresh, if one is running. For a settings
    /// screen that wants to say "protection is up to date", and for tests.
    public func pendingRefresh() async {
        await backgroundTask?.value
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func notifyObservers() {
        for continuation in observers.values { continuation.yield() }
    }

    private func loaded() async throws -> Installed {
        if let installed { return installed }
        if let loadTask { return try await loadTask.value }

        let task = Task { () throws -> Installed in
            try await self.ensure(force: false, allowNetwork: false, allowRebuild: false).0
        }
        loadTask = task
        defer { loadTask = nil }

        let value = try await task.value
        installed = value
        if !isComplete { startBackgroundRefresh() }
        return value
    }

    private func startBackgroundRefresh() {
        guard refreshesInBackground, backgroundTask == nil else { return }
        backgroundTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            _ = try? await self.refresh(force: false)
            await self.clearBackgroundTask()
        }
    }

    private func clearBackgroundTask() {
        backgroundTask = nil
    }

    // MARK: - Refresh

    public func refresh(force: Bool) async throws -> BlockerRefreshReport {
        // Two tabs opening at once must not download EasyList twice.
        if let refreshTask { return try await refreshTask.value }

        let task = Task { () throws -> BlockerRefreshReport in
            let (installed, report) = try await self.ensure(
                force: force,
                allowNetwork: true,
                allowRebuild: true
            )
            self.adopt(installed)
            return report
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func adopt(_ installed: Installed) {
        self.installed = installed
        notifyObservers()
    }

    // MARK: - Shields

    public func setShield(_ state: ShieldState, for origin: String) async {
        let key = Self.normalize(origin)
        guard !key.isEmpty else { return }

        var shields = loadedShields()
        // `.standard` is the default, so it is stored as an absence. Keeps the file
        // proportional to the number of sites the user actually had to override.
        if state == .standard {
            shields.removeValue(forKey: key)
        } else {
            shields[key] = state
        }
        self.shields = shields
        try? storage.write(shields: shields)
    }

    public func shield(for origin: String) async -> ShieldState {
        loadedShields()[Self.normalize(origin)] ?? .standard
    }

    private func loadedShields() -> [String: ShieldState] {
        if let shields { return shields }
        let loaded = storage.readShields()
        shields = loaded
        return loaded
    }

    /// Reduces an origin to `scheme://host[:port]`.
    ///
    /// The toolbar has a full URL, a settings row has a bare hostname, and both must
    /// land on the same key or a shield the user set will appear not to have stuck.
    static func normalize(_ origin: String) -> String {
        let trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let url = URL(string: trimmed), let host = url.host(), !host.isEmpty else {
            return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        }
        var result = ""
        if let scheme = url.scheme { result += "\(scheme)://" }
        result += host
        if let port = url.port, port != Self.defaultPort(for: url.scheme) {
            result += ":\(port)"
        }
        return result
    }

    private static func defaultPort(for scheme: String?) -> Int? {
        switch scheme {
        case "http": 80
        case "https": 443
        default: nil
        }
    }

    // MARK: - The pipeline

    /// Brings the installed set up to date and reports what happened.
    ///
    /// - Parameters:
    ///   - force: Recompile even when upstream content is unchanged.
    ///   - allowNetwork: Whether upstream may be contacted.
    ///   - allowRebuild: Whether a large list may be converted and compiled inline.
    ///     False on the load path — see the type's "First run" note.
    private func ensure(
        force: Bool,
        allowNetwork: Bool,
        allowRebuild: Bool
    ) async throws -> (Installed, BlockerRefreshReport) {
        let started = ContinuousClock.now
        let previous = storage.readManifest() ?? BlockerManifest()

        var manifest = BlockerManifest()
        var installed = Installed()
        var updated: [String] = []
        var complete = true
        var firstFailure: (any Error)?

        for source in sources {
            do {
                let outcome = try await materialise(
                    source: source,
                    previous: previous.entry(id: source.id),
                    force: force,
                    allowNetwork: allowNetwork,
                    allowRebuild: allowRebuild
                )
                switch outcome {
                case .unavailable:
                    complete = false
                case .reused(let entry, let lists):
                    manifest.lists.append(entry)
                    installed.add(lists)
                case .rebuilt(let entry, let lists):
                    updated.append(source.id)
                    manifest.lists.append(entry)
                    installed.add(lists)
                }
            } catch {
                // One list failing upstream must not cost us the other two.
                complete = false
                firstFailure = firstFailure ?? error
            }
        }

        if !complete {
            // Seed stays only for as long as it is doing work. Once the full set is
            // installed it is pure duplication, and every attached list costs
            // matching time on every request.
            let outcome = try await materialiseSeed(
                previous: previous.entry(id: FilterListCatalog.seedID),
                force: force
            )
            switch outcome {
            case .unavailable:
                break
            case .reused(let entry, let lists):
                manifest.lists.insert(entry, at: 0)
                installed.add(lists)
            case .rebuilt(let entry, let lists):
                updated.append(FilterListCatalog.seedID)
                manifest.lists.insert(entry, at: 0)
                installed.add(lists)
            }
        }

        isComplete = complete

        if manifest != previous {
            // A cache we could not write costs a slower next launch. Refusing to
            // return lists that are compiled and correct, because a disk was full,
            // would cost the user their blocking.
            try? storage.write(manifest)
            await collectGarbage(keeping: manifest.identifiers)
        }

        // Nothing installed at all is a hard failure: silently browsing unprotected
        // when the user believes otherwise is worse than an error the shell can show.
        if installed.network.isEmpty && installed.cosmetic.isEmpty {
            throw firstFailure
                ?? BlockerError.compilationFailed(
                    list: "all",
                    message: "no filter list could be installed"
                )
        }

        return (
            installed,
            BlockerRefreshReport(
                listsUpdated: updated,
                // Totals across the whole installed set, not just this run's
                // changes, so an unchanged refresh still answers "what is loaded?".
                // Counted before splitting, so a rule duplicated into several
                // chunks is one rule here.
                rulesCompiled: manifest.lists.reduce(0) { $0 + $1.safariRuleCount },
                rulesDropped: manifest.lists.reduce(0) { $0 + $1.droppedRuleCount },
                duration: started.duration(to: .now)
            )
        )
    }

    private enum Materialised {
        case unavailable
        case reused(BlockerManifest.Entry, [(RuleClass, Compiler.CompiledList)])
        case rebuilt(BlockerManifest.Entry, [(RuleClass, Compiler.CompiledList)])
    }

    private func materialise(
        source: FilterListSource,
        previous: BlockerManifest.Entry?,
        force: Bool,
        allowNetwork: Bool,
        allowRebuild: Bool
    ) async throws -> Materialised {
        var downloaded: String?
        var etag = previous?.etag
        var fetchedAt = previous?.fetchedAt

        let stale =
            previous.map { now().timeIntervalSince($0.fetchedAt) > BlockerLimits.listMaxAge }
            ?? true
        if allowNetwork && (force || stale) {
            // Forcing drops the ETag: with it, upstream would answer 304 and there
            // would be nothing to recompile.
            switch try await fetcher.fetch(source, etag: force ? nil : etag) {
            case .notModified:
                fetchedAt = now()
            case .updated(let text, let newETag):
                downloaded = text
                etag = newETag
                fetchedAt = now()
            }
        }

        // The path every launch takes: nothing was fetched and WebKit still has what
        // the manifest describes. Deliberately does not read the 2MB snapshot back —
        // the compiled lists are what matter, and each is identified by a hash of its
        // own contents, so there is nothing about the source text left to verify.
        if !force, downloaded == nil, let previous, let lists = await resolve(previous) {
            return .reused(refreshed(previous, etag: etag, fetchedAt: fetchedAt), lists)
        }

        guard let text = downloaded ?? storage.readSnapshot(for: source.id) else {
            return .unavailable
        }

        // Fetched bytes identical to what we already compiled: an ETag that changed
        // without the content changing, which a CDN rebuild or a mirror switch does.
        if !force, let previous, previous.contentHash == ContentHash.of(text),
            let lists = await resolve(previous)
        {
            return .reused(refreshed(previous, etag: etag, fetchedAt: fetchedAt), lists)
        }

        guard allowRebuild else { return .unavailable }

        let (entry, lists) = try await rebuild(
            listID: source.id,
            title: source.title,
            sourceURL: source.url,
            text: text,
            etag: etag,
            fetchedAt: fetchedAt ?? now(),
            force: force
        )
        if downloaded != nil {
            try storage.writeSnapshot(text, for: source.id)
        }
        return .rebuilt(entry, lists)
    }

    /// Records that upstream was asked, without claiming anything was rebuilt.
    private func refreshed(
        _ entry: BlockerManifest.Entry,
        etag: String?,
        fetchedAt: Date?
    ) -> BlockerManifest.Entry {
        var entry = entry
        entry.etag = etag
        entry.fetchedAt = fetchedAt ?? entry.fetchedAt
        return entry
    }

    private func materialiseSeed(
        previous: BlockerManifest.Entry?,
        force: Bool
    ) async throws -> Materialised {
        guard !seedRules.isEmpty else { return .unavailable }
        let text = seedRules.joined(separator: "\n")
        let hash = ContentHash.of(text)

        if !force, let previous, previous.contentHash == hash,
            let lists = await resolve(previous)
        {
            return .reused(previous, lists)
        }

        let (entry, lists) = try await rebuild(
            listID: FilterListCatalog.seedID,
            title: "Zentic Seed",
            sourceURL: nil,
            text: text,
            etag: nil,
            fetchedAt: now(),
            force: force
        )
        return .rebuilt(entry, lists)
    }

    private func rebuild(
        listID: String,
        title: String,
        sourceURL: URL?,
        text: String,
        etag: String?,
        fetchedAt: Date,
        force: Bool
    ) async throws -> (BlockerManifest.Entry, [(RuleClass, Compiler.CompiledList)]) {
        let converted = try await convertOffActor(text: text, listID: listID)
        let identifiers = converted.chunks.map { Self.identifier(listID: listID, chunk: $0) }
        let refs = zip(identifiers, converted.chunks).map { identifier, chunk in
            BlockerManifest.CompiledRef(
                identifier: identifier,
                ruleClass: chunk.ruleClass,
                entryCount: chunk.entryCount
            )
        }

        // All or nothing. Reusing some chunks and compiling others would work only if
        // the two sets came from the same conversion; taking chunk 0 from a previous
        // run and chunk 1 from this one could drop entries that fell between them.
        var reused: [Compiler.CompiledList] = []
        if !force {
            for identifier in identifiers {
                guard let existing = await compiler.existing(identifier: identifier) else {
                    reused = []
                    break
                }
                reused.append(existing)
            }
        }

        var lists: [(RuleClass, Compiler.CompiledList)] = []
        if reused.count == converted.chunks.count {
            // Same bytes as last time, so WebKit's copies are still correct even
            // though the manifest went missing.
            lists = zip(converted.chunks.map(\.ruleClass), reused).map { ($0, $1) }
        } else {
            for (identifier, chunk) in zip(identifiers, converted.chunks) {
                lists.append(
                    (
                        chunk.ruleClass,
                        try await compiler.compile(identifier: identifier, json: chunk.json)
                    )
                )
            }
        }

        let entry = BlockerManifest.Entry(
            id: listID,
            title: title,
            sourceURL: sourceURL,
            etag: etag,
            contentHash: ContentHash.of(text),
            fetchedAt: fetchedAt,
            sourceRuleCount: converted.sourceRuleCount,
            safariRuleCount: converted.safariRuleCount,
            droppedRuleCount: converted.droppedRuleCount,
            ruleLists: refs
        )
        return (entry, lists)
    }

    /// Conversion is seconds of straight-line CPU for a list the size of EasyList, and
    /// running it on the actor would block every `installedRuleLists()` and `shield(for:)`
    /// call behind it — a hung toolbar during the first-run background refresh. It has
    /// no need for actor state, so it goes to a detached task instead.
    private nonisolated func convertOffActor(
        text: String,
        listID: String
    ) async throws -> ConvertedFilterList {
        let entriesPerRuleList = self.entriesPerRuleList
        return try await Task.detached(priority: .utility) {
            try RuleConverter.convert(
                rules: FilterListText.lines(of: text),
                listID: listID,
                entriesPerList: entriesPerRuleList
            )
        }.value
    }

    /// Looks up every compiled list a manifest entry names. Nil if any is gone —
    /// a partial set would silently under-block.
    private func resolve(
        _ entry: BlockerManifest.Entry
    ) async -> [(RuleClass, Compiler.CompiledList)]? {
        guard !entry.ruleLists.isEmpty else { return nil }
        var lists: [(RuleClass, Compiler.CompiledList)] = []
        for ref in entry.ruleLists {
            guard let list = await compiler.existing(identifier: ref.identifier) else { return nil }
            lists.append((ref.ruleClass, list))
        }
        return lists
    }

    /// Compiled lists left behind by a previous list version. Only ours are touched:
    /// the default store is shared with any Safari content-blocker extension the user
    /// has installed.
    private func collectGarbage(keeping live: Set<String>) async {
        for identifier in await compiler.identifiers()
        where identifier.hasPrefix(Self.identifierPrefix) && !live.contains(identifier) {
            await compiler.remove(identifier: identifier)
        }
    }

    static var identifierPrefix: String { "zentic.\(BlockerLimits.cacheSchemaVersion)." }

    /// The content hash is *in* the identifier, which is what makes the cache
    /// correct rather than merely fast: identical JSON always resolves to WebKit's
    /// existing compilation, and changed JSON can never collide with it.
    static func identifier(listID: String, chunk: RuleListChunk) -> String {
        let hash = ContentHash.of(chunk.json).prefix(12)
        return "\(identifierPrefix)\(listID).\(chunk.ruleClass.rawValue).\(chunk.index).\(hash)"
    }
}

extension BlockerEngine: ContentBlockerService where Compiler.CompiledList == WKContentRuleList {
    /// The set for a normal tab. Origins with a non-standard shield need
    /// ``ruleLists(for:)`` instead.
    public func installedRuleLists() async throws -> [WKContentRuleList] {
        try await ruleLists(for: .standard)
    }
}

/// The production blocker.
public typealias WebKitContentBlocker = BlockerEngine<WebKitRuleListCompiler>

extension BlockerEngine where Compiler == WebKitRuleListCompiler {
    /// Builds a blocker with its own rule-list store next to its manifest, so the
    /// two cannot be wiped independently and then disagree about what is compiled.
    public init(
        directory: URL? = nil,
        fetcher: any FilterListFetching = URLSessionFilterListFetcher()
    ) {
        let resolved = directory ?? BlockerStorage.applicationSupport()
        let storage = BlockerStorage(directory: resolved)
        try? storage.createDirectories()
        self.init(
            compiler: WebKitRuleListCompiler(storeURL: storage.ruleListStoreURL),
            fetcher: fetcher,
            directory: resolved
        )
    }
}
