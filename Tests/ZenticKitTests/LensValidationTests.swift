import Foundation
import Testing

@testable import ZenticKit

/// Validation is the trust boundary between a model's output and a stylesheet
/// injected into a page the user visits every day.
///
/// So these tests are written as attacks rather than as coverage. Each one is a
/// thing a model could plausibly emit — because it hallucinated, because it was
/// steered by text on the page, or because someone hand-edited `Lenses.json` —
/// and each asserts the specific thing that must not survive.
@Suite("Lens validation")
struct LensValidationTests {

    /// The regions every hostile proposal below is checked against.
    static let regions = [
        LensRegion(id: "feed", intent: "the grid", selectors: ["ytd-rich-grid-renderer"]),
        LensRegion(id: "rail", intent: "the sidebar", selectors: ["#secondary"]),
    ]

    static let catalog = RegionCatalog(
        origin: "www.youtube.com",
        pathPattern: "/watch",
        viewport: .init(width: 1280, height: 900),
        candidates: [
            RegionCandidate(
                id: "r0",
                selector: "ytd-rich-grid-renderer",
                tag: "ytd-rich-grid-renderer",
                kindGuess: "feed",
                rect: RegionRect(x: 0, y: 0, width: 980, height: 4_000),
                depth: 6,
                textLength: 21_000,
                linkCount: 180,
                paragraphCount: 0,
                imageCount: 60,
                itemCount: 60,
                itemSelector: "ytd-rich-item-renderer"
            ),
            RegionCandidate(
                id: "r1",
                selector: "#secondary",
                tag: "div",
                elementID: "secondary",
                kindGuess: "aside",
                rect: RegionRect(x: 1_000, y: 0, width: 400, height: 1_800),
                depth: 7,
                textLength: 9_400,
                linkCount: 84,
                paragraphCount: 0,
                imageCount: 20,
                itemCount: 20,
                itemSelector: "ytd-compact-video-renderer"
            ),
        ]
    )

    /// The catalog as the gate actually sees it.
    ///
    /// Derived once here for the same reason validation derives it once: a test
    /// that built its own set from a raw catalog would be measuring against a
    /// different page from the one the code measures against, which is exactly
    /// the drift the shared pass exists to prevent.
    static let known = catalog.validated().knownSelectors

    static func proposal(_ ops: [LensOp], regions: [LensRegion] = regions) -> LensProposal {
        LensProposal(regions: regions, ops: ops, note: "n")
    }

    // MARK: Unknown regions

    @Test("An op naming a region the lens never declared is dropped")
    func unknownRegionIsDropped() {
        let result = Self.proposal([
            LensOp(id: "a", kind: .hide, region: "feed", note: "hide the grid"),
            LensOp(id: "b", kind: .hide, region: "comments", note: "hide comments"),
        ]).validated(against: Self.catalog)

        #expect(result.ops.map(\.id) == ["a"])
    }

    @Test("A move to an unknown destination is dropped, not silently retargeted")
    func unknownTargetIsDropped() {
        // Falling back to "move it somewhere" would rearrange the page in a way
        // the user never previewed.
        let result = Self.proposal([
            LensOp(id: "a", kind: .move, region: "rail", note: "move it", target: "nowhere")
        ]).validated(against: Self.catalog)

        #expect(result.ops.isEmpty)
    }

    @Test("A region whose selectors are all unknown takes its ops with it")
    func regionWithNoValidSelectorsIsDropped() {
        let invented = LensRegion(id: "ads", intent: "ads", selectors: [".sponsored-block"])
        let result = Self.proposal(
            [LensOp(id: "a", kind: .hide, region: "ads", note: "hide ads")],
            regions: Self.regions + [invented]
        ).validated(against: Self.catalog)

        #expect(result.regions.map(\.id) == ["feed", "rail"])
        #expect(result.ops.isEmpty)
    }

    // MARK: Colours — invariant 5

    @Test(
        "A colour that is not exactly #rrggbb never reaches a stylesheet",
        arguments: [
            "#fff",
            "red",
            "rgb(255,0,0)",
            "#ffffff url(https://evil.example/pixel.png)",
            "#ffffff; background-image: url(https://evil.example/p.png)",
            "#ffffff /* */ ; behavior: expression(alert(1))",
            "@import url(https://evil.example/x.css)",
            "#gggggg",
            "#ffffff\n",
            "",
        ]
    )
    func hostileColourIsRejected(value: String) {
        let style = RegionStyle(background: value, foreground: value).validated()

        // Rejected to nil, not repaired to a fallback: a lens is an overlay, so
        // leaving the site's own colour alone is the correct repair.
        #expect(style.background == nil, "\(value) survived as a background")
        #expect(style.foreground == nil, "\(value) survived as a foreground")
    }

    @Test("A well-formed colour survives, normalised to lowercase")
    func validColourSurvives() {
        let style = RegionStyle(background: "#AABBCC").validated()
        #expect(style.background == "#aabbcc")
    }

    @Test("A restyle left with nothing to apply is dropped")
    func emptyRestyleIsDropped() {
        // Every field was hostile, so validation emptied the style. An op that
        // would still report itself `applied` while doing nothing is worse than
        // no op — it hides real drift behind a green badge.
        let result = Self.proposal([
            LensOp(
                id: "a",
                kind: .restyle,
                region: "feed",
                note: "recolour",
                style: RegionStyle(background: "url(https://evil.example/p.png)")
            )
        ]).validated(against: Self.catalog)

        #expect(result.ops.isEmpty)
    }

    // MARK: Numeric ranges

    @Test("Out-of-range style numbers are clamped, not rejected")
    func styleNumericClamping() {
        let style = RegionStyle(
            fontScale: 40,
            maxWidthPx: 100_000,
            paddingPx: -50,
            radiusPx: 9_999,
            columns: 400
        ).validated()

        #expect(style.fontScale == 2.0)
        #expect(style.maxWidthPx == 4_000)
        #expect(style.paddingPx == 0)
        #expect(style.radiusPx == 64)
        #expect(style.columns == 4)
    }

    @Test("A tiny style number is clamped up to its floor")
    func styleNumericFloor() {
        let style = RegionStyle(fontScale: 0.01, maxWidthPx: 1, columns: 0).validated()
        #expect(style.fontScale == 0.5)
        #expect(style.maxWidthPx == 200)
        #expect(style.columns == 1)
    }

    @Test("Op numerics are clamped into the ranges the runner assumes")
    func opNumericClamping() throws {
        let op = try #require(
            LensOp(
                id: "a",
                kind: .width,
                region: "feed",
                note: "narrow",
                index: -99,
                fraction: 12,
                limit: 10_000_000
            ).validated(regions: ["feed"], knownSelectors: Self.known)
        )

