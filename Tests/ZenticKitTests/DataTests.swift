import Foundation
import Testing

@testable import ZenticKit

@Suite("Tab residency")
struct TabResidencyTests {

    @Test("Nothing is evicted until capacity is exceeded")
    func fillsToCapacity() {
        var residency = TabResidency(capacity: 3)
        let ids = (0..<3).map { _ in UUID() }
        for id in ids {
            #expect(residency.activate(id).isEmpty)
        }
        #expect(residency.count == 3)
    }

    @Test("The least recently used tab is evicted first")
    func evictsLeastRecentlyUsed() {
        var residency = TabResidency(capacity: 3)
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()

        residency.activate(a)
        residency.activate(b)
        residency.activate(c)
        // Touching `a` makes `b` the oldest, so `b` — not `a` — must go.
        residency.activate(a)

        #expect(residency.activate(d) == [b])
        #expect(residency.resident == [c, a, d])
    }

    @Test("The tab being activated is never the one evicted")
    func neverEvictsTheForegroundTab() {
        // The failure this guards against: at capacity 1, admitting a tab and then
        // trimming to capacity in the wrong order suspends the web view the user is
        // looking at, which reads as a blank window.
        var residency = TabResidency(capacity: 1)
        let a = UUID(), b = UUID()

        #expect(residency.activate(a).isEmpty)
        let evicted = residency.activate(b)
        #expect(evicted == [a])
        #expect(residency.resident == [b])
    }

    @Test("Re-activating a resident tab evicts nothing and reorders")
    func reactivationIsFree() {
        var residency = TabResidency(capacity: 2)
        let a = UUID(), b = UUID()
        residency.activate(a)
        residency.activate(b)

        #expect(residency.activate(a).isEmpty)
        #expect(residency.resident == [b, a])
        #expect(residency.count == 2)
    }

    @Test("Removing a closed tab frees a slot without evicting anything")
    func removeFreesASlot() {
        var residency = TabResidency(capacity: 2)
        let a = UUID(), b = UUID(), c = UUID()
        residency.activate(a)
        residency.activate(b)

        residency.remove(a)
        #expect(residency.activate(c).isEmpty)
        #expect(residency.resident == [b, c])
    }

    @Test("Thirty tabs in a row leave exactly the budget resident")
    func thirtyTabsStayWithinBudget() {
        // The M1 memory ceiling, expressed as the invariant the shell relies on.
        var residency = TabResidency()
        var suspended: [UUID] = []
        let ids = (0..<30).map { _ in UUID() }

        for id in ids {
            suspended.append(contentsOf: residency.activate(id))
        }

        #expect(residency.count == Budget.maxLiveWebViews)
        #expect(suspended.count == 30 - Budget.maxLiveWebViews)
        #expect(residency.resident == Array(ids.suffix(Budget.maxLiveWebViews)))
        // Every tab is accounted for exactly once: resident or suspended, never both.
        #expect(Set(suspended).isDisjoint(with: Set(residency.resident)))
        #expect(Set(suspended).union(residency.resident).count == 30)
    }

    @Test("drain evicts everything, oldest first")
    func drainEvictsEverything() {
        var residency = TabResidency(capacity: 4)
        let a = UUID(), b = UUID()
        residency.activate(a)
        residency.activate(b)

        #expect(residency.drain() == [a, b])
        #expect(residency.count == 0)
    }
}

@Suite("Suspension round trip")
@MainActor
struct SuspensionTests {

    @Test("Captured state survives a store save and reload")
    func roundTripsThroughTheStore() throws {
        let store = try BrowsingStore(url: nil)
        let space = store.addSpace(title: "S", tintHex: "#112233", symbolName: "circle")
        let tab = store.addTab(to: space, url: URL(string: "https://example.com/a"))

        let captured = SuspendedTabState(
            urlString: "https://example.com/deep/page?q=1",
            title: "Deep Page",
            scrollY: 1_842.5,
            canGoBack: true,
            canGoForward: false,
            interactionState: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            snapshotData: Data(repeating: 0x42, count: 128)
        )
        tab.apply(captured)
        store.save()

        let reloaded = try #require(store.tab(id: tab.id))
        #expect(reloaded.suspendedState == captured)
    }

    @Test("A capture with no snapshot keeps the previous one")
    func nilSnapshotDoesNotClobber() throws {
        // takeSnapshot fails on an occluded or still-loading web view. Writing that
        // nil through would replace a usable placeholder with a blank rectangle.
        let store = try BrowsingStore(url: nil)
        let space = store.addSpace(title: "S", tintHex: "#112233", symbolName: "circle")
        let tab = store.addTab(to: space, url: URL(string: "https://example.com"))

        tab.apply(SuspendedTabState(urlString: "https://example.com", snapshotData: Data([1, 2, 3])))
        tab.apply(SuspendedTabState(urlString: "https://example.com/next", snapshotData: nil))

        #expect(tab.snapshotData == Data([1, 2, 3]))
        #expect(tab.urlString == "https://example.com/next")
    }

