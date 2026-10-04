import Foundation
import Testing

@testable import ZenticKit

@Suite struct DriftTests {
    static let article = ["header": 1, "nav": 1, "main": 1, "article": 1, "aside": 1, "footer": 1, "h1": 1]
    static let frontPage = ["header": 1, "nav": 1, "main": 1, "article": 24, "aside": 0, "footer": 1, "h1": 0]

    static func check(
        _ matches: [String: Int], visible: Int = 6_000, total: Int = 10_000, overflows: Bool = false,
        landmarks: [String: Int] = article
    ) -> PageCheck {
        PageCheck(matches: matches, visibleText: visible, totalText: total, overflowsX: overflows, landmarks: landmarks)
    }

    static let hide = [".rail", ".promo", ".comments", ".never"]
    static let baseline = CustomBaseline(check([".rail": 1, ".promo": 3, ".comments": 1, ".never": 0]))

    func tracker() -> DriftTracker { DriftTracker(hide: Self.hide, baseline: Self.baseline) }

    @Test func aVersionThatStillMatchesHasNotDrifted() {
        var t = tracker()
        #expect(t.record(Self.check([".rail": 1, ".promo": 2, ".comments": 1]), path: "/a") == nil)
    }

    @Test func missingOnTheSameKindOfPageIsLostAtOnce() {
        var t = tracker()
        let drift = t.record(Self.check([".rail": 0, ".promo": 0, ".comments": 1]), path: "/b")
        #expect(drift?.lost == [".rail", ".promo"])
        // A selector that found nothing even when kept is never held against the version.
        #expect(drift?.changes == 3)
        #expect(drift?.reasons.first == "2 of 3 changes no longer match this site’s layout")
    }

    @Test func aDifferentKindOfPageIsNotEvidenceUntilSeveralAgree() {
        var t = tracker()
        let empty = Self.check([:], landmarks: Self.frontPage)
        // The front page has no rail: on its own, that says nothing.
        #expect(t.record(empty, path: "/") == nil)
        // Reloading the same page is not new evidence.
        #expect(t.record(empty, path: "/") == nil)
        #expect(t.record(empty, path: "/news") == nil)
        // Three distinct pages without it — after a redesign every page looks like this.
        #expect(t.record(empty, path: "/sport")?.lost == [".rail", ".promo", ".comments"])
    }

    @Test func findingASelectorAnywhereClearsIt() {
        var t = tracker()
        let empty = Self.check([:], landmarks: Self.frontPage)
        _ = t.record(empty, path: "/")
        _ = t.record(empty, path: "/news")
        // An article page has them all: the misses were the front pages' shape, not drift.
        #expect(t.record(Self.check([".rail": 1, ".promo": 1, ".comments": 1]), path: "/story") == nil)
        #expect(t.record(empty, path: "/sport") == nil)

        // And a lost selector recovers when the site brings it back.
        _ = t.record(Self.check([".rail": 0, ".promo": 1, ".comments": 1]), path: "/x")
        #expect(t.record(Self.check([".rail": 1, ".promo": 1, ".comments": 1]), path: "/y") == nil)
    }

    @Test func aSharpDropInVisibleTextIsDrift() {
        var t = tracker()
        let all = [".rail": 1, ".promo": 1, ".comments": 1]
        // 60% visible when kept; 40% is ordinary variation between pages.
        #expect(t.record(Self.check(all, visible: 4_000), path: "/a") == nil)
        let drift = t.record(Self.check(all, visible: 2_000), path: "/b")
        #expect(drift?.hiddenText == .init(kept: 0.6, now: 0.2))
        #expect(drift?.problem.contains("only 20% of the page's text is visible, against 60%") == true)
    }

    @Test func aSparsePageIsNotJudgedByShare() {
        var t = tracker()
        #expect(t.record(Self.check([".rail": 1, ".promo": 1, ".comments": 1], visible: 10, total: 300), path: "/") == nil)
    }

    @Test func newSidewaysScrollingIsDriftButOldIsNot() {
        var t = tracker()
        let all = [".rail": 1, ".promo": 1, ".comments": 1]
        #expect(t.record(Self.check(all, overflows: true), path: "/")?.scrollsSideways == true)

        let overflowing = CustomBaseline(Self.check(all, overflows: true))
        var tolerant = DriftTracker(hide: Self.hide, baseline: overflowing)
        #expect(tolerant.record(Self.check(all, overflows: true), path: "/") == nil)
    }

    @Test func pageKindToleratesLengthButNotShape() {
        let longer = Self.article.merging(["aside": 3], uniquingKeysWith: { $1 })
        #expect(Self.baseline.isSameKind(as: Self.article))
        // One sidebar or three: still an article. One article or twenty-four: not.
        #expect(!Self.baseline.isSameKind(as: Self.frontPage))
        #expect(Self.baseline.isSameKind(as: longer))
        #expect(Self.baseline.isSameKind(as: Self.article.merging(["nav": 0], uniquingKeysWith: { $1 })) == false)
    }

