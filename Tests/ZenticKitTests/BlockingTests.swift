import Foundation
import Testing

@testable import ZenticKit

// MARK: - Conversion

@Suite("Rule conversion")
struct RuleConversionTests {
    /// Exact counts, deliberately. SafariConverterLib is an upstream dependency that
    /// merges, reorders and rejects rules on its own judgement; a test that only
    /// asserted "more than zero" would not notice a version bump changing any of it.
    @Test func convertsTheFixtureIntoBothClasses() throws {
        let converted = try RuleConverter.convert(
            rules: try RuleFixture.rules("tiny"), listID: "tiny")

        #expect(converted.sourceRuleCount == 20)
        // 8 network + 2 exceptions + 4 cosmetic, less one: the converter merges the
        // two generic cosmetic rules into a single entry with a combined selector.
        #expect(converted.safariRuleCount == 13)
        // The six rules under "inexpressible" in the fixture, and only those.
        #expect(converted.droppedRuleCount == 6)

        let network = try #require(converted.chunks.first { $0.ruleClass == .network })
        let cosmetic = try #require(converted.chunks.first { $0.ruleClass == .cosmetic })
        #expect(converted.chunks.count == 2)

        let networkEntries = try Entry.decode(network.json)
        let cosmeticEntries = try Entry.decode(cosmetic.json)

        #expect(networkEntries.filter(\.isBlock).count == 8)
        #expect(cosmeticEntries.filter(\.isHide).count == 3)
        // Neither class may carry the other's actions, or detaching the cosmetic
        // lists for a `.blockingOnly` origin would take network blocking with it.
        #expect(networkEntries.filter(\.isHide).isEmpty)
        #expect(cosmeticEntries.filter(\.isBlock).isEmpty)

        // Exceptions belong to both, so neither class can over-block on its own.
        #expect(networkEntries.filter(\.isException).count == 2)
        #expect(cosmeticEntries.filter(\.isException).count == 2)
    }

    @Test func splitsAtTheCapKeepingEveryExceptionInEveryChunk() throws {
        let rules = try RuleFixture.rules("tiny")
        let whole = try RuleConverter.convert(rules: rules, listID: "tiny")
        let split = try RuleConverter.convert(rules: rules, listID: "tiny", entriesPerList: 4)

        #expect(split.chunks.count > whole.chunks.count)
        // Reported before splitting, so duplicating exceptions must not inflate it.
        #expect(split.safariRuleCount == whole.safariRuleCount)

        for chunk in split.chunks {
            let entries = try Entry.decode(chunk.json)
            #expect(entries.count == chunk.entryCount)
            #expect(entries.count <= 4)
            // The whole point: a chunk holding a block rule but not the `@@` rule
            // that excepts it would over-block, and over-blocking breaks checkouts.
            #expect(entries.filter(\.isException).count == 2)
            // Entries stay in the converter's order. `$important` block rules are
            // emitted after ordinary exceptions precisely so they win.
            #expect(entries.map(\.sortKey) == entries.map(\.sortKey).sorted())
        }

        for ruleClass in RuleClass.allCases {
            let expected = try Entry.decode(
                try #require(whole.chunks.first { $0.ruleClass == ruleClass }).json
            ).filter { !$0.isException }
            let actual = try split.chunks.filter { $0.ruleClass == ruleClass }
                .flatMap { try Entry.decode($0.json) }
                .filter { !$0.isException }
            #expect(actual == expected)
        }
    }