    @Test("A tab with no interaction state still knows where to reload")
    func degradesToUrlAndOffset() throws {
        let store = try BrowsingStore(url: nil)
        let space = store.addSpace(title: "S", tintHex: "#112233", symbolName: "circle")
        let tab = store.addTab(to: space, url: URL(string: "https://example.com/x"))
        tab.apply(SuspendedTabState(urlString: "https://example.com/x", scrollY: 400))

        let state = tab.suspendedState
        #expect(state.interactionState == nil)
        #expect(state.urlString == "https://example.com/x")
        #expect(state.scrollY == 400)
    }
}

@Suite("Visit counting")
@MainActor
struct VisitCountingTests {

    @Test("Visits accumulate per origin, not per URL")
    func countsByOrigin() throws {
        let store = try BrowsingStore(url: nil)
        store.recordVisit(url: URL(string: "https://example.com/a")!, title: "A")
        store.recordVisit(url: URL(string: "https://example.com/b")!, title: "B")
        store.recordVisit(url: URL(string: "https://other.com/a")!, title: "C")

        #expect(store.siteStat(for: "https://example.com")?.visitCount == 2)
        #expect(store.siteStat(for: "https://other.com")?.visitCount == 1)
    }

    @Test("Repeating the same URL updates the entry instead of appending")
    func consecutiveVisitsCollapse() throws {
        // A page that redirects or fires pushState three times is one visit to a
        // person; three rows would swamp the ⌘K list with duplicates.
        let store = try BrowsingStore(url: nil)
        let url = URL(string: "https://example.com/a")!
        store.recordVisit(url: url, title: "")
        store.recordVisit(url: url, title: "Real Title")

        let history = store.recentHistory()
        #expect(history.count == 1)
        #expect(history[0].title == "Real Title")
        // Still two visits to the origin — collapsing is a history concern only.
        #expect(store.siteStat(for: "https://example.com")?.visitCount == 2)
    }

    @Test("Non-web schemes are not recorded")
    func ignoresNonWebSchemes() throws {
        let store = try BrowsingStore(url: nil)
        store.recordVisit(url: URL(string: "about:blank")!, title: "blank")
        store.recordVisit(url: URL(string: "file:///etc/hosts")!, title: "hosts")

        #expect(store.recentHistory().isEmpty)
        #expect(store.topSites().isEmpty)
    }

    @Test("topSites ranks by visit count")
    func topSitesIsRanked() throws {
        let store = try BrowsingStore(url: nil)
        for _ in 0..<5 { store.recordVisit(url: URL(string: "https://a.com/\(UUID())")!, title: "a") }
        for _ in 0..<2 { store.recordVisit(url: URL(string: "https://b.com/\(UUID())")!, title: "b") }

        #expect(store.topSites().map(\.origin) == ["https://a.com", "https://b.com"])
    }

    @Test("Recipe inference waits for the visit threshold")
    func inferenceThreshold() throws {
        let store = try BrowsingStore(url: nil)
        let url = URL(string: "https://a.com/")!
        for _ in 0..<(Budget.inferenceVisitThreshold - 1) {
            store.recordVisit(url: url, title: "a")
        }
        #expect(store.siteStat(for: "https://a.com")?.deservesRecipeInference == false)

        store.recordVisit(url: URL(string: "https://a.com/other")!, title: "a")
        let stat = try #require(store.siteStat(for: "https://a.com"))
        #expect(stat.deservesRecipeInference)

        stat.recipeGeneratedAt = .now
        #expect(!stat.deservesRecipeInference)
        stat.recipeGeneratedAt = Date(timeIntervalSinceNow: -Budget.recipeMaxAge - 1)
        #expect(stat.deservesRecipeInference)
    }
}

@Suite("Session restore")
@MainActor
struct SessionRestoreTests {

    @Test("Spaces, tabs, groups and suspension state survive a relaunch")
    func restoresAcrossRelaunch() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "zentic-test-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }

        let workSpaceID: UUID
        let pinnedID: UUID
        let groupedID: UUID

