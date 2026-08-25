import Foundation
import Testing

@testable import ZenticKit

/// Deterministic lens values. Dates are pinned to ``Sample/timestamp`` so the
/// golden files are stable.
///
/// Kept apart from ``Sample`` because these are the *only* values the fixtures
/// under `Tests/Fixtures/wire/lens-*` and `command-*Lens*` are generated from —
/// changing one changes a file the TypeScript suite reads, which is the point.
enum LensSample {
    /// Carries a fingerprint, because the fallback resolution path is only worth
    /// having if both languages can read one. A fixture without it would leave the
    /// whole type unasserted on the TypeScript side.
    static let region = LensRegion(
        id: "related",
        intent: "the suggested videos sidebar",
        selectors: ["#secondary", "ytd-watch-next-secondary-results-renderer"],
        fingerprint: RegionFingerprint(
            tag: "ytd-watch-next-secondary-results-renderer",
            elementID: "secondary",
            classes: ["style-scope"],
            attributeNames: ["data-testid", "aria-label"],
            role: "complementary",
            childCount: 20,
            textLengthBand: 13,
            rectBand: RegionRectBand(x: 9, y: 6, width: 8, height: 10),
            siblingIndex: 1,
            ancestorTags: ["div", "ytd-watch-flexy", "ytd-page-manager", "ytd-app", "body"]
        )
    )

    static let feedRegion = LensRegion(
        id: "feed",
        intent: "the main video grid",
        selectors: ["ytd-rich-grid-renderer"]
    )

    static let hideOp = LensOp(
        id: "op-hide",
        kind: .hide,
        region: "related",
        note: "hide the suggestions"
    )

    static let keepOp = LensOp(
        id: "op-keep",
        kind: .keep,
        region: "feed",
        note: "keep only the grid"
    )

    static let filterOp = LensOp(
        id: "op-filter",
        kind: .filter,
        region: "feed",
        note: "drop shorts and live streams",
        predicate: ItemPredicate(
            terms: ["shorts", "live now"],
            matchMode: .any,
            field: .text,
            minChars: 4
        ),
        filterMode: .drop,
        itemSelector: "ytd-rich-item-renderer",
        limit: 200
    )

    /// The `href` half of the predicate vocabulary, with every numeric bound set.
    ///
    /// Not decoration: `minLinks`, `maxLinks` and `maxChars` appeared in no
    /// fixture at all, so a rename on either side of the bridge would have gone
    /// through both suites untouched.
    static let linkFilterOp = LensOp(
        id: "op-filter-links",
        kind: .filter,
        region: "feed",
        note: "keep only real videos",
        predicate: ItemPredicate(
            terms: ["/watch", "/shorts"],
            matchMode: .all,
            field: .href,
            minLinks: 1,
            maxLinks: 12,
            minChars: 8,
            maxChars: 400
        ),
        filterMode: .keep,
        itemSelector: "ytd-rich-item-renderer"
    )

    static let ariaFilterOp = LensOp(
        id: "op-filter-aria",
        kind: .filter,
        region: "related",
        note: "drop anything labelled sponsored",
        predicate: ItemPredicate(
            terms: ["sponsored"],
            matchMode: .none,
            field: .ariaLabel
        ),
        filterMode: .keep,
        itemSelector: "ytd-compact-video-renderer"
    )

    static let reorderOp = LensOp(
        id: "op-reorder",
        kind: .reorder,
        region: "feed",
        note: "longest titles last",
        sort: SortSpec(key: .textLength, ascending: false),
        itemSelector: "ytd-rich-item-renderer"
    )

    static let reorderByLinksOp = LensOp(
        id: "op-reorder-links",
        kind: .reorder,
        region: "related",
        note: "least linked first",
        sort: SortSpec(key: .linkCount, ascending: true),
        itemSelector: "ytd-compact-video-renderer"
    )

    static let insertOp = LensOp(
        id: "op-insert",
        kind: .insert,
        region: "feed",
        note: "show the titles at the top of the rail",
        target: "related",
        index: 0,
        // Names the bucket `harvestOp` fills. Without this field `insert` could
        // not be written down at all.
        bucket: "videos",
        limit: 10
    )

    static let restyleOp = LensOp(
        id: "op-restyle",
        kind: .restyle,
        region: "feed",
        note: "two calm columns",
        style: RegionStyle(
            background: "#101014",
            foreground: "#f2f2f2",
            fontScale: 1.1,
            maxWidthPx: 1_100,
            paddingPx: 24,
            radiusPx: 12,
            columns: 2,
            hideImages: false
        )
    )