    @Test func exceptionsExceedingTheCapAreUnrecoverable() throws {
        // The fixture's two exceptions have to appear in every chunk, so a two-entry
        // ceiling leaves no room for a single block rule. No split can fix that,
        // which is the one case `ruleLimitExceeded` is for.
        let rules = try RuleFixture.rules("tiny")
        #expect(throws: BlockerError.ruleLimitExceeded(list: "tiny", count: 10)) {
            try RuleConverter.convert(rules: rules, listID: "tiny", entriesPerList: 2)
        }
    }

    @Test func malformedRulesAreDroppedNotFatal() throws {
        let junk = [
            // Unparseable.
            "@@",
            "$$$$",
            "##:has-text(",
            "||example.com^$unknown-modifier-that-does-not-exist",
            // Parses, but the converter cannot compile the regex — a different
            // failure path, and one the drop count used to miss entirely.
            "/(((((/$script",
            // Parses, but needs a JS engine.
            "example.com#%#//scriptlet('abort-on-property-read', 'x')",
        ]
        let onlyJunk = try RuleConverter.convert(rules: junk, listID: "junk")
        #expect(onlyJunk.chunks.isEmpty)
        #expect(onlyJunk.safariRuleCount == 0)
        #expect(onlyJunk.droppedRuleCount == junk.count)

        // A bad rule must not take its neighbours down with it.
        let mixed = try RuleConverter.convert(
            rules: junk + ["||ads.example.com^"],
            listID: "mixed"
        )
        #expect(mixed.safariRuleCount == 1)
        #expect(mixed.droppedRuleCount == junk.count)
    }

    /// Identical input must produce byte-identical JSON, because the identifier of a
    /// compiled list is a hash of that JSON. Without it every rebuild would mint fresh
    /// identifiers and WebKit could never recognise work it had already done —
    /// SafariConverterLib groups rules through dictionaries, and Swift seeds its
    /// hashing per process, so this does not hold for free.
    @Test func conversionIsReproducible() throws {
        let rules = try RuleFixture.rules("tiny")
        let first = try RuleConverter.convert(rules: rules, listID: "tiny")
        let second = try RuleConverter.convert(rules: rules.reversed(), listID: "tiny")
        #expect(first.chunks.map(\.json) == second.chunks.map(\.json))
    }

    @Test func selectorListsAreOnlyReorderedWhereItIsSafe() {
        // A merged generic-cosmetic selector, which the converter builds from a set.
        #expect(RuleConverter.canonicalSelector(".b, .a") == ".a, .b")
        // Commas inside brackets and parens do not separate selectors.
        #expect(RuleConverter.canonicalSelector("[data-x=\"b,a\"]") == "[data-x=\"b,a\"]")
        #expect(RuleConverter.canonicalSelector(":not(.b, .a)") == ":not(.b, .a)")
        #expect(
            RuleConverter.canonicalSelector("div:not(.z, .y), .a") == ".a, div:not(.z, .y)"
        )
        // Anything not spelled the way the converter spells it is left untouched.
        #expect(RuleConverter.canonicalSelector(".b,.a") == ".b,.a")
        #expect(RuleConverter.canonicalSelector(".b, ") == ".b, ")
    }

    /// The seed only earns its place in the bundle if all of it survives conversion;
    /// a rule Safari cannot express is dead weight in a list whose whole purpose is
    /// to be small and instant.
    @Test func bundledSeedIsEntirelyExpressibleInSafari() throws {
        let rules = FilterListCatalog.seedRules()
        #expect(rules.count > 100, "seed.txt is missing from the resource bundle")

        let converted = try RuleConverter.convert(rules: rules, listID: FilterListCatalog.seedID)
        #expect(converted.droppedRuleCount == 0)
        #expect(converted.chunks.contains { $0.ruleClass == .network })
        #expect(converted.chunks.contains { $0.ruleClass == .cosmetic })
        // Whole point of the seed: it fits in one compiled list per class, so first
        // run is two cheap compilations.
        #expect(converted.chunks.count == 2)
    }
}

// MARK: - Caching and refresh

@Suite("Compiled-list cache")
struct BlockerCacheTests {
    @Test func firstRunInstallsTheSeedWithoutTouchingTheNetwork() async throws {
        let harness = try Harness(offline: true)
        let lists = try await harness.engine.ruleLists(for: .standard)

        #expect(!lists.isEmpty)
        // Seed only — nothing else could have been installed.
        #expect(lists.allSatisfy { $0.contains(FilterListCatalog.seedID) })
        #expect(await harness.compiler.compileCount == lists.count)
    }

    @Test func secondCallDoesNotRecompile() async throws {
        let harness = try Harness()
        _ = try await harness.engine.refresh(force: false)
        let after = await harness.compiler.compileCount
        #expect(after > 0)

        _ = try await harness.engine.ruleLists(for: .standard)
        _ = try await harness.engine.ruleLists(for: .standard)
        #expect(await harness.compiler.compileCount == after)
    }

