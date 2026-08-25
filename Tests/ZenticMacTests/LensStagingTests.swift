import Foundation
import Testing
import ZenticKit

@testable import ZenticMac

/// Which lens set reaches the page, and which one is allowed to describe it.
///
/// The set is resolved at policy time, because the bootstrap script is the only
/// thing that can put a stylesheet in the cascade before the first paint and it
/// cannot be changed once the document exists. That is two `await`s before a page
/// that may never arrive — so between arming the bootstrap and believing the
/// numbers there are four ways to be wrong, and each of them puts a count on the
/// toolbar about a page the user is not looking at, which invariant 8 forbids as
/// squarely as inventing one.
///
/// ``LensStaging`` is those rules with nothing else in it. It was lifted out of
/// `TabController` for the same reason ``VerdictMemory`` was: the tab needs a
/// SwiftData record and a live `WKWebView`, so as long as the rules lived on it
/// they could not be executed by a test at all — and this is the feature whose
/// first build was entirely inert while 259 tests passed.
@Suite("Lens staging")
struct LensStagingTests {

    // MARK: Fixtures

    static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "lens-staging-\(UUID().uuidString).json")
    }

    static func lens(
        _ id: String,
        pattern: String = "*",
        enabled: Bool = true,
        origin: String = "www.youtube.com",
        updated: TimeInterval = 0
    ) -> Lens {
        Lens(
            id: id,
            name: id.capitalized,
            origin: origin,
            pathPattern: pattern,
            isEnabled: enabled,
            prompt: "hide the suggestions",
            regions: [LensRegion(id: "rail", intent: "the sidebar", selectors: ["#secondary"])],
            ops: [LensOp(id: "\(id)-1", kind: .hide, region: "rail", note: "hide the sidebar")],
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: updated)
        )
    }

    /// A plan built exactly the way `TabController.prepareLenses` builds one: the
    /// applied set and both counts come from one store read, for one URL.
    static func plan(for url: URL, from store: LensStore) async -> LensPlan {
        let all = await store.all().filter { $0.origin == url.host() }
        return LensPlan(
            url: url,
            lenses: await store.lenses(for: url.host() ?? "", path: url.path()),
            siteLensCount: all.count,
            enabledLensCount: all.count { $0.isEnabled }
        )
    }

    private let watch = URL(string: "https://www.youtube.com/watch?v=abc")!
    private let home = URL(string: "https://www.youtube.com/")!

    // MARK: - The set that reaches the page

    /// The whole journey, with nothing mocked: three saved lenses, a URL, and the
    /// state the toolbar ends up drawing.
    ///
    /// The bug this is against is the one this feature shipped with. Every hop here
    /// was present in source and none of them carried anything — the set the store
    /// resolved was not the set the page was armed with, because nothing assigned
    /// it, and the toolbar drew a lens count of zero on a site with lenses on it.
    @Test("The set the store resolves for a URL is the set that commits and is drawn")
    func resolvedSetReachesTheChrome() async throws {
        let store = LensStore(url: Self.temporaryURL())
        // One for this route, one for the whole site, one switched off, and one for
        // a route the user is not on.
        try await store.save(Self.lens("route", pattern: "/watch", updated: 30))
        try await store.save(Self.lens("site", pattern: "*", updated: 20))
        try await store.save(Self.lens("off", pattern: "*", enabled: false, updated: 10))
        try await store.save(Self.lens("elsewhere", pattern: "/shorts", updated: 5))

        var staging = LensStaging()
        let plan = await Self.plan(for: watch, from: store)
        let sequence = staging.begin()
        let armed = staging.arm(plan, sequence: sequence)
        #expect(armed)

        let adopted = staging.commit(at: watch)
        let committed = try #require(adopted)
        // Only the two whose pattern covers `/watch` and are switched on, newest
        // edit first — which is the popover's reading order, not a claim about
        // which of two wins.
        #expect(committed.lenses.map(\.id) == ["route", "site"])
        // The counts the toolbar needs to tell "this site has no lenses" from "this
        // site's lenses are all switched off" from "on, but for another page".
        #expect(committed.siteLensCount == 4)
        #expect(committed.enabledLensCount == 3)

        let state = LensState.make(
            lenses: committed.lenses,
            reports: [:],
            siteLensCount: committed.siteLensCount,
            enabledLensCount: committed.enabledLensCount
        )
        #expect(state.entries.map(\.lens.id) == ["route", "site"])
        // `elsewhere` is on, and for a page the user is not on. The toolbar has a
        // sentence for exactly that, and it needs this number to say it.
        #expect(state.offPathCount == 1)
        // Nothing has reported, so there is no badge. Not `0/2`, not `2/2`.
        #expect(state.tally == nil)
    }

    /// The URL is carried on the plan rather than read back off the tab, and this
    /// is why: the answer is resolved for one page and applied to whatever the tab
    /// happens to be showing when it resumes.
    @Test("A plan resolved for a page with no lenses commits an empty set, not the last one")
    func emptySetIsAnAnswer() async throws {
        let store = LensStore(url: Self.temporaryURL())
        try await store.save(Self.lens("site", origin: "www.youtube.com"))

        var staging = LensStaging()
        let elsewhere = URL(string: "https://example.com/article")!
        let plan = await Self.plan(for: elsewhere, from: store)
        let sequence = staging.begin()
        staging.arm(plan, sequence: sequence)

        let adopted = staging.commit(at: elsewhere)
        let committed = try #require(adopted)
        #expect(committed.lenses.isEmpty)
        #expect(committed.siteLensCount == 0)
        #expect(!LensState.make(lenses: [], reports: [:], siteLensCount: 0).hasLenses)
    }

    // MARK: - A policy decision is not a page

    /// The navigation failed, so the page it was for never existed. Adopting its
    /// set would leave the page still on screen described by another page's counts.
    @Test("A navigation that never produced a document describes nothing")
    func failedNavigationIsDiscarded() {
        var staging = LensStaging()
        let sequence = staging.begin()
        staging.arm(Self.plan(watch, ["route"]), sequence: sequence)

        staging.discard()

        let adopted1 = staging.commit(at: watch)
        #expect(adopted1 == nil)
    }

    /// A server redirect, or a policy decision that lost a race to one. The set the
    /// document actually booted with is unknown at this point, so the honest answer
    /// is "re-resolve", never "assume the one we happened to have".
    @Test("A page that committed somewhere else does not adopt the set it was not resolved for")
    func redirectDoesNotAdoptTheSet() {
        var staging = LensStaging()
        let sequence = staging.begin()
        staging.arm(Self.plan(watch, ["route"]), sequence: sequence)

        let adopted2 = staging.commit(at: home)
        #expect(adopted2 == nil)
    }

    /// `discard()` is not keyed to a navigation — WebKit's failure callbacks do not
    /// carry one the tab can match against — so a cancelled navigation can throw
    /// away the plan of the navigation that replaced it. That degrades to a
    /// re-resolve, which is a hop; adopting the wrong plan would be a wrong number.
    @Test("A cancelled navigation cannot leave its successor describing the wrong page")
    func cancelledNavigationDoesNotBadgeItsSuccessor() {
        var staging = LensStaging()
        // The user clicks /watch, then immediately clicks / before it commits.
        let first = staging.begin()
        staging.arm(Self.plan(watch, ["route"]), sequence: first)
        let second = staging.begin()
        staging.arm(Self.plan(home, ["site"]), sequence: second)
        // /watch's provisional navigation fails with -999, cancelled.
        staging.discard()

        // Whatever else happens, /watch's set does not get to describe /.
        let adopted3 = staging.commit(at: home)
        #expect(adopted3 == nil)
    }

    /// A plan is about one navigation, and consuming it is what makes that true.
    /// Left in place, the next document to commit at a URL the old plan happens to
    /// match — a reload after a download, a back to the same route — would adopt a
    /// set and a pair of counts resolved for a page load that is long over.
    @Test("A plan is consumed by the commit it was for")
    func planIsConsumedOnce() {
        var staging = LensStaging()
        let sequence = staging.begin()
        staging.arm(Self.plan(watch, ["route"]), sequence: sequence)

        let adopted4 = staging.commit(at: watch)
        #expect(adopted4 != nil)
        let adopted5 = staging.commit(at: watch)
        #expect(adopted5 == nil)
    }

    /// A resolution that started and never finished — the tab was torn down, or the
    /// store read is still in flight — must not leave a commit believing an empty
    /// set was resolved for the page.
    @Test("Starting a resolution arms nothing on its own")
    func beginDoesNotArm() {
        var staging = LensStaging()
        _ = staging.begin()

        let adopted6 = staging.commit(at: watch)
        #expect(adopted6 == nil)
    }

    @Test("Discarding nothing is not an error and clears nothing else")
    func discardIsIdempotent() {
        var staging = LensStaging()
        staging.discard()
        let sequence = staging.begin()
        staging.arm(Self.plan(watch, ["route"]), sequence: sequence)
        let adopted7 = staging.commit(at: watch)
        #expect(adopted7 != nil)
    }

    // MARK: - Only the last resolution arms the page

    /// Both halves of a resolution are `await`s and an actor hop is not ordered, so
    /// the answer to an older question can arrive last. It must not rewrite the
    /// bootstrap the live navigation is about to boot from — the set in there is
    /// what applies at `document-start`, so a stale winner is a page visibly
    /// remodelled for somewhere the user is not.
    @Test("The last resolution to start is the one that arms the page")
    func lastResolutionWins() {
        var staging = LensStaging()
        let first = staging.begin()
        let second = staging.begin()

        // The newer one resumes first, as it may.
        let armedFresh = staging.arm(Self.plan(home, ["site"]), sequence: second)
        #expect(armedFresh)
        // The older one resumes last and is refused, so its caller leaves the
        // bootstrap alone.
        let armedStale = staging.arm(Self.plan(watch, ["route"]), sequence: first)
        #expect(!armedStale)

        let committed = staging.commit(at: home)
        #expect(committed?.lenses.map(\.id) == ["site"])
    }

    /// The same race, resolved the ordinary way round. A refused arm must not be
    /// able to leave the staging empty either — that would silently turn every
    /// navigation into a re-resolve.
    @Test("A stale resolution refused after a fresh one does not clear it")
    func staleArmDoesNotClear() {
        var staging = LensStaging()
        let stale = staging.begin()
        let current = staging.begin()
        staging.arm(Self.plan(watch, ["route"]), sequence: current)

        let armed = staging.arm(Self.plan(home, ["site"]), sequence: stale)
        #expect(!armed)
        // Refused, and the live plan is still there — a refusal that emptied the
        // staging would turn every navigation into a re-resolve.
        let adopted8 = staging.commit(at: watch)
        #expect(adopted8?.lenses.map(\.id) == ["route"])
    }

    // MARK: - What counts as the same page

    /// Host and path, and deliberately **not** the query — which is the opposite of
    /// ``DocumentKey``, and the difference is not an oversight. A verdict is about
    /// one page's prose, so `?q=cats` and `?q=dogs` are two documents. A lens
    /// matches on a host and a path *pattern*, so a query change re-resolves to the
    /// identical set; treating it as a different page would throw away a plan that
    /// is exactly right and re-resolve it on every search.
    @Test("A plan is about a host and a path, not a query and not a fragment")
    func describesHostAndPathOnly() {
        let plan = Self.plan(URL(string: "https://www.youtube.com/watch?v=abc")!, ["route"])

        #expect(plan.describes(URL(string: "https://www.youtube.com/watch?v=zzz")))
        #expect(plan.describes(URL(string: "https://www.youtube.com/watch#t=30")))
        #expect(plan.describes(URL(string: "https://www.youtube.com/watch")))

        #expect(!plan.describes(URL(string: "https://www.youtube.com/")))
        #expect(!plan.describes(URL(string: "https://www.youtube.com/shorts")))
        // A different host is a different site, and a lens is per site.
        #expect(!plan.describes(URL(string: "https://m.youtube.com/watch?v=abc")))
        #expect(!plan.describes(nil))
    }

    /// `http` and `https` are the same page for a plan, because they are the same
    /// site for the store: ``Lens/origin`` is a host, so a scheme upgrade must not
    /// throw away a set that is still exactly right.
    @Test("A scheme upgrade is the same page for a lens set")
    func schemeIsNotPartOfTheMatch() {
        let plan = Self.plan(URL(string: "http://www.youtube.com/watch")!, ["route"])
        #expect(plan.describes(URL(string: "https://www.youtube.com/watch")))
    }

    // MARK: Helpers

    private static func plan(_ url: URL, _ ids: [String]) -> LensPlan {
        let lenses = ids.map { lens($0) }
        return LensPlan(
            url: url,
            lenses: lenses,
            siteLensCount: lenses.count,
            enabledLensCount: lenses.count
        )
    }
}