    static let harvestOp = LensOp(
        id: "op-harvest",
        kind: .harvest,
        region: "feed",
        note: "collect the titles",
        sort: SortSpec(key: .harvestedField, field: "title", ascending: true),
        harvest: HarvestSpec(
            itemSelector: "ytd-rich-item-renderer",
            fields: [
                HarvestField(name: "title", selector: "#video-title", attribute: .text),
                HarvestField(name: "link", selector: "a", attribute: .href),
            ],
            into: "videos"
        )
    )

    static let moveOp = LensOp(
        id: "op-move",
        kind: .move,
        region: "related",
        note: "move the rail under the player",
        target: "feed",
        index: 0
    )

    static let widthOp = LensOp(
        id: "op-width",
        kind: .width,
        region: "feed",
        note: "narrow the grid",
        fraction: 0.7
    )

    static let labelOp = LensOp(
        id: "op-label",
        kind: .label,
        region: "feed",
        note: "mark it",
        text: "Subscriptions only"
    )

    static let report = LensReport(
        lensID: "lens-1",
        url: "https://www.youtube.com/watch",
        results: [
            LensOpResult(
                opID: "op-hide",
                status: .applied,
                matchedCount: 1,
                usedSelector: "#secondary"
            ),
            LensOpResult(
                opID: "op-filter",
                status: .missed,
                matchedCount: 0,
                message: "no candidate matched"
            ),
            // `skipped` is a budget and nothing else now that lenses do not
            // arbitrate between each other, so the fixture carries the sentence
            // the runner actually writes.
            LensOpResult(
                opID: "op-restyle",
                status: .skipped,
                matchedCount: 0,
                message: "op pass exceeded 120ms"
            ),
            // `ambiguous` and `failed` were in the enum and in no fixture, so
            // neither side of the bridge was ever asked to read one.
            LensOpResult(
                opID: "op-reorder",
                status: .ambiguous,
                matchedCount: 3,
                usedSelector: "ytd-rich-grid-renderer",
                message: "3 elements matched; applied to the first"
            ),
            LensOpResult(
                opID: "op-move",
                status: .failed,
                matchedCount: 1,
                usedSelector: "#secondary",
                message: "destination is inside the moved region"
            ),
        ],
        generatedAt: Sample.timestamp
    )

    static let lens = Lens(
        id: "lens-1",
        name: "Focus",
        origin: "www.youtube.com",
        pathPattern: "/watch",
        isEnabled: true,
        prompt: "no suggestions, no shorts",
        regions: [region, feedRegion],
        ops: [
            hideOp, keepOp, filterOp, linkFilterOp, ariaFilterOp, restyleOp, harvestOp,
            reorderOp, reorderByLinksOp, moveOp, widthOp, labelOp, insertOp,
        ],
        createdAt: Sample.timestamp,
        updatedAt: Sample.timestamp,
        lastReport: report
    )

    static let catalog = RegionCatalog(
        origin: "www.youtube.com",
        pathPattern: "/watch",
        viewport: .init(width: 1280, height: 900),
        candidates: [
            RegionCandidate(
                id: "r0",
                selector: "#secondary",
                alternates: ["ytd-watch-next-secondary-results-renderer"],
                tag: "div",
                elementID: "secondary",
                classes: ["style-scope"],
                role: "complementary",
                kindGuess: "aside",
                rect: RegionRect(x: 1_000, y: 80, width: 402, height: 1_800),
                depth: 7,
                textLength: 9_400,
                linkCount: 84,
                paragraphCount: 0,
                imageCount: 20,
                itemCount: 20,
                itemSelector: "ytd-compact-video-renderer"
            ),
            RegionCandidate(
                id: "r1",
                selector: "ytd-rich-grid-renderer",
                tag: "ytd-rich-grid-renderer",
                classes: ["style-scope"],
                kindGuess: "feed",
                rect: RegionRect(x: 0, y: 80, width: 980, height: 4_200),
                depth: 6,
                textLength: 21_000,
                linkCount: 180,
                paragraphCount: 0,
                imageCount: 60,
                itemCount: 60,
                itemSelector: "ytd-rich-item-renderer",
                // The fields inside one card, which is the only reason a model can
                // author a `harvest` at all. Note `#video-title` and `a` below:
                // `harvestOp` names exactly these, so the fixture demonstrates the
                // path rather than just carrying the type.
                itemFields: [
                    ItemFieldCandidate(
                        selector: "#video-title",
                        tag: "yt-formatted-string",
                        attributesPresent: ["title", "aria-label"],
                        textLength: 62
                    ),
                    ItemFieldCandidate(
                        selector: "a",
                        tag: "a",
                        attributesPresent: ["href"],
                        textLength: 62
                    ),
                    ItemFieldCandidate(
                        selector: "img",
                        tag: "img",
                        attributesPresent: ["src", "alt"],
                        textLength: 0
                    ),
                ]
            ),
        ]
    )