    /// The whole first-run design in one test: the first caller gets seed-only
    /// protection immediately without waiting for a download, the full set lands in the
    /// background, and the seed is dropped once it is redundant.
    @Test func theFullSetArrivesInTheBackgroundAndRetiresTheSeed() async throws {
        let harness = try Harness(refreshesInBackground: true)

        let atFirstPaint = try await harness.engine.ruleLists(for: .standard)
        #expect(atFirstPaint.allSatisfy { $0.contains(FilterListCatalog.seedID) })

        await harness.engine.pendingRefresh()

        let afterRefresh = try await harness.engine.ruleLists(for: .standard)
        #expect(!afterRefresh.isEmpty)
        #expect(afterRefresh.allSatisfy { !$0.contains(FilterListCatalog.seedID) })
    }

    /// Tabs opened during the seed-only window would keep seed-only protection until
    /// reloaded if nothing told the shell to re-attach.
    @Test func theInstalledSetAnnouncesItselfWhenItChanges() async throws {
        let harness = try Harness()
        var updates = await harness.engine.updates().makeAsyncIterator()
        _ = try await harness.engine.refresh(force: false)
        #expect(await updates.next() != nil)
    }

    /// Every tab asks for the lists as it opens, so the first several callers arrive
    /// together. Compiling once per caller would be the worst possible first run.
    @Test func concurrentCallersShareOneCompilation() async throws {
        let harness = try Harness()
        async let first = harness.engine.ruleLists(for: .standard)
        async let second = harness.engine.ruleLists(for: .standard)
        async let third = harness.engine.ruleLists(for: .blockingOnly)
        _ = try await (first, second, third)

        // The seed's two lists, once.
        #expect(await harness.compiler.compileCount == 2)
    }

    @Test func concurrentRefreshesFetchOnce() async throws {
        let harness = try Harness()
        async let first = harness.engine.refresh(force: false)
        async let second = harness.engine.refresh(force: false)
        _ = try await (first, second)

        #expect(await harness.fetcher.fetchCount == 1)
    }

    /// The expensive case: a relaunch. WebKit still holds the compiled lists, so a
    /// fresh engine must recognise them from the manifest rather than convert 90k
    /// rules again.
    @Test func warmStartAcrossEngineInstancesDoesNotRecompile() async throws {
        let harness = try Harness()
        _ = try await harness.engine.refresh(force: false)
        let after = await harness.compiler.compileCount

        let relaunched = harness.makeEngine()
        let lists = try await relaunched.ruleLists(for: .standard)
        #expect(!lists.isEmpty)
        #expect(lists.allSatisfy { !$0.contains(FilterListCatalog.seedID) })
        #expect(await harness.compiler.compileCount == after)
    }

    /// WebKit does evict compiled lists. The load path must not answer that by
    /// converting EasyList inline — it falls back to the seed and lets the
    /// background refresh rebuild.
    @Test func evictedListsFallBackToTheSeedRatherThanBlocking() async throws {
        let harness = try Harness()
        _ = try await harness.engine.refresh(force: false)
        await harness.compiler.removeAll()

        let relaunched = harness.makeEngine()
        let lists = try await relaunched.ruleLists(for: .standard)
        #expect(lists.allSatisfy { $0.contains(FilterListCatalog.seedID) })
    }

    @Test func unchangedUpstreamSkipsRecompilation() async throws {
        let harness = try Harness()
        let first = try await harness.engine.refresh(force: false)
        #expect(first.listsUpdated == [Harness.listID])
        let after = await harness.compiler.compileCount

        harness.clock.advance(by: 2 * BlockerLimits.listMaxAge)
        let second = try await harness.engine.refresh(force: false)

        #expect(await harness.fetcher.fetchCount == 2)
        #expect(second.listsUpdated.isEmpty)
        #expect(await harness.compiler.compileCount == after)
        // Totals describe the installed set, so they survive a no-op refresh.
        #expect(second.rulesCompiled == first.rulesCompiled)
        #expect(second.rulesDropped == first.rulesDropped)
    }