        #expect(op.fraction == 1.0)
        #expect(op.index == 0)
        #expect(op.limit == Budget.lensMaxItemsPerPass)
    }

    @Test("A width op with no fraction is dropped rather than defaulted")
    func widthWithoutFractionIsDropped() {
        let op = LensOp(id: "a", kind: .width, region: "feed", note: "narrow")
        #expect(op.validated(regions: ["feed"], knownSelectors: nil) == nil)
    }

    // MARK: Predicates

    @Test("A ten-thousand-term predicate is capped at the term limit")
    func predicateTermFlood() throws {
        let flood = (0..<10_000).map { "term\($0)" }
        let op = try #require(
            LensOp(
                id: "a",
                kind: .filter,
                region: "feed",
                note: "drop",
                predicate: ItemPredicate(terms: flood, matchMode: .any, field: .text),
                filterMode: .drop,
                itemSelector: "ytd-rich-item-renderer"
            ).validated(regions: ["feed"], knownSelectors: Self.known)
        )

        #expect(op.predicate?.terms.count == ItemPredicate.maxTerms)
        #expect(op.predicate?.terms.first == "term0")
    }

    @Test("An over-long term is dropped, never truncated")
    func overLongTermIsDropped() {
        // Truncating widens a substring match, so a `drop` filter would start
        // deleting items the user never named.
        let predicate = ItemPredicate(
            terms: ["shorts", String(repeating: "a", count: 500), "  ", "live"]
        ).validated()

        #expect(predicate.terms == ["shorts", "live"])
    }

    @Test("A filter left with no way to tell items apart is dropped")
    func vacuousPredicateDropsTheOp() {
        // An empty term list under `.none` matches every item, so a `drop`
        // filter carrying one would empty the feed on every visit.
        let result = Self.proposal([
            LensOp(
                id: "a",
                kind: .filter,
                region: "feed",
                note: "drop everything",
                predicate: ItemPredicate(terms: [""], matchMode: .none, field: .text),
                filterMode: .drop,
                itemSelector: "ytd-rich-item-renderer"
            )
        ]).validated(against: Self.catalog)

        #expect(result.ops.isEmpty)
    }

    @Test("An unsatisfiable range is repaired rather than honoured")
    func invertedBoundsAreSwapped() {
        let predicate = ItemPredicate(
            terms: ["x"],
            minLinks: 90,
            maxLinks: 2,
            minChars: 5_000,
            maxChars: 10
        ).validated()

        #expect(predicate.minLinks == 2)
        #expect(predicate.maxLinks == 90)
        #expect(predicate.minChars == 10)
        #expect(predicate.maxChars == 5_000)
    }

    @Test("Predicate bounds are clamped to plausible page values")
    func predicateBoundsClamped() {
        let predicate = ItemPredicate(
            terms: ["x"],
            minLinks: -5,
            maxLinks: 999_999,
            minChars: -1,
            maxChars: 10_000_000
        ).validated()

        #expect(predicate.minLinks == 0)
        #expect(predicate.maxLinks == ItemPredicate.linkBounds.upperBound)
        #expect(predicate.minChars == 0)
        #expect(predicate.maxChars == ItemPredicate.charBounds.upperBound)
    }

    @Test("A filter with no mode is dropped rather than guessed")
    func filterWithoutModeIsDropped() {
        let op = LensOp(
            id: "a",
            kind: .filter,
            region: "feed",
            note: "drop",
            predicate: ItemPredicate(terms: ["shorts"]),
            itemSelector: "ytd-rich-item-renderer"
        )
        #expect(op.validated(regions: ["feed"], knownSelectors: Self.known) == nil)
    }

    // MARK: Selectors

    @Test(
        "A selector that could escape its CSS rule is rejected",
        arguments: [
            "div}body{background:url(https://evil.example/p.png)}",
            "div;background:red",
            "div/*}*/",
            "div\\7b",
            "div</style><script>fetch('https://evil.example')</script>",
            "@import url(https://evil.example/x.css)",
            "div[style*=expression(alert(1))]",
            "div\u{0000}",
            "",
            "   ",
            // Unbalanced. `#secondary:has(` compiles to `#secondary:has( {…}`,
            // and per CSS Syntax §5.4.8 the unclosed block then swallows every
            // rule after it to the end of the sheet — so every later CSS op does
            // nothing while the structural pass still reports it `applied`.
            "#secondary:has(",
            "div[a=\"",
            "div:not(.a",
            "#a)",
            "div[data-x",
            "div]",
            ".card:has(> .ad",
            // A unicode escape reconstructing a banned token past a literal
            // substring search: `\75 rl(` is `url(`.
            "\\75 rl(https://evil.example/p.png)",
            "div\\",
            // An at-rule is not a selector.
            "@media print",
            // A selector list used to be rejected here. It is a *breadth* problem
            // rather than an escaping one — A2.0 — so it moved to
            // `unboundedRegionSelectorIsRejected`, and a harvest field selector
            // reading `h3, .title` inside one card is legitimate.
        ]
    )
    func hostileSelectorIsRejected(value: String) {
        #expect(LensToken.selector(value) == nil, "\(value) survived selector validation")
    }

    @Test(
        "A selector that plainly names the whole page is not a region",
        arguments: [
            "*", "html", "body", ":root", ":scope", "BODY", "  body  ",
            // A selector list smuggles a second, broader subject into a rule
            // authored for the first — the reason `,` is a region-only ban, and
            // that ban is a string check rather than a parse.
            ":is(main, body)",
            "#feed, body",
            "a, b",
        ]
    )
    func unboundedRegionSelectorIsRejected(value: String) {
        // `hide` on `html` is otherwise a perfectly legal lens that blanks every
        // visit to a site — §1's no-flash rule inverted into a permanent one. And
        // `keep` is worse: `keepRule(":is(body)")` synthesises
        // `:has(> :is(body)) > *:not(:is(body))`, which matches `<html>` and hides
        // everything the page has.
        #expect(LensToken.regionSelector(value) == nil, "\(value) survived as a region")
    }

    @Test(
        "A page root in disguise is stopped by the catalog, not by a parser",
        arguments: [
            ":is(body)",
            ":where(body)",
            ":is(html)",
            "*:not(.keep)",
            "body *:not(script)",
            "body.dark",
            "body:not(#nope)",
            "html.js",
            "html[lang]",
            "body > *",
            "#feed *",
            "*:has(.ad)",
            ":not(.keep)",
            ":is(*)",
        ]
    )
    func disguisedPageRootIsStoppedByTheCatalogGate(value: String) {
        // Every one of these compiles to `{display:none!important}` on an element
        // containing the whole page, and a shape check spelled
        // `pageRoots.contains(subject)` sees none of them. There used to be a
        // 230-line CSS parser here that did: it found the subject compound and
        // asked whether anything in it *narrowed*.
        //
        // That parser had exactly one caller who needed it: a lens file validated
        // against no catalog at all. That caller is gone, so the gate that answers
        // this is the one that was always stronger: a region
        // selector must be one the live page actually offered, and no page offers
        // `:is(body)` as an anchor for a box.
        //
        // Asserted through the whole-proposal path rather than through
        // `regionSelector`, because that is where the gate now lives — testing the
        // shape check alone would assert the hole rather than the defence.
        let region = LensRegion(id: "feed", intent: "everything", selectors: [value])
        let ops = [LensOp(id: "a", kind: .hide, region: "feed", note: "hide it")]
        let result = LensProposal(regions: [region], ops: ops, note: "n")
            .validated(against: Self.catalog)

        #expect(result.regions.isEmpty, "\(value) survived as a region")
        #expect(result.ops.isEmpty, "\(value) kept an op alive")
    }

    @Test(
        "A subject narrowed by an id, class, attribute or tag is still a region",
        arguments: [
            "article",
            "#secondary",
            ".sidebar",
            "[data-testid=rail]",
            "body > article.post",
            "body>div:nth-of-type(2)>article",
            ":scope > li",
            // `:is()` resolving to something narrow is narrow: this is the half a
            // blanket ban on `:is` would have broken.
            ":is(.card)",
            "#feed:has(> .ad)",
            "div[data-x=\"a>b\"]",
        ]
    )
    func narrowRegionSelectorSurvives(value: String) {
        // The breadth check has to be structural in both directions. A validator
        // that rejects ordinary markup is one whoever hits it next will loosen,
        // and the loosening is what put the literal set here in the first place.
        #expect(LensToken.regionSelector(value) == value, "\(value) was rejected as a region")
    }

    @Test("The breadth limit is a region rule, not a selector rule")
    func breadthLimitDoesNotApplyToItems() {
        // Item and field selectors are matched inside one element, so `:scope` is
        // the narrowest subject there is rather than the broadest. Banning it
        // everywhere would silently disable every filter, reorder and harvest.
        #expect(LensToken.selector(":scope") == ":scope")
        #expect(LensToken.selector(":scope > li") == ":scope > li")
        #expect(LensToken.regionSelector(":scope > li") == ":scope > li")
    }

    @Test("A comma is banned in a region, allowed in a field selector")
    func commaIsARegionRule() {
        // A2.0 puts the comma in the region-only ban with the rest of the breadth
        // rules, and it was left in the shared list instead. A region is one
        // thing, so a list there smuggles a second subject into a rule authored
        // for the first — but a harvest field is read with `querySelector` inside
        // one item, where `h3, .title` is just "whichever of these this card
        // uses", which is exactly how a real feed is marked up.
        #expect(LensToken.regionSelector("#feed, body") == nil)
        #expect(LensToken.selector("h3, .title") == "h3, .title")

        // An *item* selector is a third case, and it keeps the ban for a reason
        // that has nothing to do with breadth: when `ops.ts` cannot parse one it
        // falls back to the region's own element children, so a list would turn
        // "drop the cards matching X" into "drop everything directly inside this
        // region" the moment the two shape gates disagreed about commas.
        #expect(LensToken.pageSelector("li, article", knownSelectors: nil) == nil)
        #expect(LensToken.pageSelector(":scope > li", knownSelectors: nil) == ":scope > li")
    }

    @Test("An escaped paren cannot walk `expression(` past the check")
    func expressionBanSeesThroughAnEscape() {
        // A1.4 narrowed the `expression` ban from a substring to a function call,
        // and `expression\(` steps around the narrowed form: the regex wants a
        // literal `(` next, `escapesAreLiteral` is happy with `\(`, and
        // `isBalanced` skips the escaped character entirely. CSS reads that as a
        // literal paren rather than a call, so it is not exploitable in selector
        // position — but a check one backslash walks past is a check nobody can
        // reason about, and it was the exact check the review asked to tighten.
        #expect(LensToken.selector("div[style*=expression\\(x\\)]") == nil)
        #expect(LensToken.selector(".expression\\(1\\)") == nil)
        // And the legitimate class the narrowing was for is still addressable.
        #expect(LensToken.selector(".expression-editor") == ".expression-editor")
    }

    @Test("A selector longer than any real one is rejected")
    func absurdSelectorIsRejected() {
        #expect(LensToken.selector(String(repeating: ".a", count: 500)) == nil)
    }

    @Test("Ordinary descendant selectors survive, child combinator included")
    func validSelectorSurvives() {
        #expect(LensToken.regionSelector("body>div:nth-of-type(2)>article") != nil)
        #expect(LensToken.regionSelector("  #secondary  ") == "#secondary")
        #expect(LensToken.regionSelector("ytd-rich-grid-renderer") != nil)
    }

    @Test(
        "An escaped utility class survives — half the modern web is written in them",
        arguments: [
            ".md\\:flex",
            ".w-1\\/2",
            ".text-\\[13px\\]",
            "div.lg\\:grid-cols-2 > .p-4",
            ".\\!mt-0",
        ]
    )
    func escapedClassSelectorSurvives(value: String) {
        // Banning `\` outright rejected every one of these, which would have made
        // Tailwind sites — exactly the sites people want to lens — unaddressable.
        #expect(LensToken.regionSelector(value) == value, "\(value) was rejected")
    }

    @Test("`expression` is banned as a function call, not as a substring")
    func expressionBanIsNarrow() {
        // The raw substring ban rejected `.expression-editor`, an ordinary class
        // on an ordinary page. A validator that fails on legitimate markup is one
        // that gets loosened by whoever hits it next.
        #expect(LensToken.regionSelector(".expression-editor") == ".expression-editor")
        #expect(LensToken.regionSelector("#expressions") == "#expressions")
        #expect(LensToken.selector("div[style*=expression (alert(1))]") == nil)
    }

    @Test("A quoted attribute value may contain a bracket without unbalancing it")
    func quotedBracketsAreBalanced() {
        #expect(LensToken.regionSelector("div[data-x=\"a(b\"]") != nil)
        #expect(LensToken.regionSelector("div[data-x='a]b']") != nil)
    }

    @Test("A selector the page never offered is rejected even when it parses")
    func selectorAbsentFromCatalogIsRejected() {
        let invented = LensRegion(
            id: "feed",
            intent: "the grid",
            // Well-formed, plausible, and not in the catalog: exactly what a
            // model produces when it pattern-matches on a site it half-knows.
            selectors: [".feed-container", "ytd-rich-grid-renderer"]
        )
        let result = LensProposal(regions: [invented], ops: [], note: "n")
            .validated(against: Self.catalog)

        #expect(result.regions.first?.selectors == ["ytd-rich-grid-renderer"])
    }

    @Test("An item selector the page never offered takes the whole op with it")
    func itemSelectorAbsentFromCatalogDropsTheOp() {
        // It used to be nulled while the op survived, and that was the sharpest
        // edge in the whole validator: `itemRun` falls back to the region's own
        // element children when no item selector is given, so "drop the cards
        // matching X" silently became "drop whatever the runner decides an item
        // is". On a feed, that empties the feed.
        let op = LensOp(
            id: "a",
            kind: .filter,
            region: "feed",
            note: "drop shorts",
            predicate: ItemPredicate(terms: ["shorts"]),
            filterMode: .drop,
            itemSelector: ".invented-item"
        )
        #expect(op.validated(regions: ["feed"], knownSelectors: Self.known) == nil)

        // Same rule for a kind that does not even use the field: a supplied
        // selector that fails the gate is a lens that does not mean what it says.
        let hide = LensOp(
            id: "b",
            kind: .hide,
            region: "feed",
            note: "hide",
            itemSelector: ".invented-item"
        )
        #expect(hide.validated(regions: ["feed"], knownSelectors: Self.known) == nil)
    }

    @Test("`reorder` and `filter` without an item selector are dropped")
    func itemOpsRequireAnItemSelector() {
        // These two ops are *defined* by the item they act on. Without it they
        // fall back to the region's element children, which is a different set
        // from the one the op was authored against — and for a `drop` filter the
        // difference is the whole feed.
        let filter = LensOp(
            id: "a",
            kind: .filter,
            region: "feed",
            note: "drop shorts",
            predicate: ItemPredicate(terms: ["shorts"]),
            filterMode: .drop
        )
        #expect(filter.validated(regions: ["feed"], knownSelectors: Self.known) == nil)

        let reorder = LensOp(
            id: "b",
            kind: .reorder,
            region: "feed",
            note: "shortest first",
            sort: SortSpec(key: .textLength, ascending: true)
        )
        #expect(reorder.validated(regions: ["feed"], knownSelectors: Self.known) == nil)
    }

    @Test("A `:scope >` item selector survives, because that is what the page offers")
    func scopedItemSelectorSurvives() throws {
        // `regions.ts` generates `:scope > <tag>` for a feed's rows and
        // `harvest.ts` reads a field from a bare `:scope`. The breadth limit is a
        // *region* rule; applying it here would disable every filter, reorder and
        // harvest ever written.
        let catalog = RegionCatalog(
            origin: "example.com",
            pathPattern: "/",
            viewport: .init(width: 1280, height: 900),
            candidates: [
                RegionCandidate(
                    id: "r0",
                    selector: "#feed",
                    tag: "div",
                    elementID: "feed",
                    kindGuess: "feed",
                    rect: RegionRect(x: 0, y: 0, width: 900, height: 4_000),
                    depth: 4,
                    textLength: 9_000,
                    linkCount: 40,
                    paragraphCount: 0,
                    imageCount: 10,
                    itemCount: 20,
                    itemSelector: ":scope > li"
                )
            ]
        )
        let regions = [LensRegion(id: "feed", intent: "the feed", selectors: ["#feed"])]
        let result = LensProposal(
            regions: regions,
            ops: [
                LensOp(
                    id: "a",
                    kind: .filter,
                    region: "feed",
                    note: "drop ads",
                    predicate: ItemPredicate(terms: ["sponsored"]),
                    filterMode: .drop,
                    itemSelector: ":scope > li"
                )
            ],
            note: "n"
        ).validated(against: catalog)

        #expect(result.ops.first?.itemSelector == ":scope > li")
        #expect(catalog.validated().candidates.first?.itemSelector == ":scope > li")
    }

    @Test("A harvest field may read the item itself with a bare `:scope`")
    func bareScopeFieldSelectorSurvives() throws {
        let op = try #require(
            LensOp(
                id: "a",
                kind: .harvest,
                region: "feed",
                note: "collect",
                harvest: HarvestSpec(
                    itemSelector: "ytd-rich-item-renderer",
                    fields: [HarvestField(name: "text", selector: ":scope", attribute: .text)],
                    into: "videos"
                )
            ).validated(regions: ["feed"], knownSelectors: Self.known)
        )

        #expect(op.harvest?.fields.first?.selector == ":scope")
    }

    @Test("Without a catalog the shape gate still applies")
    func shapeGateAppliesWithoutCatalog() {
        let region = LensRegion(
            id: "feed",
            intent: "the grid",
            selectors: ["div}body{color:red}", ".anything-goes"]
        )
        let result = LensProposal(regions: [region], ops: [], note: "n").validated(against: nil)

        // The catalog gate is off, so `.anything-goes` is allowed — but the
        // rule-escaping selector is not, because that check never depends on a
        // catalog being available.
        #expect(result.regions.first?.selectors == [".anything-goes"])
    }

    // MARK: Harvest

    @Test("A harvest of an attribute outside the closed set does not decode")
    func harvestAttributeIsClosed() throws {
        // `attribute` is an enum now, so the check has moved from validation to
        // the decoder — which is why the hostile input has to arrive as JSON.
        // `data-session` is the shape that matters: a site's private payload,
        // not something it ever rendered.
        let json = """
            {"name":"leak","selector":"*","attribute":"data-session"}
            """
        #expect(throws: DecodingError.self) {
            try ZenticCoding.makeDecoder().decode(HarvestField.self, from: Data(json.utf8))
        }

        // And the whole op goes with it, rather than arriving with one field
        // quietly missing — a decode is all-or-nothing.
        let lens = """
            {"itemSelector":"li","into":"x",
             "fields":[{"name":"leak","selector":"*","attribute":"data-session"}]}
            """
        #expect(throws: DecodingError.self) {
            try ZenticCoding.makeDecoder().decode(HarvestSpec.self, from: Data(lens.utf8))
        }
    }

    @Test("The schema a model is shown lists exactly the attributes that decode")
    func harvestAttributeSchemaMatchesTheEnum() {
        // Two spellings of one set is how a model ends up being told about an
        // attribute the decoder will reject, which surfaces as a proposal that
        // fails for no reason anybody can see.
        #expect(Set(HarvestField.allowedAttributes) == Set(HarvestAttribute.allCases.map(\.rawValue)))
    }

    @Test("A harvest with no usable field is dropped, taking its op with it")
    func harvestWithoutFieldsDropsTheOp() {
        let result = Self.proposal([
            LensOp(
                id: "a",
                kind: .harvest,
                region: "feed",
                note: "collect",
                harvest: HarvestSpec(
                    itemSelector: "ytd-rich-item-renderer",
                    fields: [HarvestField(name: "x", selector: "a{}", attribute: .href)],
                    into: "videos"
                )
            )
        ]).validated(against: Self.catalog)

        #expect(result.ops.isEmpty)
    }

    @Test("A harvested-field sort naming no field falls back to document order")
    func sortWithoutFieldFallsBack() throws {
        let op = try #require(
            LensOp(
                id: "a",
                kind: .reorder,
                region: "feed",
                note: "sort",
                sort: SortSpec(key: .harvestedField, field: nil, ascending: true),
                itemSelector: "ytd-rich-item-renderer"
            ).validated(regions: ["feed"], knownSelectors: Self.known)
        )

        #expect(op.sort?.key == .documentOrder)
    }

    // MARK: Budget caps

    @Test("An op list over the budget is truncated, not run")
    func opCountIsCappedAtBudget() {
        let flood = (0..<500).map {
            LensOp(id: "op\($0)", kind: .hide, region: "feed", note: "hide \($0)")
        }
        let result = Self.proposal(flood).validated(against: Self.catalog)

        // The op pass has a frame budget; an unbounded list would exhaust it on
        // every visit and report the tail as skipped forever.
        #expect(result.ops.count == Budget.lensMaxOpsPerLens)
        #expect(result.ops.first?.id == "op0")
    }

    @Test("A region list over the candidate limit is truncated")
    func regionCountIsCappedAtBudget() {
        let flood = (0..<400).map {
            LensRegion(id: "r\($0)", intent: "x", selectors: ["ytd-rich-grid-renderer"])
        }
        let result = LensProposal(regions: flood, ops: [], note: "n")
            .validated(against: Self.catalog)

        #expect(result.regions.count == LensProposal.maxRegions)
    }

    @Test("Duplicate region ids collapse to the first, so ops resolve one way")
    func duplicateRegionIDsCollapse() {
        let result = LensProposal(
            regions: [
                LensRegion(id: "feed", intent: "grid", selectors: ["ytd-rich-grid-renderer"]),
                LensRegion(id: "feed", intent: "rail", selectors: ["#secondary"]),
            ],
            ops: [],
            note: "n"
        ).validated(against: Self.catalog)

        #expect(result.regions.count == 1)
        #expect(result.regions.first?.selectors == ["ytd-rich-grid-renderer"])
    }

    // MARK: Text fields

    @Test("A note long enough to break the UI chip is truncated")
    func noteIsLengthCapped() throws {
        let op = try #require(
            LensOp(
                id: "a",
                kind: .hide,
                region: "feed",
                note: String(repeating: "x", count: 5_000)
            ).validated(regions: ["feed"], knownSelectors: Self.known)
        )

        #expect(op.note.count == LensOp.maxNoteLength)
    }

    @Test("Control characters are stripped from text that lands in the page")
    func labelTextIsSanitised() throws {
        let op = try #require(
            LensOp(
                id: "a",
                kind: .label,
                region: "feed",
                note: "label",
                text: "Sub\u{0000}scriptions\nonly"
            ).validated(regions: ["feed"], knownSelectors: Self.known)
        )

        #expect(op.text == "Subscriptionsonly")
    }

    @Test("A label whose text sanitises away is dropped")
    func emptyLabelIsDropped() {
        let op = LensOp(id: "a", kind: .label, region: "feed", note: "label", text: "\u{0000}\n")
        #expect(op.validated(regions: ["feed"], knownSelectors: Self.known) == nil)
    }

    // MARK: Cross-op references

    static func harvestOp(
        _ id: String = "h",
        into: String = "videos",
        field: String = "title"
    ) -> LensOp {
        LensOp(
            id: id,
            kind: .harvest,
            region: "feed",
            note: "collect",
            harvest: HarvestSpec(
                itemSelector: "ytd-rich-item-renderer",
                fields: [HarvestField(name: field, selector: "#video-title", attribute: .text)],
                into: into
            )
        )
    }

    @Test("An insert without both a destination and a bucket is dropped")
    func insertNeedsTargetAndBucket() {
        // Two halves of one instruction: `target` is where the block goes,
        // `bucket` is what goes in it. Either alone renders nothing, somewhere.
        let noBucket = LensOp(id: "a", kind: .insert, region: "feed", note: "i", target: "rail")
        #expect(noBucket.validated(regions: ["feed", "rail"], knownSelectors: Self.known) == nil)

        let noTarget = LensOp(id: "b", kind: .insert, region: "feed", note: "i", bucket: "videos")
        #expect(noTarget.validated(regions: ["feed", "rail"], knownSelectors: Self.known) == nil)
    }

    @Test("An insert naming a bucket no harvest fills is dropped")
    func insertBucketMustBeHarvested() {
        let result = Self.proposal([
            Self.harvestOp(into: "videos"),
            LensOp(id: "i", kind: .insert, region: "feed", note: "i", target: "rail", bucket: "news"),
        ]).validated(against: Self.catalog)

        // Nothing ever writes `news`, so this op is a `missed` on every visit for
        // a reason that has nothing to do with the site — drift the user cannot
        // fix and did not cause.
        #expect(result.ops.map(\.id) == ["h"])
    }

    @Test("An insert naming a bucket a harvest does fill survives")
    func insertBucketResolves() {
        let result = Self.proposal([
            Self.harvestOp(into: "videos"),
            LensOp(
                id: "i",
                kind: .insert,
                region: "feed",
                note: "i",
                target: "rail",
                bucket: "videos"
            ),
        ]).validated(against: Self.catalog)

        #expect(result.ops.map(\.id) == ["h", "i"])
    }

    @Test("Two harvests into one bucket collapse to the first")
    func harvestBucketsAreUniquePerLens() {
        // The second `put` replaces the first, so an `insert` would render
        // whichever harvest happened to run last rather than what was authored.
        let result = Self.proposal([
            Self.harvestOp("h1", into: "videos", field: "title"),
            Self.harvestOp("h2", into: "videos", field: "link"),
        ]).validated(against: Self.catalog)

        #expect(result.ops.map(\.id) == ["h1"])
    }

    @Test("A sort naming a field no harvest collects falls back to document order")
    func harvestedFieldSortMustBeProduced() throws {
        let result = Self.proposal([
            Self.harvestOp(into: "videos", field: "title"),
            LensOp(
                id: "r",
                kind: .reorder,
                region: "feed",
                note: "by date",
                sort: SortSpec(key: .harvestedField, field: "published", ascending: true),
                itemSelector: "ytd-rich-item-renderer"
            ),
        ]).validated(against: Self.catalog)

        // At run time `fieldOf(item, "published")` returns nothing for every item,
        // so every key is equal and the stable sort leaves document order. Saying
        // so is honest; leaving the name in place reports a sort that never ran.
        let reorder = try #require(result.ops.first { $0.id == "r" })
        #expect(reorder.sort?.key == .documentOrder)
        #expect(reorder.sort?.field == nil)

        // A field that *is* collected keeps its key.
        let kept = Self.proposal([
            Self.harvestOp(into: "videos", field: "title"),
            LensOp(
                id: "r",
                kind: .reorder,
                region: "feed",
                note: "by title",
                sort: SortSpec(key: .harvestedField, field: "title", ascending: true),
                itemSelector: "ytd-rich-item-renderer"
            ),
        ]).validated(against: Self.catalog)
        #expect(kept.ops.first { $0.id == "r" }?.sort?.key == .harvestedField)
    }

    // MARK: Moves

    @Test("A move into itself is dropped, not attempted")
    func moveToSelfIsDropped() {
        // `appendChild(self)` is a HierarchyRequestError at best and a subtree
        // detached from the document with the landmark still in it at worst.
        let op = LensOp(id: "a", kind: .move, region: "feed", note: "move", target: "feed")
        #expect(op.validated(regions: ["feed"], knownSelectors: Self.known) == nil)
    }

    @Test("A cycle of moves loses the op that closes it")
    func moveCycleIsBroken() {
        let result = Self.proposal([
            LensOp(id: "a", kind: .move, region: "feed", note: "feed into rail", target: "rail"),
            LensOp(id: "b", kind: .move, region: "rail", note: "rail into feed", target: "feed"),
        ]).validated(against: Self.catalog)

        // Running both takes *both* regions out of the page, and the second op is
        // the one that had no way to know the first had happened.
        #expect(result.ops.map(\.id) == ["a"])
    }

    // MARK: The lens as a whole

    static func lens(_ ops: [LensOp], regions: [LensRegion] = regions) -> Lens {
        Lens(
            id: "l",
            name: "Focus",
            origin: "www.youtube.com",
            pathPattern: "/watch",
            prompt: "no shorts",
            regions: regions,
            ops: ops,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("A lens goes through the same gate a proposal does")
    func lensValidationMatchesProposalValidation() throws {
        // The type that actually crosses into the page is `Lens`, not
        // `LensProposal`: it rides on `ReaderConfiguration.lenses`, which is
        // interpolated into the bootstrap script. Before this entry point existed,
        // a lens read off disk reached that script unchecked.
        let hostile = Self.lens([
            LensOp(id: "a", kind: .hide, region: "feed", note: "hide"),
            LensOp(id: "b", kind: .hide, region: "comments", note: "unknown region"),
            LensOp(
                id: "c",
                kind: .filter,
                region: "feed",
                note: "no item selector",
                predicate: ItemPredicate(terms: ["x"]),
                filterMode: .drop
            ),
        ])

        let validated = try #require(hostile.validated())
        #expect(validated.ops.map(\.id) == ["a"])
    }

    @Test("A lens carrying a rule-escaping selector loses the region and its ops")
    func lensRejectsHostileSelectors() {
        let lens = Self.lens(
            [LensOp(id: "a", kind: .hide, region: "feed", note: "hide")],
            regions: [
                LensRegion(
                    id: "feed",
                    intent: "the grid",
                    selectors: ["#feed{background:url(https://tracker.example/p)}"]
                )
            ]
        )

        #expect(lens.validated() == nil)
    }

    @Test("A lens from another schema version never validates")
    func lensSchemaIsGated() {
        var stale = Self.lens([LensOp(id: "a", kind: .hide, region: "feed", note: "hide")])
        stale.schemaVersion = Lens.currentSchemaVersion + 1
        #expect(stale.validated() == nil)
    }

    @Test("A lens whose origin could not have come from a URL is rejected")
    func lensOriginIsGated() {
        var odd = Self.lens([LensOp(id: "a", kind: .hide, region: "feed", note: "hide")])
        odd.origin = "www.youtube.com/watch?v=1"
        #expect(odd.validated() == nil)

        odd.origin = ""
        #expect(odd.validated() == nil)
    }

    @Test("A lens normalises its stored text and pattern")
    func lensNormalisesItsFields() throws {
        var messy = Self.lens([LensOp(id: "a", kind: .hide, region: "feed", note: "hide")])
        messy.name = String(repeating: "n", count: 500)
        messy.prompt = String(repeating: "p", count: 2_000)
        messy.pathPattern = "javascript:alert(1)"
        messy.origin = "WWW.YouTube.com"

        let validated = try #require(messy.validated())
        #expect(validated.name.count == LensStore.maxNameLength)
        #expect(validated.prompt.count == LensStore.maxPromptLength)
        // Site-wide is a thing the user can see in the list and switch off; a
        // malformed pattern is a lens that sits there and never fires.
        #expect(validated.pathPattern == "*")
        #expect(validated.origin == "www.youtube.com")
    }

    @Test("A lens with no name still has one, so its row can be identified")
    func lensWithoutANameGetsOne() throws {
        var anonymous = Self.lens([LensOp(id: "a", kind: .hide, region: "feed", note: "hide")])
        anonymous.name = "  \u{0000} "
        #expect(try #require(anonymous.validated()).name == "Lens")
    }

    @Test("An op id outside the identifier alphabet is dropped")
    func opIDsAreGated() {
        // Ids are echoed back in every `LensOpResult` and matched against the
        // stored op, exactly like a region id — so they get the same alphabet.
        let op = LensOp(id: "a\"><script>", kind: .hide, region: "feed", note: "hide")
        #expect(op.validated(regions: ["feed"], knownSelectors: Self.known) == nil)
    }

    @Test("Two ops sharing an id collapse to the first")
    func duplicateOpIDsCollapse() {
        // A report is keyed by op id: duplicates make the drift row ambiguous and
        // the re-fit button act on both.
        let result = Self.proposal([
            LensOp(id: "a", kind: .hide, region: "feed", note: "first"),
            LensOp(id: "a", kind: .hide, region: "rail", note: "second"),
        ]).validated(against: Self.catalog)

        #expect(result.ops.count == 1)
        #expect(result.ops.first?.region == "feed")
    }

    // MARK: Catalog

    @Test("A catalog longer than the candidate budget is truncated")
    func catalogCandidatesAreCapped() {
        // The budget is *defined* as a cap on these, and was being applied to a
        // proposal's regions instead — so nothing capped the thing it names.
        let flood = (0..<400).map { index in
            RegionCandidate(
                id: "r\(index)",
                selector: "#r\(index)",
                tag: "div",
                rect: RegionRect(x: 0, y: 0, width: 10, height: 10),
                depth: 3,
                textLength: 10,
                linkCount: 0,
                paragraphCount: 0,
                imageCount: 0,
                itemCount: 0
            )
        }
        let catalog = RegionCatalog(
            origin: "example.com",
            pathPattern: "/",
            viewport: .init(width: 1280, height: 900),
            candidates: flood
        ).validated()

        #expect(catalog.candidates.count == Budget.lensRegionCandidateLimit)
    }

    @Test("A catalog cannot authorise a selector that is not one")
    func catalogSelectorsAreGated() {
        // `knownSelectors` is the gate an op's selector is measured against, so a
        // malformed selector in the catalog would *authorise* itself: the model
        // is told the page offers `#secondary:has(`, and validation agrees.
        let catalog = RegionCatalog(
            origin: "example.com",
            pathPattern: "/",
            viewport: .init(width: 1280, height: 900),
            candidates: [
                RegionCandidate(
                    id: "r0",
                    selector: "#secondary:has(",
                    tag: "div",
                    rect: RegionRect(x: 0, y: 0, width: 10, height: 10),
                    depth: 3,
                    textLength: 10,
                    linkCount: 0,
                    paragraphCount: 0,
                    imageCount: 0,
                    itemCount: 0
                ),
                RegionCandidate(
                    id: "r1",
                    selector: "#feed",
                    alternates: ["body", ".grid"],
                    tag: "div",
                    rect: RegionRect(x: 0, y: 0, width: 10, height: 10),
                    depth: 3,
                    textLength: 10,
                    linkCount: 0,
                    paragraphCount: 0,
                    imageCount: 0,
                    itemCount: 0
                ),
            ]
        ).validated()

        #expect(catalog.candidates.map(\.id) == ["r1"])
        #expect(catalog.candidates.first?.alternates == [".grid"])
        #expect(!catalog.knownSelectors.contains("#secondary:has("))
    }

    /// A catalog with more candidates than the budget allows, each offering a
    /// region selector and an item selector of its own.
    static func crowdedCatalog() -> RegionCatalog {
        RegionCatalog(
            origin: "example.com",
            pathPattern: "/",
            viewport: .init(width: 1_280, height: 900),
            candidates: (0..<(Budget.lensRegionCandidateLimit + 5)).map { index in
                RegionCandidate(
                    id: "r\(index)",
                    selector: "#r\(index)",
                    tag: "div",
                    rect: RegionRect(x: 0, y: 0, width: 10, height: 10),
                    depth: 3,
                    textLength: 10,
                    linkCount: 0,
                    paragraphCount: 0,
                    imageCount: 0,
                    itemCount: 4,
                    itemSelector: "li.r\(index)"
                )
            }
        )
    }

    @Test("An item selector is measured against the same capped catalog a region is")
    func itemSelectorsUseTheCappedCatalog() {
        // Two gates read two different catalogs: regions were measured against
        // `catalog.validated().knownSelectors` and item selectors against the raw,
        // uncapped `catalog.knownSelectors`. So a candidate past
        // `lensRegionCandidateLimit` — one the model is never shown, and could
        // only have invented — was rejected as a region and accepted as the thing
        // a `drop` filter operates on. A2.11's "cap once" held inside
        // `OpenAIProvider` and nowhere else, and `LensController.generate`
        // re-validates against the raw page catalog.
        let beyond = "li.r\(Budget.lensRegionCandidateLimit + 1)"
        let result = LensProposal(
            regions: [LensRegion(id: "feed", intent: "the feed", selectors: ["#r0"])],
            ops: [
                LensOp(
                    id: "a",
                    kind: .filter,
                    region: "feed",
                    note: "drop ads",
                    predicate: ItemPredicate(terms: ["sponsored"]),
                    filterMode: .drop,
                    itemSelector: beyond
                )
            ],
            note: "n"
        ).validated(against: Self.crowdedCatalog())

        #expect(result.ops.isEmpty)

        // The same rule reached the other way: a harvest's own item selector.
        let harvest = LensProposal(
            regions: [LensRegion(id: "feed", intent: "the feed", selectors: ["#r0"])],
            ops: [
                LensOp(
                    id: "a",
                    kind: .harvest,
                    region: "feed",
                    note: "collect",
                    harvest: HarvestSpec(
                        itemSelector: beyond,
                        fields: [HarvestField(name: "title", selector: "h3", attribute: .text)],
                        into: "rows"
                    )
                )
            ],
            note: "n"
        ).validated(against: Self.crowdedCatalog())

        #expect(harvest.ops.isEmpty)
    }

    @Test("A catalog selector with stray whitespace still authorises the trimmed one")
    func catalogSelectorsAreNormalisedBeforeTheyAuthorise() throws {
        // `pageSelector` trims its input and then looked the trimmed form up in a
        // set built from raw strings, so a catalog offering `" li "` could never
        // authorise `li` — the page offered an item selector no op could use, and
        // the op was dropped as though the model had invented it.
        let catalog = RegionCatalog(
            origin: "example.com",
            pathPattern: "/",
            viewport: .init(width: 1_280, height: 900),
            candidates: [
                RegionCandidate(
                    id: "r0",
                    selector: "  #feed  ",
                    tag: "div",
                    elementID: "feed",
                    kindGuess: "feed",
                    rect: RegionRect(x: 0, y: 0, width: 900, height: 4_000),
                    depth: 4,
                    textLength: 9_000,
                    linkCount: 40,
                    paragraphCount: 0,
                    imageCount: 10,
                    itemCount: 20,
                    itemSelector: " li "
                )
            ]
        )

        #expect(catalog.knownSelectors.contains("li"))
        #expect(catalog.knownSelectors.contains("#feed"))

        let result = LensProposal(
            regions: [LensRegion(id: "feed", intent: "the feed", selectors: ["#feed"])],
            ops: [
                LensOp(
                    id: "a",
                    kind: .filter,
                    region: "feed",
                    note: "drop ads",
                    predicate: ItemPredicate(terms: ["sponsored"]),
                    filterMode: .drop,
                    itemSelector: "li"
                )
            ],
            note: "n"
        ).validated(against: catalog)

        #expect(result.ops.map(\.itemSelector) == ["li"])
    }

    // MARK: Item fields — what the model is shown inside one card

    /// One candidate carrying whatever the page felt like offering.
    private static func feedCandidate(itemFields: [ItemFieldCandidate]) -> RegionCandidate {
        RegionCandidate(
            id: "r0",
            selector: "#feed",
            tag: "div",
            elementID: "feed",
            kindGuess: "feed",
            rect: RegionRect(x: 0, y: 0, width: 900, height: 4_000),
            depth: 4,
            textLength: 9_000,
            linkCount: 40,
            paragraphCount: 0,
            imageCount: 10,
            itemCount: 20,
            itemSelector: ":scope > li",
            itemFields: itemFields
        )
    }

    private static func feedCatalog(itemFields: [ItemFieldCandidate]) -> RegionCatalog {
        RegionCatalog(
            origin: "example.com",
            pathPattern: "/",
            viewport: .init(width: 1280, height: 900),
            candidates: [feedCandidate(itemFields: itemFields)]
        )
    }

    @Test("A page offering more item fields than a harvest can collect is truncated")
    func itemFieldsAreCapped() {
        // Unbounded, this is a page with two thousand nodes inside one card writing
        // two thousand entries into every prompt the user ever sends about it.
        let fields = (0..<200).map {
            ItemFieldCandidate(
                selector: ".f\($0)",
                tag: "span",
                attributesPresent: [],
                textLength: 10
            )
        }
        let validated = Self.feedCatalog(itemFields: fields).validated()

        #expect(validated.candidates.first?.itemFields.count == RegionCandidate.maxItemFields)
        #expect(RegionCandidate.maxItemFields == HarvestSpec.maxFields)
    }

    @Test("An item field selector that could escape its rule never reaches the model")
    func itemFieldSelectorGoesThroughTheShapeGate() {
        // This is the field a model is *told* to copy a `HarvestField.selector`
        // from, and field selectors are deliberately not catalog-gated. So an
        // unchecked offer here is a selector the model would name in good faith
        // and validation would then have to catch on the way back — one gate too
        // late, and only if the second one is also right.
        let validated = Self.feedCatalog(
            itemFields: [
                ItemFieldCandidate(
                    selector: "h3}body{display:none}",
                    tag: "h3",
                    attributesPresent: [],
                    textLength: 40
                ),
                ItemFieldCandidate(
                    selector: ".byline",
                    tag: "span",
                    attributesPresent: [],
                    textLength: 12
                ),
            ]
        ).validated()

        #expect(validated.candidates.first?.itemFields.map(\.selector) == [".byline"])
    }

    @Test("Two offers of one field collapse, and attribute names are capped")
    func itemFieldsAreDeduplicatedAndBounded() {
        let validated = Self.feedCatalog(
            itemFields: [
                ItemFieldCandidate(
                    selector: "a",
                    tag: "A",
                    attributesPresent: (0..<40).map { "data-x\($0)" } + ["not an attribute"],
                    textLength: 9_999_999
                ),
                // The same selector described again is one field, not two: the
                // model would be choosing between identical options with prompt
                // budget that could have shown it a different field.
                ItemFieldCandidate(
                    selector: "a",
                    tag: "a",
                    attributesPresent: ["href"],
                    textLength: 20
                ),
            ]
        ).validated()

        let fields = validated.candidates.first?.itemFields ?? []
        #expect(fields.count == 1)
        #expect(fields.first?.tag == "a")
        #expect(fields.first?.attributesPresent.count == ItemFieldCandidate.maxAttributes)
        #expect(fields.first?.attributesPresent.contains("not an attribute") == false)
        #expect(fields.first?.textLength == ItemPredicate.charBounds.upperBound)
    }

    @Test("An item field selector does not authorise itself as a region")
    func itemFieldsDoNotWidenTheCatalogGate() {
        // `knownSelectors` is the gate for selectors resolved against the whole
        // document. An item field is resolved inside one card, so unioning `.title`
        // into that set would let a `hide` op name every title on the page as
        // though the catalog had offered it as a box.
        let catalog = Self.feedCatalog(
            itemFields: [
                ItemFieldCandidate(
                    selector: ".title",
                    tag: "h3",
                    attributesPresent: [],
                    textLength: 40
                )
            ]
        )
        #expect(!catalog.knownSelectors.contains(".title"))

        let result = LensProposal(
            regions: [LensRegion(id: "t", intent: "titles", selectors: [".title"])],
            ops: [LensOp(id: "a", kind: .hide, region: "t", note: "hide titles")],
            note: "n"
        ).validated(against: catalog)
        #expect(result.regions.isEmpty)
    }

    // MARK: Fingerprints

    @Test("A fingerprint from the page is capped and clamped, never rejected")
    func fingerprintIsBounded() throws {
        // Page-supplied, persisted to `Lenses.json`, re-read on every launch — the
        // same untrusted round trip a report makes, and the reason that one is
        // validated. Unbounded, one saved lens is a page writing as much as it
        // likes into a file this app reads at startup forever.
        let region = LensRegion(
            id: "feed",
            intent: "the grid",
            selectors: ["ytd-rich-grid-renderer"],
            fingerprint: RegionFingerprint(
                tag: "YTD-RICH-GRID-RENDERER",
                elementID: "contents",
                classes: (0..<200).map { "c\($0)" },
                attributeNames: (0..<200).map { "data-a\($0)" },
                role: "feed",
                childCount: 9_999_999,
                textLengthBand: 9_999,
                rectBand: RegionRectBand(x: -4, y: 6, width: 9_999, height: 8),
                siblingIndex: -1,
                ancestorTags: (0..<50).map { "t\($0)" }
            )
        )
        let validated = try #require(
            region.validated(knownSelectors: nil)?.fingerprint
        )

        // Lowercased so a fingerprint taken from `element.tagName` and one taken
        // from `localName` are the same fingerprint.
        #expect(validated.tag == "ytd-rich-grid-renderer")
        #expect(validated.classes.count == RegionFingerprint.maxClasses)
        #expect(validated.attributeNames.count == RegionFingerprint.maxAttributeNames)
        #expect(validated.ancestorTags.count == RegionFingerprint.maxAncestors)
        #expect(validated.childCount == RegionFingerprint.countBounds.upperBound)
        #expect(validated.siblingIndex == 0)
        #expect(validated.textLengthBand == RegionFingerprint.bandBounds.upperBound)
        #expect(validated.rectBand.x == 0)
        #expect(validated.rectBand.width == RegionFingerprint.bandBounds.upperBound)
        #expect(validated.role == "feed")
    }

    @Test("A fingerprint carrying prose in an attribute name loses it, not the region")
    func fingerprintKeepsIdentifiersOnly() throws {
        // The privacy rule enforced rather than merely documented: attribute
        // *names* are CSS identifiers, so anything that is not one could not have
        // come off an element and is the shape a smuggled `aria-label` *value*
        // would take. Dropping it beats rejecting the fingerprint — a signature
        // with one fewer signal still scores, and a region with none resolves by
        // selector alone, which is where it was before.
        let region = LensRegion(
            id: "feed",
            intent: "the grid",
            selectors: ["ytd-rich-grid-renderer"],
            fingerprint: RegionFingerprint(
                tag: "div",
                attributeNames: ["aria-label", "Sponsored — 3 min read", "data-testid"],
                role: "feed",
                childCount: 20,
                textLengthBand: 12,
                rectBand: RegionRectBand(x: 9, y: 6, width: 8, height: 10),
                siblingIndex: 0
            )
        )
        let validated = try #require(region.validated(knownSelectors: nil))

        #expect(validated.fingerprint?.attributeNames == ["aria-label", "data-testid"])
        #expect(validated.selectors == ["ytd-rich-grid-renderer"])
    }

    // MARK: Reports — the page's own account of what it did

    @Test("A report from the page is capped, stripped and gated like any other input")
    func reportIsValidated() throws {
        // `LensReport` was the one field in a `Lens` that crossed the trust
        // boundary with no gate at all: `Lens.validated()` skipped it and
        // `LensStore.recordReport` wrote it verbatim. A page posting fifty
        // thousand results with megabyte messages got them written into
        // `Lenses.json`, re-read on every launch, and rendered in the popover.
        let hostile = LensReport(
            lensID: "lens-1",
            url: "https://www.example.com/watch?v=1&token=secret#t=90",
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

        let safe = try #require(hostile.validated())
        #expect(safe.results.count == LensReport.maxResults)
        // Query and fragment left behind: this is written to a file that outlives
        // the session, and a query string is where the session tokens and the
        // search terms live.
        #expect(safe.url == "/watch")
        #expect(safe.results.first?.message?.count == LensOp.maxNoteLength)
        // A selector longer than any real one is not a selector, and it is
        // rendered in the drift row.
        #expect(safe.results.first?.usedSelector == nil)
        #expect(safe.results.first?.matchedCount == Budget.lensMaxItemsPerPass)
    }

    @Test("A report is gated on the ids it claims, exactly as an op is")
    func reportIDsAreGated() throws {
        let injected = LensReport(
            lensID: "l\"><script>",
            url: "/watch",
            results: [],
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(injected.validated() == nil)

        // A result naming an op id outside the alphabet is dropped rather than
        // taking the whole report with it: the other rows still describe the page.
        let mixed = LensReport(
            lensID: "lens-1",
            url: "/watch",
            results: [
                LensOpResult(opID: "op\"><script>", status: .applied),
                LensOpResult(opID: "op-hide", status: .missed, message: "no candidate matched"),
                // Two results for one op make the drift row ambiguous, the same
                // way two ops sharing an id do.
                LensOpResult(opID: "op-hide", status: .applied),
            ],
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let safe = try #require(mixed.validated())
        #expect(safe.results.map(\.opID) == ["op-hide"])
        #expect(safe.results.first?.status == .missed)
    }

    @Test("A lens carries only a report that could have been about itself")
    func lensReportIsValidatedWithTheLens() throws {
        var lens = Self.lens([LensOp(id: "a", kind: .hide, region: "feed", note: "hide")])
        lens.lastReport = LensReport(
            lensID: "l",
            url: "https://www.youtube.com/watch?v=1",
            results: [LensOpResult(opID: "a", status: .applied, matchedCount: 1)],
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(try #require(lens.validated()).lastReport?.url == "/watch")

        // A report naming another lens describes a page load this lens was not
        // part of, so its counts would badge the wrong row.
        lens.lastReport?.lensID = "someone-else"
        #expect(try #require(lens.validated()).lastReport == nil)
    }

    @Test("A lens id outside the identifier alphabet is rejected")
    func lensIDsAreGated() {
        // `LensOp.id` and `LensRegion.id` are both gated; the lens's own id is
        // what a draft from the page chooses, what the store matches on, and what
        // every report keys against.
        var injected = Self.lens([LensOp(id: "a", kind: .hide, region: "feed", note: "hide")])
        injected.id = "l\"><script>"
        #expect(injected.validated() == nil)
    }

    @Test("A region carrying a phone book of selectors is truncated")
    func regionSelectorCountIsCapped() throws {
        // 500 selectors × 40 ops is a ~5MB stylesheet, rebuilt on every SPA
        // navigation. Nothing capped this, so a lens off disk could make a site
        // unusable without a single selector failing a shape check.
        let flood = (0..<500).map { "#r\($0)" }
        let region = LensRegion(id: "feed", intent: "the feed", selectors: flood)
        let validated = try #require(region.validated(knownSelectors: nil))

        #expect(validated.selectors.count == LensRegion.maxSelectors)
        #expect(validated.selectors.first == "#r0")
    }

    // MARK: Numbers that are not numbers

    @Test("A non-finite number is rejected, never clamped")
    func nonFiniteNumbersAreRejected() {
        // `min`/`max` both return NaN, so the shared clamp passes it straight
        // through — and `NaN%` in a stylesheet is a rule the engine discards
        // while the report still says `applied`.
        let width = LensOp(
            id: "a",
            kind: .width,
            region: "feed",
            note: "narrow",
            fraction: .nan
        )
        #expect(width.validated(regions: ["feed"], knownSelectors: Self.known) == nil)

        let infinite = LensOp(
            id: "b",
            kind: .width,
            region: "feed",
            note: "narrow",
            fraction: .infinity
        )
        #expect(infinite.validated(regions: ["feed"], knownSelectors: Self.known) == nil)

        #expect(RegionStyle(fontScale: .nan).validated().fontScale == nil)
    }

    @Test("A move index has its own bound, unrelated to the items-per-pass budget")
    func moveIndexHasItsOwnBound() throws {
        let op = try #require(
            LensOp(
                id: "a",
                kind: .move,
                region: "rail",
                note: "move",
                target: "feed",
                index: 10_000_000
            ).validated(regions: ["feed", "rail"], knownSelectors: Self.known)
        )

        #expect(op.index == LensOp.indexBounds.upperBound)
    }

    // MARK: Prose

    @Test("Truncating prose is idempotent")
    func plainTextTruncationIsIdempotent() {
        // Trimming *before* truncating lets the cut reintroduce trailing
        // whitespace, so a second pass produces a different string — and
        // validation runs on the model's answer, on save, and again on load. A
        // stored lens would quietly stop being the one the user previewed.
        let input = String(repeating: "x", count: LensOp.maxNoteLength - 1) + " tail"
        let once = LensToken.plainText(input, limit: LensOp.maxNoteLength)
        let twice = LensToken.plainText(once, limit: LensOp.maxNoteLength)

        #expect(once == twice)
        #expect(once.last != " ")
        #expect(once.count == LensOp.maxNoteLength - 1)
    }

    @Test("Leading whitespace does not eat the prose behind it")
    func plainTextKeepsContentAfterLeadingSpace() {
        let padded = String(repeating: " ", count: 300) + "Subscriptions"
        #expect(LensToken.plainText(padded, limit: 240) == "Subscriptions")
    }

    // MARK: Idempotence

    @Test("Validation is idempotent")
    func idempotent() {
        // The disk path and the model path both validate. If a second pass
        // changed anything, a saved lens would drift away from what was
        // previewed.
        let hostile = Self.proposal([
            LensOp(
                id: "a",
                kind: .restyle,
                region: "feed",
                note: String(repeating: "x", count: 900),
                style: RegionStyle(background: "#AABBCC", fontScale: 40, columns: 99)
            ),
            LensOp(
                id: "b",
                kind: .filter,
                region: "feed",
                note: "drop",
                predicate: ItemPredicate(terms: (0..<200).map { "t\($0)" }, minChars: 90, maxChars: 2),
                filterMode: .drop,
                itemSelector: "ytd-rich-item-renderer"
            ),
        ])

        let once = hostile.validated(against: Self.catalog)
        #expect(once.validated(against: Self.catalog) == once)
    }
}