        // Scoped so the container is released before the "relaunch" opens the file
        // again — the same sequence a real quit performs.
        do {
            let store = try BrowsingStore(url: url)
            let spaces = store.spacesEnsuringDefault()
            #expect(spaces.count == Space.firstRunSeeds.count)

            let work = try #require(spaces.last)
            workSpaceID = work.id

            let pinned = store.addTab(
                to: work,
                url: URL(string: "https://pinned.example"),
                title: "Pinned",
                pinned: true
            )
            pinnedID = pinned.id
            pinned.apply(
                SuspendedTabState(
                    urlString: "https://pinned.example/inner",
                    title: "Pinned Inner",
                    scrollY: 96,
                    canGoBack: true,
                    interactionState: Data([7, 7, 7])
                )
            )

            let group = store.addGroup(to: work, title: "Research")
            let grouped = store.addTab(
                to: work,
                url: URL(string: "https://grouped.example"),
                title: "Grouped",
                group: group
            )
            groupedID = grouped.id

            store.addFolder(
                to: work,
                title: "Reading",
                items: [Bookmark(title: "Spec", urlString: "https://spec.example")]
            )
            store.recordVisit(url: URL(string: "https://visited.example/x")!, title: "Visited")
            store.save()
        }

        let store = try BrowsingStore(url: url)
        let spaces = store.spacesEnsuringDefault()
        #expect(spaces.count == Space.firstRunSeeds.count)

        let work = try #require(spaces.first { $0.id == workSpaceID })
        #expect(work.tabs.count == 2)
        #expect(work.groups.map(\.title) == ["Research"])
        #expect(work.folders.first?.items.first?.urlString == "https://spec.example")

        let pinned = try #require(store.tab(id: pinnedID))
        #expect(pinned.isPinned)
        #expect(pinned.urlString == "https://pinned.example/inner")
        #expect(pinned.scrollY == 96)
        #expect(pinned.interactionState == Data([7, 7, 7]))

        let grouped = try #require(store.tab(id: groupedID))
        #expect(grouped.group?.title == "Research")
        #expect(grouped.isPinned == false)

        #expect(store.recentHistory().map(\.title) == ["Visited"])
        #expect(store.siteStat(for: "https://visited.example")?.visitCount == 1)
    }

    @Test("A fresh store seeds spaces exactly once")
    func seedingIsIdempotent() throws {
        let store = try BrowsingStore(url: nil)
        let first = store.spacesEnsuringDefault()
        let second = store.spacesEnsuringDefault()
        #expect(first.count == second.count)
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("Closing a tab does not take its group's other tabs with it")
    func closingATabIsNotCascading() throws {
        let store = try BrowsingStore(url: nil)
        let space = store.addSpace(title: "S", tintHex: "#112233", symbolName: "circle")
        let group = store.addGroup(to: space, title: "G")
        let a = store.addTab(to: space, url: URL(string: "https://a.example"), group: group)
        store.addTab(to: space, url: URL(string: "https://b.example"), group: group)

        store.close(a)
        #expect(group.tabs.count == 1)
        #expect(store.tab(id: a.id) == nil)
    }
}

@Suite("Fuzzy match")
struct FuzzyMatchTests {

    @Test("An empty query matches everything, so the palette can show recents")
    func emptyQueryMatches() {
        #expect(FuzzyMatcher.match("", in: "anything")?.score == 0)
    }

    @Test("Non-subsequences do not match")
    func rejectsNonSubsequence() {
        #expect(FuzzyMatcher.match("zzz", in: "github.com") == nil)
        #expect(FuzzyMatcher.match("hg", in: "github") == nil)
    }

    @Test("Matching is case insensitive and records offsets")
    func recordsOffsets() {
        let match = FuzzyMatcher.match("GH", in: "github")
        #expect(match?.matched == [0, 3])
    }

    @Test("A prefix match outranks a mid-string match")
    func prefixWins() {
        let direct = FuzzyMatcher.match("g", in: "google.com")?.score ?? .min
        let nested = FuzzyMatcher.match("g", in: "pages.example.com/g")?.score ?? .min
        #expect(direct > nested)
    }

    @Test("Contiguous runs outrank scattered characters")
    func adjacencyWins() {
        let contiguous = FuzzyMatcher.match("read", in: "readme")?.score ?? .min
        let scattered = FuzzyMatcher.match("read", in: "rendered-and-dropped")?.score ?? .min
        #expect(contiguous > scattered)
    }

    @Test("Word-boundary initials rank above characters buried mid-word")
    func boundaryWins() {
        let initials = FuzzyMatcher.match("dt", in: "Design Tokens")?.score ?? .min
        let buried = FuzzyMatcher.match("dt", in: "addendum-to")?.score ?? .min
        #expect(initials > buried)
    }

    @Test("Spaces in the query are ignored, so 'gi hu' still finds github")
    func queryWhitespaceIsIgnored() {
        #expect(FuzzyMatcher.match("gi hu", in: "github.com") != nil)
    }

    @Test("A candidate shorter than the query cannot match")
    func shortCandidate() {
        #expect(FuzzyMatcher.match("abcdef", in: "abc") == nil)
    }
}