    /// An ETag can change while the bytes do not — a CDN rebuild, a mirror switch.
    /// Hashing the text is what stops that costing a full recompile.
    @Test func newETagOverIdenticalContentSkipsRecompilation() async throws {
        let harness = try Harness()
        _ = try await harness.engine.refresh(force: false)
        let after = await harness.compiler.compileCount

        await harness.fetcher.setETag("changed-but-same-bytes")
        harness.clock.advance(by: 2 * BlockerLimits.listMaxAge)
        let report = try await harness.engine.refresh(force: false)

        #expect(report.listsUpdated.isEmpty)
        #expect(await harness.compiler.compileCount == after)
    }

    @Test func changedContentRecompilesAndRetiresTheOldLists() async throws {
        let harness = try Harness()
        _ = try await harness.engine.refresh(force: false)
        let after = await harness.compiler.compileCount
        let before = await harness.compiler.identifiers()

        await harness.fetcher.setText("||newly-added.example.com^\n" + Harness.listText)
        await harness.fetcher.setETag("v2")
        harness.clock.advance(by: 2 * BlockerLimits.listMaxAge)
        let report = try await harness.engine.refresh(force: false)

        #expect(report.listsUpdated == [Harness.listID])
        #expect(await harness.compiler.compileCount > after)
        // Superseded lists are removed, or the store grows without bound. The cosmetic
        // chunk is untouched by a new network rule, so it keeps its identifier — which
        // is the point of hashing each chunk rather than the list as a whole.
        let now = await harness.compiler.identifiers()
        #expect(now.count == before.count)
        #expect(!before.subtracting(now).isEmpty)
        #expect(!now.subtracting(before).isEmpty)
    }

    @Test func forceRecompilesContentThatDidNotChange() async throws {
        let harness = try Harness()
        _ = try await harness.engine.refresh(force: false)
        let after = await harness.compiler.compileCount

        let report = try await harness.engine.refresh(force: true)
        #expect(report.listsUpdated == [Harness.listID])
        #expect(await harness.compiler.compileCount > after)
    }

    @Test func reportsWhatTheConverterCouldNotExpress() async throws {
        let harness = try Harness()
        let report = try await harness.engine.refresh(force: false)
        // Non-zero is the expected state, not a defect: Safari's syntax is a subset
        // of Adblock Plus's. The fixture's six inexpressible rules.
        #expect(report.rulesDropped == 6)
        #expect(report.rulesCompiled == 13)
        #expect(report.duration > .zero)
    }
}

// MARK: - Shields

@Suite("Per-origin shields")
struct ShieldTests {
    @Test func shieldSelectsWhichListsAttach() async throws {
        let harness = try Harness()
        _ = try await harness.engine.refresh(force: false)

        let standard = try await harness.engine.ruleLists(for: .standard)
        let blockingOnly = try await harness.engine.ruleLists(for: .blockingOnly)
        let off = try await harness.engine.ruleLists(for: .off)

        #expect(off.isEmpty)
        #expect(blockingOnly.allSatisfy { $0.contains(RuleClass.network.rawValue) })
        #expect(!blockingOnly.contains { $0.contains(RuleClass.cosmetic.rawValue) })
        #expect(Set(blockingOnly).isSubset(of: Set(standard)))
        #expect(standard.count > blockingOnly.count)
    }

    @Test func shieldsSurviveARelaunch() async throws {
        let harness = try Harness()
        await harness.engine.setShield(.blockingOnly, for: "https://example.com")
        await harness.engine.setShield(.off, for: "https://broken.example.org")

        let relaunched = harness.makeEngine()
        #expect(await relaunched.shield(for: "https://example.com") == .blockingOnly)
        #expect(await relaunched.shield(for: "https://broken.example.org") == .off)
        #expect(await relaunched.shield(for: "https://untouched.example.net") == .standard)
    }

    /// The toolbar has a full URL and a settings row has a bare host. If they key
    /// differently, a shield the user set looks like it did not stick.
    @Test func originsNormaliseToOneKey() async throws {
        let harness = try Harness()
        await harness.engine.setShield(.off, for: "HTTPS://Example.com:443/some/path?q=1")

        for spelling in [
            "https://example.com", "https://example.com/", "https://EXAMPLE.com/other",
        ] {
            #expect(await harness.engine.shield(for: spelling) == .off, "\(spelling)")
        }
        // A different scheme or port is a different origin.
        #expect(await harness.engine.shield(for: "http://example.com") == .standard)
        #expect(await harness.engine.shield(for: "https://example.com:8443") == .standard)
    }

