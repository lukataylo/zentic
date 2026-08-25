import Foundation
import Testing

@testable import ZenticKit

/// The store decides which lenses run on the page in front of the user, and in
/// what order. Every test here is a way for that decision to go wrong silently:
/// a lens that matches nothing, two lenses that list differently on two machines,
/// a lens on disk carrying something a lens is not allowed to carry, a drift badge
/// that forgets it drifted overnight, a file rewritten twice a second by a page
/// that is only scrolling.
@Suite("Lens store")
struct LensStoreTests {

    // MARK: Fixtures

    static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "lens-store-\(UUID().uuidString).json")
    }

    static let region = LensRegion(
        id: "rail",
        intent: "the suggested videos sidebar",
        selectors: ["#secondary"]
    )

    static func op(_ id: String = "op") -> LensOp {
        LensOp(id: id, kind: .hide, region: "rail", note: "hide the suggestions")
    }

    /// A page offering exactly the one anchor these lenses name. See
    /// `LensDraftSaveTests.draftCannotBlankThePage` for why the draft path insists
    /// on having one of these.
    static let catalog = RegionCatalog(
        origin: "www.example.com",
        pathPattern: "*",
        viewport: .init(width: 1280, height: 900),
        candidates: [
            RegionCandidate(
                id: "r0",
                selector: "#secondary",
                tag: "div",
                elementID: "secondary",
                kindGuess: "aside",
                rect: RegionRect(x: 980, y: 0, width: 300, height: 2_000),
                depth: 5,
                textLength: 4_000,
                linkCount: 40,
                paragraphCount: 2,
                imageCount: 12,
                itemCount: 0
            )
        ]
    )

    static func lens(
        _ id: String,
        origin: String = "www.example.com",
        pattern: String = "*",
        enabled: Bool = true,
        created: TimeInterval = 0,
        updated: TimeInterval? = nil
    ) -> Lens {
        Lens(
            id: id,
            name: id,
            origin: origin,
            pathPattern: pattern,
            isEnabled: enabled,
            prompt: "hide the suggestions",
            regions: [region],
            ops: [op()],
            createdAt: Date(timeIntervalSince1970: created),
            updatedAt: Date(timeIntervalSince1970: updated ?? created)
        )
    }

    // MARK: Path generalisation

    @Test("Path patterns generalise exactly as the TypeScript does")
    func pathPatternMatchesTheTypeScript() {
        // These are `web/src/skeleton.ts:pathPattern()`'s rules, case by case. A
        // divergence here does not fail loudly anywhere: the editor shows the user
        // one pattern, the store matches a different one, and the lens they watched
        // being created never fires again.
        #expect(LensPath.pattern(for: "/") == "/")
        #expect(LensPath.pattern(for: "") == "/")
        #expect(LensPath.pattern(for: "/watch") == "/watch")
        // A numeric segment is an identity, not a page shape.
        #expect(LensPath.pattern(for: "/posts/12345/my-title") == "/posts/*/my-title")
        // 16+ hex characters: a content hash.
        #expect(LensPath.pattern(for: "/a/deadbeefdeadbeef") == "/a/*")
        #expect(LensPath.pattern(for: "/a/deadbeefdeadbee") == "/a/deadbeefdeadbee")
        // A UUID anywhere in the segment, not just as the whole segment.
        #expect(LensPath.pattern(for: "/x/id-123e4567-e89b-12d3-a456-426614174000") == "/x/*")
        // Longer than 24 characters: a slug.
        #expect(LensPath.pattern(for: "/blog/the-quick-brown-fox-jumped-over") == "/blog/*")
        // Short but numbered: also a slug.
        #expect(LensPath.pattern(for: "/x/ab12345") == "/x/*")
        // Four characters with a digit is a section name, not an id — the
        // TypeScript's `length > 4` boundary, which is off-by-one-able.
        #expect(LensPath.pattern(for: "/x/ab12") == "/x/ab12")
        // Percent-encoding is decoded before the rules run, so an encoded number is
        // still a number.
        #expect(LensPath.pattern(for: "/a/%31%32%33") == "/a/*")
        // ICU's `\d` matches Devanagari digits and JavaScript's does not; the port
        // uses `[0-9]` so this segment survives in both.
        #expect(LensPath.pattern(for: "/a/१२३४५६") == "/a/१२३४५६")
    }

    @Test("A wildcard segment matches the concrete path it was generalised from")
    func wildcardsMatchConcretePaths() {
        // The case the spec calls out: `/posts/*/*` must cover the page the user was
        // looking at when they chose "pages like this". Note that generalising that
        // path gives `/posts/*/my-title`, since `my-title` is short and has no
        // digits — so matching cannot be "generalise and compare strings".
        #expect(LensPath.matches(pattern: "/posts/*/*", path: "/posts/12345/my-title"))
        #expect(LensPath.matches(pattern: "/posts/*/my-title", path: "/posts/12345/my-title"))
        #expect(LensPath.matches(pattern: "/posts/*", path: "/posts/98765"))
        #expect(LensPath.matches(pattern: "*", path: "/anything/at/all"))
        #expect(LensPath.matches(pattern: "/watch", path: "/watch"))
        #expect(LensPath.matches(pattern: "/", path: "/"))

        // Segment counts must agree: a pattern for a post is not a pattern for the
        // index of posts.
        #expect(!LensPath.matches(pattern: "/posts/*/*", path: "/posts/12345"))
        #expect(!LensPath.matches(pattern: "/posts/*", path: "/posts/12345/my-title"))
        #expect(!LensPath.matches(pattern: "/watch", path: "/results"))
    }

    @Test("A path always matches the pattern generalised from it")
    func generalisationAlwaysMatches() {
        // The property that ties the two functions together, and the one that breaks
        // first if either drifts.
        for path in [
            "/", "/watch", "/posts/12345/my-title", "/a/deadbeefdeadbeef",
            "/blog/the-quick-brown-fox-jumped-over", "/x/ab12", "/a/b/c/d/e",
            // Percent-encoded, which is how every non-ASCII or spaced URL arrives.
            "/wiki/%E7%8C%AB", "/search/hello%20world",
        ] {
            #expect(LensPath.matches(pattern: LensPath.pattern(for: path), path: path))
        }
    }

    @Test("A percent-encoded pattern matches the path it was stored from")
    func encodedPatternsMatch() {
        // Only the path used to be decoded. So a "this page" lens on any URL with
        // a non-ASCII or spaced segment never fired on the page it was created on:
        // the stored pattern held `%E7%8C%AB`, the live path decoded to `猫`, and
        // the comparison was between two spellings of one segment. Nothing about
        // that looks like drift, so the drift UI could not explain it either.
        #expect(LensPath.matches(pattern: "/wiki/%E7%8C%AB", path: "/wiki/%E7%8C%AB"))
        #expect(LensPath.matches(pattern: "/wiki/%E7%8C%AB", path: "/wiki/猫"))
        #expect(LensPath.matches(pattern: "/wiki/猫", path: "/wiki/%E7%8C%AB"))
        #expect(LensPath.matches(pattern: "/search/hello%20world", path: "/search/hello world"))

        // Decoding happens after the split, so an encoded slash cannot invent a
        // segment boundary and make a one-segment pattern match a two-segment path.
        #expect(!LensPath.matches(pattern: "/a%2Fb", path: "/a/b"))
    }

    // MARK: Matching

    @Test("Only enabled lenses for this host and path apply")
    func matchingSelectsTheActiveSet() async throws {
        let store = LensStore(url: Self.temporaryURL())
        try await store.save(Self.lens("site-wide"))
        try await store.save(Self.lens("watch-only", pattern: "/watch"))
        try await store.save(Self.lens("posts", pattern: "/posts/*/*"))
        try await store.save(Self.lens("disabled", enabled: false))
        try await store.save(Self.lens("elsewhere", origin: "other.example.com"))

        let onWatch = await store.lenses(for: "www.example.com", path: "/watch")
        #expect(Set(onWatch.map(\.id)) == ["site-wide", "watch-only"])

        let onPost = await store.lenses(for: "www.example.com", path: "/posts/99/hello")
        #expect(Set(onPost.map(\.id)) == ["site-wide", "posts"])

        // DNS is case-insensitive, so a lens saved from a capitalised host must
        // still match.
        let capitalised = await store.lenses(for: "WWW.Example.com", path: "/watch")
        #expect(Set(capitalised.map(\.id)) == ["site-wide", "watch-only"])
    }

    @Test("Lenses list newest edit first, and the sequence is total")
    func stackingOrderIsTotal() async throws {
        let store = LensStore(url: Self.temporaryURL())
        // Deliberately saved in the wrong order: the sequence must come from the
        // fields, not from insertion, or two machines holding the same lenses would
        // show the user two different lists.
        try await store.save(Self.lens("oldest", updated: 10))
        try await store.save(Self.lens("newest", updated: 40))
        try await store.save(Self.lens("middle", pattern: "/watch", updated: 20))

        let applied = await store.lenses(for: "www.example.com", path: "/watch")
        #expect(applied.map(\.id) == ["newest", "middle", "oldest"])
    }

    @Test("The popover's first row is the lens whose effect is on the page")
    func popoverListsTheLensThePageIsShowing() async throws {
        // Two sorts of ``Lens/updatedAt``, pointing opposite ways on purpose: this
        // one descending because its list is read by a person, `appliesBefore` in
        // `web/src/lens/index.ts` ascending because its list is applied and the
        // cascade lets the last one stand. Both halves say so in a comment, which
        // is precisely what the path matcher's two halves also said while one of
        // them silently dropped every wildcard pattern the other had matched.
        //
        // So the claim is asserted rather than argued, at the point the user meets
        // it: the lens they edited most recently is the top row of the popover,
        // and it is the one whose ops the page lets win. The other half —
        // the same pair, moved to two different places, ending up where the newer
        // lens said — is "puts the most recently edited lens's effect on the page"
        // in `web/test/lens/engine.test.ts`.
        let store = LensStore(url: Self.temporaryURL())
        try await store.save(Self.lens("older", updated: 10))
        try await store.save(Self.lens("newer", updated: 20))

        let handedToThePage = await store.lenses(for: "www.example.com", path: "/watch")
        let state = LensState.make(lenses: handedToThePage, reports: [:])

        #expect(state.entries.first?.lens.id == "newer")
        // And the page applies that same list back to front, so the row the user
        // reads first is the lens whose ops reach the cascade last. Reversed
        // *whole*, ties included — see ``LensStore/lenses(for:path:)``.
        #expect(Array(handedToThePage.reversed()).map(\.id) == ["older", "newer"])
    }

    @Test("Two lenses edited in the same instant still stack the same way everywhere")
    func identicalTimestampsBreakOnID() async throws {
        // Real: a save and a `setEnabled` in the same millisecond, or two lenses
        // written by one migration. Without a total order the two machines holding
        // the same file list them differently, and the popover then describes a
        // sequence the page is not using.
        //
        // Ascending id here, descending in `appliesBefore`, so the two lists stay
        // exact mirrors through a tie as well. When both broke it ascending, this
        // test and its TypeScript twin both passed while the popover's first row
        // was the lens the page had let *lose*.
        let store = LensStore(url: Self.temporaryURL())
        try await store.save(Self.lens("b", updated: 100))
        try await store.save(Self.lens("a", updated: 100))
        try await store.save(Self.lens("c", updated: 100))

        #expect(
            await store.lenses(for: "www.example.com", path: "/").map(\.id) == ["a", "b", "c"]
        )
    }

    @Test("Editing a lens moves it to the top of its site's list")
    func editingRestacks() async throws {
        // The whole of the cheap conflict model: the lens the user touched last is
        // the one they were thinking about, so it is the one they read first. There
        // is no other way to reorder the list, and there does not need to be.
        let store = LensStore(url: Self.temporaryURL())
        try await store.save(Self.lens("first", updated: 10))
        try await store.save(Self.lens("second", updated: 20))
        #expect(await store.all().map(\.id) == ["second", "first"])

        var edited = Self.lens("first", updated: 10)
        edited.name = "renamed"
        _ = try await store.save(draft: edited, origin: "www.example.com", against: Self.catalog)

        #expect(await store.all().map(\.id) == ["first", "second"])
    }

    // MARK: Mutation

    @Test("Enabling and disabling takes a lens out of the active set and back")
    func enableDisable() async throws {
        let store = LensStore(url: Self.temporaryURL())
        try await store.save(Self.lens("a"))

        await store.setEnabled(false, id: "a")
        #expect(await store.lenses(for: "www.example.com", path: "/").isEmpty)
        // Still stored, just not applied — disabling is not deleting.
        #expect(await store.all().count == 1)

        await store.setEnabled(true, id: "a")
        #expect(await store.lenses(for: "www.example.com", path: "/").count == 1)
    }

    @Test("Deleting removes the lens from disk, not just from the active set")
    func deletePersists() async throws {
        let url = Self.temporaryURL()
        let store = LensStore(url: url)
        try await store.save(Self.lens("a"))
        await store.delete(id: "a")

        #expect(await LensStore(url: url).all().isEmpty)
    }

    @Test("A site cannot accumulate more lenses than the budget allows")
    func perOriginCapIsEnforced() async throws {
        let store = LensStore(url: Self.temporaryURL())
        for index in 0..<Budget.lensMaxLensesPerOrigin {
            try await store.save(Self.lens("lens-\(index)"))
        }

        // Rejected with a typed error, not silently dropped: the user is watching
        // this happen and has to be told why it did not.
        await #expect(
            throws: LensStoreError.tooManyLenses(
                origin: "www.example.com",
                limit: Budget.lensMaxLensesPerOrigin
            )
        ) {
            try await store.save(Self.lens("one-too-many"))
        }

        // Editing a lens at the cap still works: the limit exists to stop a pile
        // accumulating, not to trap the user in the pile they have.
        var edited = Self.lens("lens-0")
        edited.name = "renamed"
        try await store.save(edited)
        #expect(await store.lens(id: "lens-0")?.name == "renamed")

        // The cap is per origin, so another site is unaffected.
        try await store.save(Self.lens("elsewhere", origin: "other.example.com"))
    }

    @Test("A lens from a build with a different shape is dropped, not half-applied")
    func incompatibleSchemaIsRefused() async throws {
        let store = LensStore(url: Self.temporaryURL())
        var stale = Self.lens("stale")
        stale.schemaVersion = Lens.currentSchemaVersion + 1

        await #expect(
            throws: LensStoreError.incompatibleSchema(version: Lens.currentSchemaVersion + 1)
        ) {
            try await store.save(stale)
        }
    }

    // MARK: Failure posture

    @Test("An absent file is an empty store")
    func absentFileIsEmpty() async throws {
        let store = LensStore(url: Self.temporaryURL())
        #expect(await store.all().isEmpty)
        #expect(await store.lenses(for: "www.example.com", path: "/").isEmpty)
    }

    @Test("A corrupt file is an empty store, never a crash")
    func corruptFileIsEmptyAndStillWritable() async throws {
        let url = Self.temporaryURL()
        try Data("{ this is not a lens file".utf8).write(to: url)

        let store = LensStore(url: url)
        #expect(await store.all().isEmpty)

        // And the store is still usable: losing lenses the user can re-fit is the
        // acceptable failure, refusing to work from then on is not.
        try await store.save(Self.lens("fresh"))
        #expect(await LensStore(url: url).all().map(\.id) == ["fresh"])
    }

    @Test("A lens on disk carrying a hostile selector never reaches the page")
    func storedLensesAreValidatedOnLoad() async throws {
        // `Lenses.json` is a plain file in Application Support. Anything that can
        // write there — a hand edit, a sync conflict, an older build whose gate was
        // looser — can put a selector in it, and the store's output is interpolated
        // straight into the bootstrap script. Validating only on save would leave
        // the read path as an unguarded way in.
        let url = Self.temporaryURL()
        var hostile = Self.lens("hostile")
        hostile.regions = [
            LensRegion(
                id: "rail",
                intent: "the sidebar",
                selectors: ["#secondary{background:url(https://tracker.example/p)}"]
            )
        ]
        try JSONEncoder().encode([hostile, Self.lens("clean")]).write(to: url)

        #expect(await LensStore(url: url).all().map(\.id) == ["clean"])
    }

    @Test("A file holding lenses from an older schema loads the rest")
    func incompatibleStoredLensesAreSkipped() async throws {
        let url = Self.temporaryURL()
        var stale = Self.lens("stale")
        stale.schemaVersion = 0
        let encoder = JSONEncoder()
        try encoder.encode([stale, Self.lens("current")]).write(to: url)

        #expect(await LensStore(url: url).all().map(\.id) == ["current"])
    }

    // MARK: Drift

    @Test("A drift report survives a relaunch")
    func reportsPersist() async throws {
        let url = Self.temporaryURL()
        let store = LensStore(url: url)
        try await store.save(Self.lens("a"))

        let report = LensReport(
            lensID: "a",
            url: "https://www.example.com/watch",
            results: [
                LensOpResult(opID: "op", status: .missed, message: "no selector matched")
            ],
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )
        await store.recordReport(report)
        // A report is coalesced rather than written inline — see
        // `identicalReportsWriteOnce`. Forced here rather than slept on, which is
        // also the only reason `flush()` is on the store's face: a delayed write
        // needs someone able to end it, and the app ends it on the way to quitting.
        await store.flush()

        // The point of persisting: the toolbar can badge the lens amber before the
        // page it drifted on has even started loading.
        let reloaded = try #require(await LensStore(url: url).lens(id: "a"))
        #expect(reloaded.lastReport?.isDrifted == true)
        #expect(reloaded.lastReport?.missedCount == 1)
        // The path, not the URL. This assertion used to name the whole URL and so
        // bound the unfixed behaviour in place: the store took the page's word for
        // what it had visited and wrote the query string into a file that outlives
        // the session.
        #expect(reloaded.lastReport?.url == "/watch")
    }

    @Test("A report is capped and stripped by the store, not by the page's good manners")
    func recordReportIsValidated() async throws {
        // The stripping lives in `web/src/lens/index.ts`, which is the untrusted
        // side of the wire: an event arrives page → app, so a page that skips the
        // step — or a build of the runner from before it existed — writes whatever
        // it likes into `Lenses.json`. Nothing capped `results`, `message`,
        // `usedSelector` or `matchedCount` either, so one event could make the
        // file megabytes and the popover unusable.
        let url = Self.temporaryURL()
        let store = LensStore(url: url)
        try await store.save(Self.lens("a"))

        await store.recordReport(
            LensReport(
                lensID: "a",
                url: "https://www.example.com/watch?v=1&session=secret#t=90",
                results: (0..<2_000).map { index in
                    LensOpResult(
                        opID: "op\(index)",
                        status: .applied,
                        matchedCount: .max,
                        usedSelector: String(repeating: "x", count: 1_000),
                        message: String(repeating: "m", count: 4_000)
                    )
                },
                generatedAt: Date(timeIntervalSince1970: 1_000)
            )
        )

        // The running store, not a reload: `load()` validates too, so reading the
        // file back would pass even if `recordReport` stored the lot.
        let stored = try #require(await store.lens(id: "a")?.lastReport)
        #expect(stored.url == "/watch")
        #expect(stored.results.count == LensReport.maxResults)
        #expect(stored.results.first?.message?.count == LensOp.maxNoteLength)
        #expect(stored.results.first?.usedSelector == nil)
    }

    @Test("A hostile lens is refused by save, not left for the next launch to filter")
    func saveIsGated() async throws {
        // `save(_:)` is the only in-process gate on the page → app draft path:
        // `LensController.save(draft:)` hands a lens the editor built straight to
        // it, and what the store holds is what the next navigation interpolates
        // into the bootstrap script. Deleting the `validated()` call left the whole
        // suite green, because every other assertion about hostile lenses reads
        // them back through `load()`, which validates on the way in.
        let store = LensStore(url: Self.temporaryURL())
        var hostile = Self.lens("hostile")
        hostile.regions = [
            LensRegion(
                id: "rail",
                intent: "the sidebar",
                selectors: ["#secondary{background:url(https://tracker.example/p)}"]
            )
        ]

        await #expect(
            throws: LensStoreError.rejected(reason: "no op in this lens could act on a page")
        ) {
            try await store.save(hostile)
        }
        // And nothing reached the set this store would hand to a page.
        #expect(await store.all().isEmpty)
        #expect(await store.lenses(for: "www.example.com", path: "/").isEmpty)
    }

    @Test("A lens on disk naming the page root cannot blank the site")
    func storedLensCannotBlankThePage() async throws {
        // `save(_:)` and `load()` both validate with no catalog — there is no page
        // to check against when reading a file, and there does not need to be:
        // `Lenses.json` is the user's own file, so what this defends against is a
        // typo or a lens written by a build whose gate was looser. The literal
        // spellings are what those produce. Breadth on the *draft* path, where the
        // input is a page talking to us, is the catalog's job — see
        // `LensControllerSaveTests` for that half.
        for selector in ["body", "html", ":root", "*"] {
            let store = LensStore(url: Self.temporaryURL())
            var blanking = Self.lens("blank")
            blanking.regions = [
                LensRegion(id: "rail", intent: "the sidebar", selectors: [selector])
            ]

            await #expect(throws: LensStoreError.self, "\(selector) was storable") {
                try await store.save(blanking)
            }
            #expect(await store.all().isEmpty)
        }
    }

    // MARK: Write rate

    @Test("A page that keeps saying the same thing is not a page that keeps writing")
    func identicalReportsWriteOnce() async throws {
        // The measured problem: `LensEngine` re-posts a coalesced full report every
        // 500ms for as long as any observer is live, and the tab records one per
        // lens, so a scrolling feed with three lenses meant six whole-file encode
        // and write cycles a second — on a store that reaches a few hundred
        // kilobytes, from a blocking write on the actor's own thread.
        //
        // Observed by deleting the file and watching for it to come back, rather
        // than by counting writes through a seam the shipping code would carry: an
        // absent file is exactly what "nothing was written" means.
        let url = Self.temporaryURL()
        let store = LensStore(url: url)
        try await store.save(Self.lens("a"))

        func report(at seconds: TimeInterval, matched: Int = 1) -> LensReport {
            LensReport(
                lensID: "a",
                url: "/watch",
                results: [LensOpResult(opID: "op", status: .applied, matchedCount: matched)],
                generatedAt: Date(timeIntervalSince1970: seconds)
            )
        }

        await store.recordReport(report(at: 0))
        await store.flush()
        #expect(FileManager.default.fileExists(atPath: url.path()))

        try FileManager.default.removeItem(at: url)
        for second in 1...20 { await store.recordReport(report(at: TimeInterval(second))) }
        await store.flush()
        #expect(
            !FileManager.default.fileExists(atPath: url.path()),
            "twenty identical reports wrote the store again"
        )

        // And a report that actually says something different still lands: the
        // dedup must not be a way to stop persisting drift.
        await store.recordReport(report(at: 21, matched: 0))
        await store.flush()
        #expect(FileManager.default.fileExists(atPath: url.path()))
        #expect(await LensStore(url: url).lens(id: "a")?.lastReport?.results.first?.matchedCount == 0)
    }

    @Test("A changed report is written once for a run of changes, not once each")
    func changedReportsCoalesce() async throws {
        // What survives the dedup is a genuine change, and on a virtualised feed
        // those arrive at report rate too: `matchedCount` moves every time the
        // list recycles a card. So the second half of the fix is that a changed
        // report marks the store dirty and one write follows, rather than a write
        // per report.
        let url = Self.temporaryURL()
        let store = LensStore(url: url)
        try await store.save(Self.lens("a"))
        try FileManager.default.removeItem(at: url)

        for matched in 1...20 {
            await store.recordReport(
                LensReport(
                    lensID: "a",
                    url: "/watch",
                    results: [
                        LensOpResult(opID: "op", status: .applied, matchedCount: matched)
                    ],
                    generatedAt: Date(timeIntervalSince1970: TimeInterval(matched))
                )
            )
        }
        // Nothing yet: twenty different reports, none of them on disk.
        #expect(!FileManager.default.fileExists(atPath: url.path()))

        await store.flush()
        // One write, carrying the last of them.
        #expect(await LensStore(url: url).lens(id: "a")?.lastReport?.results.first?.matchedCount == 20)
    }

    @Test("An edit the user made is on disk before the call returns")
    func userEditsAreNotCoalesced() async throws {
        // The coalescer is for reports only. A lens the user just saved, deleted or
        // switched off is their work and they are watching: one that survives a
        // crash only if it happened to be more than two seconds old is not saved.
        let url = Self.temporaryURL()
        let store = LensStore(url: url)

        try await store.save(Self.lens("a"))
        #expect(await LensStore(url: url).all().map(\.id) == ["a"])

        await store.setEnabled(false, id: "a")
        #expect(await LensStore(url: url).lens(id: "a")?.isEnabled == false)

        await store.delete(id: "a")
        #expect(await LensStore(url: url).all().isEmpty)
    }

    @Test("A report for a lens that has been deleted is dropped, not an error")
    func reportForUnknownLens() async throws {
        let store = LensStore(url: Self.temporaryURL())
        // Normal: a page keeps running the set it was handed until it reloads, so
        // reports for just-deleted lenses arrive routinely.
        await store.recordReport(
            LensReport(lensID: "gone", url: "https://x.example/", results: [], generatedAt: .now)
        )
        #expect(await store.all().isEmpty)
    }
}
