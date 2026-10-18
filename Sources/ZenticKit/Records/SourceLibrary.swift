import Foundation

/// Something that can turn a response's shape into a recipe for it.
///
/// Receives a ``ShapeSummary`` string and nothing else from the response. A
/// protocol so the library's flow — store raw, ask once, re-map — is testable
/// without a network, and so no implementation can be handed the body by
/// accident.
public protocol RecipeInferring: Sendable {
    /// Only the shape. Not the origin, not the endpoint path — paths carry
    /// usernames and slugs (`/users/alice/comments`), and the model does not need
    /// to know whose data it is looking at to say where the items are.
    func inferEndpointRecipe(shape: String) async throws -> EndpointRecipe
}

/// What the recorder forwarded: one response the page itself fetched.
public struct CapturePayload: Codable, Sendable, Hashable {
    public enum Via: String, Codable, Sendable {
        case fetch, xhr
        /// JSON the server embedded in the HTML: JSON-LD, `__NEXT_DATA__`.
        case embedded
    }

    /// The response's URL, or `embedded://<kind>` for embedded JSON.
    public var url: String
    public var via: Via
    public var body: String

    public init(url: String, via: Via, body: String) {
        self.url = url
        self.via = via
        self.body = body
    }
}

/// The library's write path: captures in, records out.
///
/// Every capture is written raw before it is mapped. A response that arrives
/// while its endpoint has no recipe is not lost — it waits in ``RecordStore``
/// until inference produces one, and is mapped then.
public actor SourceLibrary {
    private let store: RecordStore
    private let inferrer: (any RecipeInferring)?
    /// Endpoints with an inference in flight, so a burst of forty responses from
    /// one scroll asks the model once.
    private var inferring: Set<String> = []
    /// When inference last failed per endpoint. A failure is retried after an
    /// hour, not on the next response — a broken key or a bad model reply would
    /// otherwise cost one call per scroll.
    private var failedAt: [String: Date] = [:]

    public enum Outcome: Sendable, Equatable {
        /// Not a source, or not JSON. Nothing was stored.
        case ignored
        case mapped(Int)
        /// Stored raw; a recipe is being inferred for this endpoint.
        case awaitingRecipe(endpoint: String)
    }

    /// - Parameter url: The database file, or nil for an in-memory library (tests).
    public init(url: URL?, inferrer: (any RecipeInferring)?) throws {
        self.store = try RecordStore(url: url)
        self.inferrer = inferrer
    }

    // MARK: - Reads

    public func sources() -> [Source] {
        (try? store.sources()) ?? []
    }

    public func source(_ origin: String) -> Source? {
        try? store.source(origin)
    }

    public func records(matching query: RecordQuery, allowedSources: Set<String>) -> [SourceRecord] {
        (try? store.records(matching: query, allowedSources: allowedSources)) ?? []
    }

    public func recordCount(source: String) -> Int {
        (try? store.recordCount(source: source)) ?? 0
    }

    /// The newest few records per source, for showing a model what real data looks
    /// like when it designs an app. Text is cut to ``LibraryBudget/appSampleTextLength``.
    public func samples(for origins: [String]) -> [SourceRecord] {
        origins.flatMap { origin in
            records(
                matching: RecordQuery(limit: LibraryBudget.appSampleRecords),
                allowedSources: [origin]
            ).map { record in
                var sample = record
                if let text = sample.text, text.count > LibraryBudget.appSampleTextLength {
                    sample.text = String(text.prefix(LibraryBudget.appSampleTextLength)) + "…"
                }
                return sample
            }
        }
    }

    // MARK: - Sources

    /// Start keeping a database of `origin`. Curated recipes apply immediately.
    @discardableResult
    public func addSource(origin: String, title: String, homeURL: String, refresh: Source.Refresh) throws -> Source {
        if let existing = try store.source(origin) { return existing }
        let source = Source(
            origin: origin,
            title: title,
            homeURL: homeURL,
            refresh: refresh,
            recipe: SourceRecipe.curated(for: origin)
        )
        try store.save(source)
        return source
    }

    /// Save a changed source — its refresh policy, its home page.
    public func update(_ source: Source) {
        try? store.save(source)
    }

    public func removeSource(origin: String) throws {
        try store.remove(origin: origin)
    }

    // MARK: - Ingest

    /// Store a response the page fetched, and map it if its endpoint has a recipe.
    ///
    /// - Parameter pageOrigin: The origin of the frame that sent the capture, as
    ///   WebKit reported it — never the payload's own URL. The payload came from
    ///   page script, and a page that could name its own origin could write into
    ///   another source.
    public func ingest(_ capture: CapturePayload, pageOrigin: String, pageURL: URL?) async -> Outcome {
        guard let source = try? store.source(pageOrigin),
            capture.body.utf8.count <= LibraryBudget.maxCaptureBytes,
            let body = capture.body.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]),
            json is [String: Any] || json is [Any],
            let url = URL(string: capture.url)
        else { return .ignored }

        let endpoint = EndpointKey.of(url)
        let key = "\(pageOrigin) \(endpoint)"
        let recipe = source.recipe?.endpoint(for: endpoint)

        // A standing "no records here" verdict — a badge count, a settings blob —
        // is not worth a row, let alone a model call. Until it expires: the first
        // response an endpoint returned may have been an empty search.
        if let recipe, recipe.items == nil {
            let age = recipe.inferredAt.map { Date.now.timeIntervalSince($0) } ?? 0
            guard age > LibraryBudget.recipeVerdictMaxAge else { return .ignored }
        }

        let now = Date.now
        try? store.appendRaw(
            .init(origin: pageOrigin, endpoint: endpoint, url: capture.url, capturedAt: now, body: body)
        )

        guard let recipe, recipe.items != nil else {
            await learnRecipe(origin: pageOrigin, endpoint: endpoint, sample: json)
            return .awaitingRecipe(endpoint: endpoint)
        }

        let records = Self.ordered(
            RecordMapper.records(from: json, recipe: recipe, source: pageOrigin, pageURL: pageURL, seenAt: now)
        )
        guard !records.isEmpty else {
            await noteEmptyMapping(key: key, origin: pageOrigin, endpoint: endpoint, bytes: body.count, sample: json)
            return .mapped(0)
        }
        yielded.insert(key)
        emptyStreak[key] = nil

        let count = (try? store.upsert(records)) ?? 0
        queueMedia(for: records, source: source)
        if var fresh = try? store.source(pageOrigin) {
            fresh.lastCapturedAt = now
            try? store.save(fresh)
        }
        return .mapped(count)
    }

    /// Records with no date of their own keep the order the site listed them in.
    /// They share one capture time, so without this a dateless feed would sort by
    /// id — alphabetical, which is no order a site ever meant.
    static func ordered(_ records: [SourceRecord]) -> [SourceRecord] {
        records.enumerated().map { index, record in
            guard record.publishedAt == nil else { return record }
            var copy = record
            copy.firstSeen = record.firstSeen.addingTimeInterval(-Double(index) * 0.001)
            return copy
        }
    }

    // MARK: - Media

    /// Images the shell should cache: avatars and the first few media of records
    /// just captured, restricted to hosts the source is allowed to use.
    ///
    /// Queued here, at capture time, and nowhere else. An app asking for records
    /// must not be able to make the native process fetch anything — that would be
    /// a network request outside the sandbox, chosen by a model-written page.
    private var pendingMedia: [String] = []

    private func queueMedia(for records: [SourceRecord], source: Source) {
        let allowedHosts = Set(source.recipe?.mediaHosts ?? [])
        for record in records {
            let candidates = [record.authorAvatar].compactMap { $0 } + record.media.prefix(LibraryBudget.cachedMediaPerRecord)
            pendingMedia += candidates.filter {
                MediaPolicy.allows($0, source: source.origin, extraHosts: allowedHosts)
            }
        }
    }

    /// Drain the media queue. The shell fetches these and tells apps when they land.
    public func takePendingMedia() -> [String] {
        defer { pendingMedia = [] }
        var seen: Set<String> = []
        return pendingMedia.filter { seen.insert($0).inserted }
    }

    // MARK: - Recipes

    /// Endpoints that have produced records this session, and how many responses
    /// in a row each has since mapped to nothing.
    private var yielded: Set<String> = []
    private var emptyStreak: [String: Int] = [:]
    /// Model calls per source today, against ``LibraryBudget/recipeInferencesPerSourcePerDay``.
    private var inferenceCalls: [String: (day: Date, count: Int)] = [:]

    /// An endpoint that used to yield records and now maps nothing, repeatedly,
    /// from responses big enough to hold some: the site changed shape. Re-learn
    /// that one endpoint — `endpoint(for:)` prefers an exact key over the
    /// wildcard, so a fix for X's timeline does not disturb its other endpoints.
    private func noteEmptyMapping(key: String, origin: String, endpoint: String, bytes: Int, sample: Any) async {
        guard yielded.contains(key), bytes >= LibraryBudget.staleRecipeMinBytes else { return }
        let streak = (emptyStreak[key] ?? 0) + 1
        emptyStreak[key] = streak
        guard streak >= LibraryBudget.staleRecipeStreak else { return }
        emptyStreak[key] = nil
        yielded.remove(key)
        await learnRecipe(origin: origin, endpoint: endpoint, sample: sample)
    }

    /// Find a recipe for an endpoint: first by trying the ones this source already
    /// has — a site's profile, list and search endpoints usually share an item
    /// shape, and `/users/alice/posts` should not cost a call when `/users/bob/posts`
    /// already paid for one — and only then by asking the model.
    private func learnRecipe(origin: String, endpoint: String, sample: Any) async {
        guard let source = try? store.source(origin) else { return }
        for known in source.recipe?.endpoints ?? [] where known.items != nil && known.endpoint != endpoint {
            if !RecordMapper.records(from: sample, recipe: known, source: origin, pageURL: nil).isEmpty {
                var reused = known
                reused.endpoint = endpoint
                try? await adopt(reused, origin: origin, endpoint: endpoint)
                return
            }
        }

        let key = "\(origin) \(endpoint)"
        guard let inferrer else { return }
        if let failed = failedAt[key], Date.now.timeIntervalSince(failed) < 3600 { return }
        guard spendInference(for: origin), inferring.insert(key).inserted else { return }
        defer { inferring.remove(key) }

        do {
            let recipe = try await inferrer.inferEndpointRecipe(shape: ShapeSummary.describe(sample))
            try await adopt(recipe, origin: origin, endpoint: endpoint)
            failedAt[key] = nil
        } catch {
            failedAt[key] = .now
        }
    }

    private func spendInference(for origin: String) -> Bool {
        let today = Calendar.current.startOfDay(for: .now)
        var entry = inferenceCalls[origin] ?? (today, 0)
        if entry.day != today { entry = (today, 0) }
        guard entry.count < LibraryBudget.recipeInferencesPerSourcePerDay else { return false }
        entry.count += 1
        inferenceCalls[origin] = entry
        return true
    }

    /// Install an endpoint recipe, then re-map every stored response for it.
    ///
    /// Only the model's own `items: null` becomes a "no records here" verdict. A
    /// recipe that maps nothing from what is stored so far is kept as it is: an
    /// endpoint's first response is often empty or an error, and judging the
    /// endpoint by it would close it for good.
    public func adopt(_ recipe: EndpointRecipe, origin: String, endpoint: String) async throws {
        guard var source = try store.source(origin) else { return }
        var recipe = recipe
        recipe.endpoint = endpoint

        var mapped: [SourceRecord] = []
        if recipe.items != nil {
            for raw in try store.rawResponses(origin: origin, endpoint: endpoint) {
                guard let json = try? JSONSerialization.jsonObject(with: raw.body) else { continue }
                mapped += Self.ordered(
                    RecordMapper.records(
                        from: json,
                        recipe: recipe,
                        source: origin,
                        pageURL: URL(string: raw.url),
                        seenAt: raw.capturedAt
                    )
                )
            }
        }

        var sourceRecipe = source.recipe
            ?? SourceRecipe(origin: origin, endpoints: [], provenance: .inferred)
        sourceRecipe.endpoints.removeAll { $0.endpoint == endpoint }
        sourceRecipe.endpoints.append(recipe)
        sourceRecipe.generatedAt = .now
        source.recipe = sourceRecipe
        if !mapped.isEmpty {
            source.lastCapturedAt = .now
            yielded.insert("\(origin) \(endpoint)")
        }
        try store.save(source)
        try store.upsert(mapped)
        queueMedia(for: mapped, source: source)
    }
}

/// Which image URLs the media cache may fetch for a source.
///
/// https only; the source's own site or a host its curated recipe names; never
/// an IP literal or a private name. A captured record is the site's claim about
/// an image, and the cache is a native fetch outside every page's sandbox — so
/// the claim gets the narrowest reading that still shows the site's avatars.
public enum MediaPolicy {
    public static func allows(_ string: String, source: String, extraHosts: Set<String>) -> Bool {
        guard let url = URL(string: string), url.scheme == "https",
            let host = url.host()?.lowercased(), !host.isEmpty,
            let sourceHost = URL(string: source)?.host()?.lowercased()
        else { return false }
        if isIPLiteral(host) || host == "localhost" || host.hasSuffix(".local") || !host.contains(".") {
            return false
        }
        if extraHosts.contains(host) { return true }
        let site = registrableGuess(sourceHost)
        return host == site || host.hasSuffix("." + site)
    }

    static func isIPLiteral(_ host: String) -> Bool {
        host.contains(":") || host.split(separator: ".").allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// The source's host without a leading `www.`. Deliberately not "the last two
    /// labels": on `bbc.co.uk` that would be every site in the UK.
    static func registrableGuess(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