    @Test func resettingToStandardForgetsTheOverride() async throws {
        let harness = try Harness()
        await harness.engine.setShield(.off, for: "https://example.com")
        await harness.engine.setShield(.standard, for: "https://example.com")

        let relaunched = harness.makeEngine()
        #expect(await relaunched.shield(for: "https://example.com") == .standard)
    }
}

// MARK: - Measurement

/// Not part of the suite: needs the network and drives real WebKit compilation, both of
/// which a unit test must never depend on. Run it to get the numbers quoted in the
/// milestone report, or after a SafariConverterLib bump:
///
/// ```
/// ZENTIC_BLOCKING_LIVE=1 swift test --filter Measurement
/// ```
@Suite(
    "Measurement",
    .enabled(if: ProcessInfo.processInfo.environment["ZENTIC_BLOCKING_LIVE"] == "1")
)
struct MeasurementTests {
    @Test func measuresTheRealListsEndToEnd() async throws {
        for source in FilterListCatalog.defaults {
            let text = try await download(source)
            let rules = FilterListText.lines(of: text)

            let started = ContinuousClock.now
            let converted = try RuleConverter.convert(rules: rules, listID: source.id)
            let elapsed = started.duration(to: .now)

            print(
                """
                MEASURE \(source.id): bytes=\(text.utf8.count) rules=\(rules.count) \
                safari=\(converted.safariRuleCount) dropped=\(converted.droppedRuleCount) \
                convert=\(elapsed) \
                chunks=\(converted.chunks.map { "\($0.ruleClass.rawValue):\($0.entryCount)" })
                """
            )
        }

        let directory = URL.temporaryDirectory.appending(
            path: "zentic-measure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Also the only place the conditional conformance to the frozen protocol is
        // exercised: `installedRuleLists()` exists only when the compiler is WebKit's.
        let blocker: any ContentBlockerService = WebKitContentBlocker(directory: directory)

        let coldStart = ContinuousClock.now
        let seeded = try await blocker.installedRuleLists()
        print("MEASURE cold first-paint lists=\(seeded.count) in \(coldStart.duration(to: .now))")

        let refreshStart = ContinuousClock.now
        let report = try await blocker.refresh(force: false)
        print(
            """
            MEASURE full set: updated=\(report.listsUpdated) compiled=\(report.rulesCompiled) \
            dropped=\(report.rulesDropped) reported=\(report.duration) \
            measured=\(refreshStart.duration(to: .now))
            """
        )

        let warmStart = ContinuousClock.now
        let warm = WebKitContentBlocker(directory: directory)
        let warmLists = try await warm.installedRuleLists()
        print("MEASURE warm launch lists=\(warmLists.count) in \(warmStart.duration(to: .now))")

        let noopStart = ContinuousClock.now
        let noop = try await warm.refresh(force: false)
        print(
            "MEASURE no-op refresh updated=\(noop.listsUpdated) in \(noopStart.duration(to: .now))"
        )
    }

    private func download(_ source: FilterListSource) async throws -> String {
        switch try await URLSessionFilterListFetcher().fetch(source, etag: nil) {
        case .updated(let text, _): return text
        case .notModified: throw BlockerError.downloadFailed(list: source.id, message: "304")
        }
    }
}

// MARK: - Harness

/// Everything a `BlockerEngine` needs, with the network and WebKit replaced.
///
/// The compiler and the directory outlive individual engines so a relaunch can be
/// simulated: `makeEngine()` gives a fresh engine over the same "disk" and the same
/// "WebKit store".
private struct Harness {
    static let listID = "fixture"
    static let listText = try! String(contentsOf: RuleFixture.url("tiny"), encoding: .utf8)

    let directory: URL
    let compiler: RecordingCompiler
    let fetcher: StubFetcher
    let clock: MutableClock
    let engine: BlockerEngine<RecordingCompiler>

    private let refreshesInBackground: Bool