    static let proposal = LensProposal(
        regions: [region, feedRegion],
        ops: [hideOp, filterOp],
        note: "Hides the suggestions rail and drops Shorts from the grid."
    )

    static let promptRequest = LensPromptRequest(
        text: "get rid of the suggestions",
        selectedRegionIDs: ["r0"],
        catalog: catalog
    )

    /// A bootstrap carrying a lens, so the fixture the bundle reads has something
    /// in `lenses` to read.
    static var configuration: ReaderConfiguration {
        ReaderConfiguration(
            mode: .original,
            theme: Sample.theme,
            passthroughOrigins: ["https://www.youtube.com"],
            lenses: [lens]
        )
    }
}

@Suite("Lens wire contract")
struct LensContractTests {

    // MARK: Golden fixtures shared with the TypeScript bundle

    @Test func applyLensesCommandMatchesGolden() throws {
        try GoldenFixture.assertMatches(
            ReaderCommand.applyLenses([LensSample.lens]),
            named: "command-applyLenses"
        )
    }

    @Test func enterLensModeCommandMatchesGolden() throws {
        try GoldenFixture.assertMatches(
            ReaderCommand.enterLensMode(nil),
            named: "command-enterLensMode"
        )
    }

    /// The editing half of the same command, as its own fixture.
    ///
    /// Authoring and editing are one command carrying two different meanings, and
    /// the difference is one optional key. A fixture for only the empty case would
    /// leave the key that decides whether Save replaces a lens or duplicates it
    /// unasserted in both languages.
    @Test func editLensCommandMatchesGolden() throws {
        try GoldenFixture.assertMatches(
            ReaderCommand.enterLensMode(LensEditRequest(editing: "lens-focus")),
            named: "command-enterLensMode-editing"
        )
    }

    @Test func exitLensModeCommandMatchesGolden() throws {
        try GoldenFixture.assertMatches(
            ReaderCommand.exitLensMode,
            named: "command-exitLensMode"
        )
    }

    @Test func proposeOpsCommandMatchesGolden() throws {
        try GoldenFixture.assertMatches(
            ReaderCommand.proposeOps(LensSample.proposal),
            named: "command-proposeOps"
        )
    }

    @Test func requestRegionsCommandMatchesGolden() throws {
        try GoldenFixture.assertMatches(
            ReaderCommand.requestRegions,
            named: "command-requestRegions"
        )
    }

    @Test func lensReportEventMatchesGolden() throws {
        try GoldenFixture.assertMatches(
            ReaderEvent.lensReport([LensSample.report]),
            named: "event-lensReport"
        )
    }

    @Test func lensRegionsEventMatchesGolden() throws {
        try GoldenFixture.assertMatches(
            ReaderEvent.lensRegions(LensSample.catalog),
            named: "event-lensRegions"
        )
    }

    @Test func lensPromptEventMatchesGolden() throws {
        try GoldenFixture.assertMatches(
            ReaderEvent.lensPrompt(LensSample.promptRequest),
            named: "event-lensPrompt"
        )
    }

    @Test func lensDraftEventMatchesGolden() throws {
        try GoldenFixture.assertMatches(
            ReaderEvent.lensDraft(LensSample.lens),
            named: "event-lensDraft"
        )
    }

    @Test func lensModeChangedEventMatchesGolden() throws {
        try GoldenFixture.assertMatches(
            ReaderEvent.lensModeChanged(true),
            named: "event-lensModeChanged"
        )
    }

    /// Exports the op vocabulary so the bundle's runner can assert it handles
    /// every kind.
    ///
    /// Same reasoning as `section-kinds`: the switch over op kinds exists in
    /// both languages, and a kind added on one side but not the other is a
    /// silent no-op on a user's page rather than a compile error.
    @Test func lensOpKindsMatchGolden() throws {
        try GoldenFixture.assertMatches(
            ["kinds": LensOpKind.allCases.map(\.rawValue)],
            named: "lens-op-kinds"
        )
    }