    @Test func anErrorPageIsNeverAdoptedAsABaseline() {
        // A version kept before baselines existed is measured on its next
        // visit — but not off a 404, which would mark every selector as
        // matching nothing and so never judge any of them again.
        #expect(!Self.check([".rail": 0], visible: 30, total: 40).canBeBaseline(for: [".rail"]))
        #expect(!Self.check([".rail": 0]).canBeBaseline(for: [".rail", ".promo"]))
        #expect(Self.check([".rail": 0, ".promo": 2]).canBeBaseline(for: [".rail", ".promo"]))
        #expect(Self.check([:]).canBeBaseline(for: []))
    }

    @Test func readsWhatThePageScriptReturns() {
        let raw: [String: Any] = [
            "matches": [".rail": NSNumber(value: 2)], "visibleText": NSNumber(value: 10),
            "totalText": NSNumber(value: 20), "overflowsX": NSNumber(value: true),
            "landmarks": ["main": NSNumber(value: 1)],
        ]
        let check = PageCheck(script: raw)
        #expect(check?.matches == [".rail": 2])
        #expect(check?.overflowsX == true)
        #expect(check?.landmarks == ["main": 1])
        #expect(PageCheck(script: NSNull()) == nil)
        #expect(PageCheck(script: ["visibleText": "lots"]) == nil)
    }
}

@Suite struct CustomVersionDecodingTests {
    @Test func aVersionStoredBeforeBaselinesStillDecodes() throws {
        // sites.json as written before re-checking existed.
        let json = """
            {"defaultMode":"clean","sites":{"example.com":{"mode":"custom","custom":{
              "base":"minimal","css":"body{color:red}","hide":[".ad"],"summary":"Red.",
              "prompts":["red"],"updatedAt":750000000}}}}
            """
        let book = try JSONDecoder().decode(SiteBook.self, from: Data(json.utf8))
        let version = try #require(book.custom(for: "example.com"))
        #expect(version.hide == [".ad"])
        #expect(version.baseline == nil)
        #expect(book.mode(for: "example.com") == .custom)
    }

    @Test func aBaselineRoundTrips() throws {
        let baseline = CustomBaseline(DriftTests.check([".ad": 2]))
        let version = CustomVersion(
            base: .clean, css: "", hide: [".ad"], summary: "s", prompts: [], baseline: baseline)
        let decoded = try JSONDecoder().decode(CustomVersion.self, from: JSONEncoder().encode(version))
        #expect(decoded.baseline == baseline)
        #expect(decoded == version)
    }

    @Test func measuringAVersionIsNotChangingIt() {
        // Otherwise recording a baseline re-applies the site in every tab,
        // dropping a preview someone is looking at in another.
        let version = CustomVersion(base: .clean, css: "a{}", hide: [".ad"], summary: "s", prompts: [])
        var measured = version
        measured.baseline = CustomBaseline(DriftTests.check([".ad": 1]))
        #expect(CustomVersion.sameDesign(version, measured))
        #expect(CustomVersion.sameDesign(nil, nil))
        #expect(!CustomVersion.sameDesign(version, nil))
        var restyled = measured
        restyled.css = "b{}"
        #expect(!CustomVersion.sameDesign(measured, restyled))
    }

    @Test func aBaselineThatNoLongerDecodesCostsTheBaselineNotTheVersion() throws {
        let json = """
            {"base":"clean","css":"","hide":[".ad"],"summary":"s","prompts":[],"updatedAt":0,
             "baseline":{"matches":"garbled"}}
            """
        let version = try JSONDecoder().decode(CustomVersion.self, from: Data(json.utf8))
        #expect(version.hide == [".ad"])
        #expect(version.baseline == nil)
    }
}

@Suite struct RepairPromptTests {
    @Test func aRepairCarriesTheVersionAndWhatBrokeButNotAPreviewFailure() {
        let current = CustomVersion(base: .clean, css: ".x{color:red}", hide: [".rail"], summary: "", prompts: ["no rail"])
        let drift = Drift(lost: [".rail"], changes: 1)
        let prompt = OpenAIDesigner.userPrompt(
            .init(
                url: URL(string: "https://a.com")!, title: "A", outline: "o", instruction: "Repair it",
                current: current, screenshot: "data:image/jpeg;base64,AA", drift: drift.problem))
        #expect(prompt.contains(".x{color:red}"))
        #expect(prompt.contains("no rail"))
        #expect(prompt.contains("no longer match anything on the page: .rail"))
        // A kept version that drifted is not a preview that broke the page.
        #expect(!prompt.contains("Previewing that stylesheet broke the page"))
    }
}