    init(offline: Bool = false, refreshesInBackground: Bool = false) throws {
        directory = URL.temporaryDirectory.appending(path: "zentic-blocking-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        compiler = RecordingCompiler()
        fetcher = StubFetcher(text: Self.listText, etag: "v1", offline: offline)
        clock = MutableClock()
        self.refreshesInBackground = refreshesInBackground
        engine = Self.make(directory, compiler, fetcher, clock, refreshesInBackground)
    }

    func makeEngine() -> BlockerEngine<RecordingCompiler> {
        Self.make(directory, compiler, fetcher, clock, refreshesInBackground)
    }

    private static func make(
        _ directory: URL,
        _ compiler: RecordingCompiler,
        _ fetcher: StubFetcher,
        _ clock: MutableClock,
        _ refreshesInBackground: Bool
    ) -> BlockerEngine<RecordingCompiler> {
        BlockerEngine(
            compiler: compiler,
            fetcher: fetcher,
            directory: directory,
            sources: [
                FilterListSource(
                    id: listID,
                    title: "Fixture",
                    url: URL(string: "https://example.invalid/list.txt")!,
                    isDefault: true
                )
            ],
            seedRules: FilterListCatalog.seedRules(),
            // Off unless a test is specifically about the first-run handover:
            // background work would turn every compile-count assertion into a race.
            refreshesInBackground: refreshesInBackground,
            now: { clock.now }
        )
    }
}

/// Stands in for `WKContentRuleListStore`: remembers what it compiled, and counts.
private actor RecordingCompiler: RuleListCompiling {
    typealias CompiledList = String

    private var store: [String: String] = [:]
    private(set) var compileCount = 0

    func existing(identifier: String) async -> String? {
        store[identifier] == nil ? nil : identifier
    }

    func compile(identifier: String, json: String) async throws -> String {
        compileCount += 1
        store[identifier] = json
        return identifier
    }

    func identifiers() async -> Set<String> { Set(store.keys) }

    func remove(identifier: String) async { store[identifier] = nil }

    func removeAll() { store.removeAll() }
}

private actor StubFetcher: FilterListFetching {
    private var text: String
    private var etag: String
    private let offline: Bool
    private(set) var fetchCount = 0

    init(text: String, etag: String, offline: Bool) {
        self.text = text
        self.etag = etag
        self.offline = offline
    }

    func setText(_ text: String) { self.text = text }
    func setETag(_ etag: String) { self.etag = etag }

    func fetch(_ source: FilterListSource, etag: String?) async throws -> FilterListFetchResult {
        fetchCount += 1
        if offline { throw BlockerError.downloadFailed(list: source.id, message: "offline") }
        if let etag, etag == self.etag { return .notModified }
        return .updated(text: text, etag: self.etag)
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_700_000_000)

    var now: Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { date += interval }
    }
}

// MARK: - Fixtures

enum RuleFixture {
    /// Derived from this file's path so it works under `swift test` and Xcode alike,
    /// without the fixtures having to be a bundle resource.
    static var repoRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()  // ZenticKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    static func url(_ name: String) -> URL {
        repoRoot.appending(path: "Rules/fixtures/\(name).txt")
    }

    static func rules(_ name: String) throws -> [String] {
        FilterListText.lines(of: try String(contentsOf: url(name), encoding: .utf8))
    }
}

/// Minimal reader for Safari content-blocking JSON, so assertions can talk about
/// actions rather than substrings.
private struct Entry: Decodable, Equatable {
    struct Action: Decodable, Equatable {
        var type: String
        var selector: String?
    }
    struct Trigger: Decodable, Equatable {
        var urlFilter: String?
        var ifDomain: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case ifDomain = "if-domain"
        }
    }

    var trigger: Trigger
    var action: Action

    var isBlock: Bool { action.type == "block" || action.type == "block-cookies" }
    var isHide: Bool { action.type == "css-display-none" }
    var isException: Bool { action.type == "ignore-previous-rules" }

    /// Exceptions sort after the rules they override, which is the ordering the
    /// chunker has to preserve.
    var sortKey: Int { isException ? 1 : 0 }

    static func decode(_ json: String) throws -> [Entry] {
        try JSONDecoder().decode([Entry].self, from: Data(json.utf8))
    }
}