    /// Exports the engine's budgets, because they stopped travelling on the wire.
    ///
    /// They used to arrive in seven `ReaderConfiguration` fields, which was two
    /// copies of one compile-time constant shipped over a bridge to reach the
    /// value the receiver already held — so the fields went, and `index.ts` keeps
    /// its own copy as `DEFAULT_ENGINE_OPTIONS`. What went with them was the only
    /// thing comparing the two. A divergence now is silent and asymmetric: the
    /// page would run a pass ceiling, an item cap and a candidate limit that
    /// `Budget` does not name, and nothing anywhere would say so.
    ///
    /// So the numbers are a fixture instead of a payload. Written here, read by
    /// `web/test/lens/engine.test.ts`, and costing no bytes on any page.
    @Test func lensBudgetsMatchGolden() throws {
        try GoldenFixture.assertMatches(
            [
                "lensOpPassCeilingMs": Int(Budget.lensOpPassCeiling.milliseconds),
                "lensMaxItemsPerPass": Budget.lensMaxItemsPerPass,
                "lensMaxOpsPerLens": Budget.lensMaxOpsPerLens,
                "lensObserverDebounceMs": Int(Budget.lensObserverDebounce.milliseconds),
                "lensObserverMaxPassesPerSecond": Budget.lensObserverMaxPassesPerSecond,
                "lensRegionCandidateLimit": Budget.lensRegionCandidateLimit,
                "lensMaxLensesPerOrigin": Budget.lensMaxLensesPerOrigin,
            ],
            named: "lens-budgets"
        )
    }

    // MARK: Round trips

    @Test(
        "Every lens event survives a round trip",
        arguments: [
            ReaderEvent.lensReport([LensSample.report]),
            ReaderEvent.lensRegions(LensSample.catalog),
            ReaderEvent.lensPrompt(LensSample.promptRequest),
            ReaderEvent.lensDraft(LensSample.lens),
            ReaderEvent.lensModeChanged(false),
        ]
    )
    func lensEventRoundTrip(event: ReaderEvent) throws {
        let data = try ZenticCoding.makeEncoder().encode(event)
        let decoded = try ZenticCoding.makeDecoder().decode(ReaderEvent.self, from: data)
        #expect(decoded == event)
    }

    @Test(
        "Every lens command survives a round trip",
        arguments: [
            ReaderCommand.applyLenses([LensSample.lens]),
            ReaderCommand.applyLenses([]),
            ReaderCommand.enterLensMode(nil),
            ReaderCommand.enterLensMode(LensEditRequest(editing: "lens-1")),
            ReaderCommand.exitLensMode,
            ReaderCommand.proposeOps(LensSample.proposal),
            ReaderCommand.requestRegions,
        ]
    )
    func lensCommandRoundTrip(command: ReaderCommand) throws {
        let data = try ZenticCoding.makeEncoder().encode(command)
        let decoded = try ZenticCoding.makeDecoder().decode(ReaderCommand.self, from: data)
        #expect(decoded == command)
    }

    /// Every op kind, with the field its kind is defined by, through the coder.
    ///
    /// The flat-struct shape means an op is mostly optionals, and
    /// `encodeIfPresent` drops the ones that are nil. A field that failed to
    /// round-trip would show up as an op that silently lost its `fraction` or
    /// its `predicate` — applied, reported applied, doing nothing.
    @Test(
        "Every op kind keeps its defining field across the wire",
        arguments: [
            LensSample.hideOp,
            LensSample.keepOp,
            LensSample.widthOp,
            LensSample.moveOp,
            LensSample.restyleOp,
            LensSample.reorderOp,
            LensSample.reorderByLinksOp,
            LensSample.filterOp,
            LensSample.linkFilterOp,
            LensSample.ariaFilterOp,
            LensSample.labelOp,
            LensSample.harvestOp,
            LensSample.insertOp,
        ]
    )
    func opRoundTrip(op: LensOp) throws {
        let data = try ZenticCoding.makeEncoder().encode(op)
        let decoded = try ZenticCoding.makeDecoder().decode(LensOp.self, from: data)
        #expect(decoded == op)
    }

    @Test("A nil op field is absent, not null, so the bundle's `??` works")
    func nilOpFieldsAreOmitted() throws {
        let data = try ZenticCoding.makeEncoder().encode(LensSample.hideOp)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["kind"] as? String == "hide")
        // Every optional, not a sample of them: the four that used to be missing
        // from this list are exactly the ones the runner reads with `??`, so a
        // `null` reaching `applyFilter` or `applyInsert` would be read as a value.
        for absent in [
            "target", "index", "fraction", "text", "style", "sort", "predicate",
            "filterMode", "harvest", "itemSelector", "bucket", "limit",
        ] {
            #expect(object[absent] == nil, "\(absent) should be omitted when nil")
        }
    }

    /// Fails if an optional is added to ``LensOp`` and left out of the list above.
    ///
    /// The list is a hand-maintained mirror of the type, and the failure mode of
    /// a hand-maintained mirror is that it stops being one. Encoding an op with
    /// *every* field set says what the full key set is, so a new field shows up
    /// here rather than in a `??` on somebody's page.
    @Test("Every op field is accounted for by the omission test")
    func opFieldSetIsKnown() throws {
        let data = try ZenticCoding.makeEncoder().encode(LensSample.insertOp)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let required: Set<String> = ["id", "kind", "region", "note"]
        let optional: Set<String> = [
            "target", "index", "fraction", "text", "style", "sort", "predicate",
            "filterMode", "harvest", "itemSelector", "bucket", "limit",
        ]

        #expect(Set(object.keys).isSubset(of: required.union(optional)))
        #expect(Mirror(reflecting: LensSample.insertOp).children.count == required.count + optional.count)
    }

    @Test("Lens dates cross the wire as ISO-8601")
    func lensDatesAreISO8601() throws {
        let data = try ZenticCoding.makeEncoder().encode(LensSample.lens)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("2025-07-31T") || json.contains("2025-08-01T"))
        #expect(!json.contains("1754000000"))
    }

    @Test("Report counters are derived, so they never disagree with the results")
    func reportCountersAreDerived() throws {
        let report = LensSample.report
        #expect(report.totalCount == 5)
        #expect(report.appliedCount == 1)
        #expect(report.missedCount == 1)
        // `ambiguous` and `failed` are neither applied nor missed. A badge that
        // counted them either way would read `3/5` on a lens that fits perfectly
        // or `5/5` on one that threw.
        #expect(report.isDrifted)

        // Derived, not encoded: a stored counter could survive an edit to
        // `results` and then lie to the toolbar badge.
        let data = try ZenticCoding.makeEncoder().encode(report)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["appliedCount"] == nil)
        #expect(object["missedCount"] == nil)
    }

    @Test("Bootstrap configuration carries lenses, and no longer their budgets")
    func configurationCarriesLenses() throws {
        let data = try ZenticCoding.makeEncoder().encode(LensSample.configuration)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Lenses have to be present at document-start or `hide` ops flash.
        let lenses = try #require(object["lenses"] as? [[String: Any]])
        #expect(lenses.count == 1)

        // Seven compile-time constants used to be serialised here so the bundle
        // could fall back, per field, to the identical constants it already held.
        // Asserting their absence is what stops the next person adding an eighth:
        // a budget on this wire is a budget with two owners.
        for budget in [
            "lensOpPassCeilingMs", "lensObserverDebounceMs", "lensObserverMaxPassesPerSecond",
            "lensMaxItemsPerPass", "lensMaxOpsPerLens", "lensMaxLensesPerOrigin",
            "lensRegionCandidateLimit",
        ] {
            #expect(object[budget] == nil, "\(budget) is a Budget constant, not wire state")
        }
    }

    /// The fields the harvest story depends on, through the coder.
    ///
    /// `harvest` was unauthorable on every site probed because the model was shown
    /// an item selector and nothing inside an item — so it had to invent
    /// `HarvestField.selector`, against a prompt that says invented selectors are
    /// discarded. This is the field that fixed it, and a rename that dropped it
    /// silently would put the feature straight back where it was.
    @Test("A catalog offers the insides of one repeated item")
    func catalogCarriesItemFields() throws {
        let data = try ZenticCoding.makeEncoder().encode(LensSample.catalog)
        let decoded = try ZenticCoding.makeDecoder().decode(RegionCatalog.self, from: data)
        let feed = try #require(decoded.candidates.first { $0.itemCount == 60 })

        #expect(feed.itemFields.count == 3)
        #expect(feed.itemFields.first?.selector == "#video-title")
        #expect(feed.itemFields.first?.attributesPresent == ["title", "aria-label"])
        #expect(feed.itemFields.first?.textLength == 62)

        // The point of the field: every selector a harvest names came from here.
        let offered = Set(feed.itemFields.map(\.selector))
        let named = LensSample.harvestOp.harvest?.fields.map(\.selector) ?? []
        #expect(!named.isEmpty)
        for selector in named {
            #expect(offered.contains(selector), "\(selector) was never offered to the model")
        }
    }

    @Test("A region's fingerprint survives the wire")
    func regionFingerprintRoundTrips() throws {
        let data = try ZenticCoding.makeEncoder().encode(LensSample.lens)
        let decoded = try ZenticCoding.makeDecoder().decode(Lens.self, from: data)
        let fingerprint = try #require(decoded.regions.first?.fingerprint)

        #expect(fingerprint.tag == "ytd-watch-next-secondary-results-renderer")
        #expect(fingerprint.role == "complementary")
        #expect(fingerprint.attributeNames == ["data-testid", "aria-label"])
        #expect(fingerprint.rectBand.width == 8)
        #expect(fingerprint.ancestorTags.count == 5)

        // Optional, so every lens written before fingerprinting still decodes
        // rather than being discarded as incompatible.
        #expect(decoded.regions.last?.fingerprint == nil)
    }

    @Test("A lens no longer carries a stacking order")
    func lensHasNoOrderField() throws {
        // The whole conflict apparatus — an explicit `order`, drag-to-reorder, a
        // string conflict pass, `skipped` as an override outcome — answered a
        // question the cascade answers. If `order` comes back, the popover's list
        // starts meaning something again and the answer has two owners.
        let data = try ZenticCoding.makeEncoder().encode(LensSample.lens)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["order"] == nil)
        let declared = Mirror(reflecting: LensSample.lens).children.compactMap(\.label)
        #expect(!declared.contains("order"))
    }

    /// A bootstrap that actually carries a lens.
    ///
    /// `configuration.json` is generated with an empty `lenses` array, so the
    /// bundle's contract test could only ever prove the *key* survives. This one
    /// proves the shape inside it does — which is the half that decides whether
    /// the stylesheet compiler has anything to compile at document-start.
    @Test func configurationWithLensesMatchesGolden() throws {
        try GoldenFixture.assertMatches(
            LensSample.configuration,
            named: "configuration-lenses"
        )
    }

    @Test(
        "A superseded wire version is rejected, not read as best it can be",
        arguments: [1, 2]
    )
    func rejectsSupersededWireVersion(version: Int) throws {
        // v2 is the format that still had `Lens.order` and seven lens budgets in
        // the bootstrap. A stale bundle is the realistic case — it is a resource
        // injected at document-start, and an app upgrade does not reach into a
        // page that is already open — so this is the version gate doing the job it
        // exists for rather than a hypothetical.
        let json = #"{"v":\#(version),"type":"requestRegions"}"#
        #expect(throws: ReaderBridgeError.self) {
            try ZenticCoding.makeDecoder().decode(ReaderCommand.self, from: Data(json.utf8))
        }
    }

    /// The untrusted direction, which had no version test at all.
    ///
    /// App→page is code we wrote talking to code we wrote. Page→app is a message
    /// arriving from a content world that a compromised bundle, a stale injected
    /// script after an upgrade, or a page that found a way in could all be
    /// speaking into. The version gate is the first thing it meets, so it needs a
    /// test more than the other direction does, not less.
    @Test("A superseded event from the page is rejected", arguments: [1, 2])
    func rejectsSupersededEventVersion(version: Int) throws {
        let json = #"{"v":\#(version),"type":"lensModeChanged","payload":true}"#
        #expect(throws: ReaderBridgeError.self) {
            try ZenticCoding.makeDecoder().decode(ReaderEvent.self, from: Data(json.utf8))
        }
    }

    @Test("An unknown wire tag is a clean decoding error, never a trap")
    func unknownTagDecodesCleanly() throws {
        // What a *newer* bundle talking to an older app looks like. It has to
        // land as a throw the bridge can log and drop; a crash here would take
        // the browser down over a message it was always free to ignore.
        let command = #"{"v":3,"type":"summonDemon","payload":{}}"#
        #expect(throws: DecodingError.self) {
            try ZenticCoding.makeDecoder().decode(ReaderCommand.self, from: Data(command.utf8))
        }

        let event = #"{"v":3,"type":"lensTelepathy","payload":{}}"#
        #expect(throws: DecodingError.self) {
            try ZenticCoding.makeDecoder().decode(ReaderEvent.self, from: Data(event.utf8))
        }
    }
}
