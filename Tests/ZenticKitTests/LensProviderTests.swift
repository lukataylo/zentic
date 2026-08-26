import Foundation
import Testing

@testable import ZenticKit

/// The provider seam, tested without a network.
///
/// Two things can go wrong here and neither shows up as an error. A provider that
/// cannot author lenses might answer anyway and hand back something half-shaped;
/// and a provider that *can* might hand back ops naming regions the page does not
/// have, which apply to nothing and report as drift the user did not cause. So:
/// the declining default must actually decline, and the validation gate must
/// actually be crossed before a proposal is returned.
///
/// ## Why the stub calls the real thing
///
/// ``EchoProvider`` used to *re-implement* the decode → validate → re-id sequence,
/// which meant every assertion below was about the stub. Deleting
/// `.validated(against:)` from ``OpenAIProvider`` left the whole suite green while
/// a model's invented selectors went straight into a stylesheet. The sequence now
/// lives in ``OpenAIProvider/proposal(from:catalog:)`` and
/// ``OpenAIProvider/regions(from:catalog:requested:)``, and the stub calls those —
/// so what is tested here is the code the network path runs.
@Suite("Lens provider")
struct LensProviderTests {

    // MARK: Fixtures

    static let catalog = RegionCatalog(
        origin: "www.example.com",
        pathPattern: "/watch",
        viewport: .init(width: 1_280, height: 900),
        candidates: [
            RegionCandidate(
                id: "r0",
                selector: "#secondary",
                alternates: ["aside.rail"],
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
                itemSelector: "div.item"
            )
        ]
    )

    /// A response of exactly the shape ``OpenAIProvider/lensProposalSchema`` asks
    /// for, including the nulls a strict schema forces on absent fields — and
    /// including two things a model plausibly gets wrong: an op naming a region
    /// nobody declared, and a region built on a selector the page never offered.
    static let modelResponse = """
        {
          "note": "Hides the rail and the comments.",
          "regions": [
            {
              "id": "rail",
              "intent": "the suggested videos sidebar",
              "selectors": ["#secondary", "aside.rail"]
            },
            {
              "id": "invented",
              "intent": "a region that is not on this page",
              "selectors": ["#definitely-not-here"]
            }
          ],
          "ops": [
            {
              "id": "op1", "kind": "hide", "region": "rail",
              "note": "hide the suggestions", "target": null, "index": null,
              "fraction": null, "text": null, "style": null, "sort": null,
              "predicate": null, "filterMode": "drop", "harvest": null,
              "itemSelector": null, "limit": null
            },
            {
              "id": "op2", "kind": "hide", "region": "comments",
              "note": "hide the comments", "target": null, "index": null,
              "fraction": null, "text": null, "style": null, "sort": null,
              "predicate": null, "filterMode": "drop", "harvest": null,
              "itemSelector": null, "limit": null
            },
            {
              "id": "op3", "kind": "restyle", "region": "rail",
              "note": "tint it", "target": null, "index": null, "fraction": null,
              "text": null,
              "style": {
                "background": "#112233", "foreground": null, "fontScale": 9.5,
                "maxWidthPx": null, "paddingPx": null, "radiusPx": null,
                "columns": null, "hideImages": null
              },
              "sort": null, "predicate": null, "filterMode": "drop",
              "harvest": null, "itemSelector": null, "limit": null
            }
          ]
        }
        """

    // MARK: Declining

    @Test("A provider that does not author lenses declines instead of answering")
    func defaultImplementationDeclines() async throws {
        let provider = SilentProvider()
        let request = LensRequest(catalog: Self.catalog, prompt: "hide the sidebar")

        await #expect(
            throws: LLMError.providerFailed(
                identifier: "test.silent",
                message: """
                    Authoring a lens is a long, structured generation and past what \
                    this model does well — half a document is worse than a refusal. \
                    Zentic routes these to the cloud model; View ▸ Model is where \
                    OpenAI is chosen, and where its key goes.
                    """
            )
        ) {
            _ = try await provider.generateLens(request)
        }

        await #expect(throws: LLMError.self) {
            _ = try await provider.refitLens(
                LensRefitRequest(catalog: Self.catalog, regions: [])
            )
        }
    }

    @Test("Declining names a provider the user can actually switch to")
    func decliningMessageIsActionable() async throws {
        // A dead end ("unsupported") leaves the user with a lens editor that does
        // nothing and no idea why. The message has to name the way out.
        let provider = SilentProvider()
        do {
            _ = try await provider.generateLens(
                LensRequest(catalog: Self.catalog, prompt: "hide the sidebar")
            )
            Issue.record("the default implementation answered")
        } catch let LLMError.providerFailed(identifier, message) {
            #expect(identifier == "test.silent")
            #expect(message.contains("OpenAI"))
        }
    }

    // MARK: Validation

    @Test("A provider's answer is validated before it is returned")
    func providerValidatesItsAnswer() async throws {
        // `EchoProvider` calls the provider's own decode-validate-re-id step, so
        // removing the validation call from `OpenAIProvider` fails this test rather
        // than leaving a copy of it passing in the stub.
        let provider = EchoProvider(response: Self.modelResponse)
        let proposal = try await provider.generateLens(
            LensRequest(catalog: Self.catalog, prompt: "hide the sidebar")
        )

        // The op naming `comments` is gone: nothing declares that region, so at run
        // time it would match nothing and report drift the site never caused.
        #expect(proposal.ops.map(\.note) == ["hide the suggestions", "tint it"])
        #expect(proposal.ops.allSatisfy { $0.region == "rail" })

        // The region built on an invented selector is gone with it.
        #expect(proposal.regions.map(\.id) == ["rail"])
        #expect(proposal.regions.first?.selectors == ["#secondary", "aside.rail"])

        // And the numbers a schema minimum did not stop are clamped rather than
        // trusted: 9.5x body text is a page the user cannot read.
        #expect(proposal.ops.last?.style?.fontScale == 2.0)
        #expect(proposal.ops.last?.style?.background == "#112233")
    }

    @Test("Op ids are minted locally, not taken from the model")
    func opIDsAreOurs() async throws {
        // Drift reports key on op id, and the editor removes ops by id one chip at a
        // time. A model that answers "op1" twice would make two ops the same op.
        let provider = EchoProvider(response: Self.modelResponse)
        let proposal = try await provider.generateLens(
            LensRequest(catalog: Self.catalog, prompt: "hide the sidebar")
        )

        #expect(!proposal.ops.contains { $0.id == "op1" || $0.id == "op3" })
        #expect(Set(proposal.ops.map(\.id)).count == proposal.ops.count)
        #expect(proposal.ops.allSatisfy { UUID(uuidString: $0.id) != nil })
    }

    @Test("A re-fit cannot introduce a selector the page never offered")
    func refitIsValidated() async throws {
        let provider = EchoProvider(response: Self.modelResponse)
        let regions = try await provider.refitLens(
            LensRefitRequest(
                catalog: Self.catalog,
                regions: [LensRegion(id: "rail", intent: "the sidebar", selectors: ["#old"])]
            )
        )

        #expect(regions.map(\.id) == ["rail"])
        #expect(regions.first?.selectors == ["#secondary", "aside.rail"])
    }

    /// A re-fit that answers with ids nobody asked about, and says nothing about
    /// one that was asked about — both of which a model does.
    static let refitResponse = """
        {
          "regions": [
            {
              "id": "sidebar",
              "intent": "the rail, renamed",
              "selectors": ["#secondary"]
            },
            {
              "id": "rail",
              "intent": "the model's own words for it",
              "selectors": ["#secondary", "aside.rail"]
            }
          ]
        }
        """

    @Test("A re-fit answers about the regions it was asked about, and no others")
    func refitIsConstrainedToWhatWasAsked() async throws {
        // The button says "Re-fit", so the one outcome it must not have is making
        // the drift worse. A caller assigning this to `lens.regions` would, with an
        // unconstrained answer, lose the region every op names — every op then
        // reports `missed` and the lens is dead in a way the user cannot undo.
        let provider = EchoProvider(response: Self.refitResponse)
        let regions = try await provider.refitLens(
            LensRefitRequest(
                catalog: Self.catalog,
                regions: [
                    LensRegion(id: "rail", intent: "the suggested videos sidebar", selectors: ["#old"]),
                    LensRegion(id: "comments", intent: "the comments", selectors: ["#old-comments"]),
                ]
            )
        )

        // One entry per requested region, in the order they were asked for, and
        // nothing the model invented.
        #expect(regions.map(\.id) == ["rail", "comments"])
        #expect(regions.first?.selectors == ["#secondary", "aside.rail"])

        // The region the model could not place keeps what it had: a stale selector
        // and a drift chip the user can act on beats a region that vanished.
        #expect(regions.last?.selectors == ["#old-comments"])

        // And the intent is the user's, kept verbatim — it is what the *next*
        // re-fit works from, so a model paraphrasing it each time erodes it.
        #expect(regions.first?.intent == "the suggested videos sidebar")
    }

    @Test("An empty proposal is a failure, not a lens that does nothing")
    func emptyProposalIsRejected() async throws {
        // Saved, this becomes a row in the popover badged `0/0, no drift`: a lens
        // that reports itself perfectly healthy and has no effect, which the user
        // can only diagnose by deleting it. `LensStore.save` already refuses the shape.
        let provider = EchoProvider(response: """
            {"note": "I could not find anything.", "regions": [], "ops": []}
            """)

        await #expect(throws: LLMError.self) {
            _ = try await provider.generateLens(
                LensRequest(catalog: Self.catalog, prompt: "hide the sidebar")
            )
        }
    }

    @Test("A proposal whose every op validates away is rejected too")
    func proposalThatValidatesToNothingIsRejected() async throws {
        // The same failure arriving by the more likely route: the model answered,
        // and every op it wrote named a region that is not on this page.
        let provider = EchoProvider(response: """
            {
              "note": "Hides the comments.",
              "regions": [],
              "ops": [
                {
                  "id": "op1", "kind": "hide", "region": "comments",
                  "note": "hide the comments", "target": null, "index": null,
                  "fraction": null, "text": null, "style": null, "sort": null,
                  "predicate": null, "filterMode": "drop", "harvest": null,
                  "bucket": null, "itemSelector": null, "limit": null
                }
              ]
            }
            """)

        await #expect(throws: LLMError.self) {
            _ = try await provider.generateLens(
                LensRequest(catalog: Self.catalog, prompt: "hide the comments")
            )
        }
    }

    @Test("The model sees the same catalog its answer is measured against")
    func theCatalogIsCappedOnce() async throws {
        // The prompt used to carry `prefix(lensRegionCandidateLimit)` while
        // validation ran against the whole catalog, so a selector past the cap —
        // one the model was never shown, and could only have invented — was
        // accepted as something "the page offered".
        var crowded = Self.catalog
        crowded.candidates = (0..<(Budget.lensRegionCandidateLimit + 5)).map { index in
            RegionCandidate(
                id: "r\(index)",
                selector: "#r\(index)",
                tag: "div",
                kindGuess: "unknown",
                rect: RegionRect(x: 0, y: 0, width: 10, height: 10),
                depth: 3,
                textLength: 0,
                linkCount: 0,
                paragraphCount: 0,
                imageCount: 0,
                itemCount: 0
            )
        }

        // The provider's own call builder, not a `.validated()` spelled out here:
        // the catalog in the prompt and the catalog the answer is measured against
        // are one object, so deleting the cap fails all three assertions below
        // rather than none of them.
        let call = try OpenAIProvider.lensCall(
            LensRequest(catalog: crowded, prompt: "hide that box"),
            model: "test"
        )
        #expect(call.catalog.candidates.count == Budget.lensRegionCandidateLimit)

        // And what the model is actually shown is that same capped catalog.
        let prompt = try #require(Self.userMessage(call.body))
        #expect(prompt.contains("\"#r0\""))
        #expect(!prompt.contains("\"#r\(Budget.lensRegionCandidateLimit + 1)\""))

        // A region built on a selector past the cap is not a region this page
        // offered, and must not survive.
        let beyond = "#r\(Budget.lensRegionCandidateLimit + 1)"
        let provider = EchoProvider(response: """
            {
              "note": "Hides a box the model was never shown.",
              "regions": [
                {"id": "ghost", "intent": "a box past the cap", "selectors": ["\(beyond)"]}
              ],
              "ops": [
                {
                  "id": "op1", "kind": "hide", "region": "ghost",
                  "note": "hide it", "target": null, "index": null,
                  "fraction": null, "text": null, "style": null, "sort": null,
                  "predicate": null, "filterMode": "drop", "harvest": null,
                  "bucket": null, "itemSelector": null, "limit": null
                }
              ]
            }
            """)

        await #expect(throws: LLMError.self) {
            _ = try await provider.generateLens(
                LensRequest(catalog: crowded, prompt: "hide that box")
            )
        }
    }

    // MARK: Harvest

    /// A page with a feed in it: an item selector, and — the part that took a
    /// field study to notice was missing — a description of what is *inside* one
    /// item, so a `harvest` can name a field instead of guessing at one.
    static let harvestCatalog = RegionCatalog(
        origin: "www.example.com",
        pathPattern: "/",
        viewport: .init(width: 1_280, height: 900),
        candidates: [
            RegionCandidate(
                id: "r0",
                selector: "#feed",
                tag: "div",
                elementID: "feed",
                kindGuess: "feed",
                rect: RegionRect(x: 0, y: 0, width: 800, height: 4_000),
                depth: 5,
                textLength: 40_000,
                linkCount: 120,
                paragraphCount: 30,
                imageCount: 30,
                itemCount: 30,
                itemSelector: ":scope > article.card",
                itemFields: [
                    ItemFieldCandidate(
                        selector: "h3",
                        tag: "h3",
                        attributesPresent: [],
                        textLength: 58
                    ),
                    ItemFieldCandidate(
                        selector: "a[href]",
                        tag: "a",
                        attributesPresent: ["href"],
                        textLength: 58
                    ),
                ]
            ),
            RegionCandidate(
                id: "r1",
                selector: "#secondary",
                tag: "aside",
                elementID: "secondary",
                kindGuess: "aside",
                rect: RegionRect(x: 820, y: 0, width: 400, height: 1_800),
                depth: 5,
                textLength: 900,
                linkCount: 8,
                paragraphCount: 2,
                imageCount: 0,
                itemCount: 0
            ),
        ]
    )

    /// The answer a model gives once it has been told `itemFields` exists: a
    /// `harvest` whose field selectors were copied out of it, and the `insert` that
    /// renders what it collected.
    static let harvestResponse = """
        {
          "note": "Pulls the feed's headlines into the sidebar.",
          "regions": [
            {"id": "feed", "intent": "the story feed", "selectors": ["#feed"]},
            {"id": "rail", "intent": "the sidebar", "selectors": ["#secondary"]}
          ],
          "ops": [
            {
              "id": "op1", "kind": "harvest", "region": "feed",
              "note": "collect the headlines", "target": null, "index": null,
              "fraction": null, "text": null, "style": null, "sort": null,
              "predicate": null, "filterMode": "drop",
              "harvest": {
                "itemSelector": ":scope > article.card",
                "fields": [
                  {"name": "title", "selector": "h3", "attribute": "text"},
                  {"name": "link", "selector": "a[href]", "attribute": "href"}
                ],
                "into": "headlines"
              },
              "bucket": null, "itemSelector": null, "limit": null
            },
            {
              "id": "op2", "kind": "insert", "region": "feed",
              "note": "show them in the sidebar", "target": "rail", "index": 0,
              "fraction": null, "text": null, "style": null, "sort": null,
              "predicate": null, "filterMode": "drop", "harvest": null,
              "bucket": "headlines", "itemSelector": null, "limit": null
            }
          ]
        }
        """

    @Test("A harvest built from itemFields survives validation with its insert")
    func harvestFromItemFieldsSurvives() async throws {
        // The end of the road H1 and H2 exist to open. Every gate on this path is
        // a different one — the harvest's item selector is measured against the
        // catalog, its field selectors are shape-checked only, and the insert is
        // kept alive by a cross-op check that the bucket it names was filled — so
        // a single assertion that both ops came out is the only way to know the
        // whole run is passable.
        let provider = EchoProvider(response: Self.harvestResponse)
        let proposal = try await provider.generateLens(
            LensRequest(catalog: Self.harvestCatalog, prompt: "put the headlines in the sidebar")
        )

        #expect(proposal.ops.map(\.kind) == [.harvest, .insert])

        let harvest = try #require(proposal.ops.first?.harvest)
        #expect(harvest.itemSelector == ":scope > article.card")
        // Copied from `itemFields`, which is not in `knownSelectors` and never
        // will be — a field selector is resolved inside one card, so the catalog
        // gate is the wrong gate for it.
        #expect(harvest.fields.map(\.selector) == ["h3", "a[href]"])
        #expect(harvest.fields.map(\.attribute) == [.text, .href])
        #expect(harvest.into == "headlines")

        // And the insert kept both halves: without either it renders nothing,
        // somewhere, and reports `applied`.
        #expect(proposal.ops.last?.bucket == "headlines")
        #expect(proposal.ops.last?.target == "rail")
    }

    @Test("The model is shown what is inside one item, and none of what it says")
    func itemFieldsReachThePromptTextless() throws {
        // Invariant 4, at the one place it is most tempting to break: a model would
        // pick the headline field instantly from the headline. It gets a selector,
        // a tag, attribute *names* and a character count.
        let call = try OpenAIProvider.lensCall(
            LensRequest(catalog: Self.harvestCatalog, prompt: "put the headlines in the sidebar"),
            model: "test"
        )
        let prompt = try #require(Self.userMessage(call.body))

        #expect(prompt.contains("\"itemFields\""))
        #expect(prompt.contains("\"a[href]\""))
        #expect(prompt.contains("\"attributesPresent\":[\"href\"]"))
        #expect(prompt.contains("\"textLength\":58"))
    }

    // MARK: Instructions

    @Test("The instructions offer itemFields and carve field selectors out of rule 2")
    func instructionsOfferItemFields() throws {
        // Measured across fourteen sites, `harvest` was authorable on none: the
        // candidate description never mentioned `itemFields`, and the one rule that
        // did mention selectors said flatly that an invented one is discarded. A
        // model that follows its instructions either declines or writes an op it has
        // been told will be thrown away. Both halves of that are asserted here,
        // against the string the model is actually sent.
        let halves = OpenAIProvider.lensInstructions.components(separatedBy: "Rules:")
        #expect(halves.count == 2)
        let preamble = try #require(halves.first)
        let rules = try #require(halves.last)
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.first?.isNumber == true }

        // The candidate field list — not a rule — is where the model learns the
        // field exists at all.
        #expect(preamble.contains("itemFields"))
        #expect(preamble.contains("attributesPresent"))

        // Rule 2 keeps its force, but has to say which selectors it is about.
        // Unqualified, it forbids the one selector a harvest must supply.
        let ban = try #require(rules.first { $0.contains("Never invent") })
        #expect(ban.contains("region selector"))

        // And one rule has to say where a harvest's two selectors do come from,
        // or the carve-out is a hole rather than a route.
        let harvest = try #require(rules.first { $0.contains("itemFields") })
        #expect(harvest.contains("\"harvest\""))
        #expect(harvest.contains("itemSelector"))
    }

    // MARK: Schema

    @Test("The op schema names exactly the fields a LensOp decodes")
    func opSchemaMatchesTheType() throws {
        // Strict structured output requires every schema property and rejects
        // extras, so a field renamed on one side and not the other produces JSON
        // that will not decode — at runtime, against the user's own API key.
        let populated = LensOp(
            id: "a",
            kind: .filter,
            region: "feed",
            note: "n",
            target: "rail",
            index: 0,
            fraction: 0.5,
            text: "t",
            style: RegionStyle(background: "#000000"),
            sort: SortSpec(key: .documentOrder),
            predicate: ItemPredicate(terms: ["x"]),
            filterMode: .drop,
            harvest: HarvestSpec(itemSelector: "div.item", fields: [], into: "b"),
            // Every optional populated, because the check is a set comparison
            // against the *encoded* keys: a field left nil is omitted, so a
            // schema property missing on one side and a nil field on the other
            // cancel out. `bucket` was exactly that — absent from the schema,
            // which made `insert` unauthorable, and absent from this fixture,
            // which is why nothing said so.
            itemSelector: "div.item",
            bucket: "b",
            limit: 10
        )
        #expect(try Self.encodedKeys(populated) == Set(Self.opSchemaProperties().keys))
    }

    @Test("Every object nested in an op names exactly the fields its type decodes")
    func nestedSchemasMatchTheirTypes() throws {
        // `bucket` was missing from the op schema and `insert` was unauthorable
        // through the model path for it — the op kind was in the vocabulary and
        // could not be reached. The same omission one level down is quieter still:
        // `strict: true` forbids a property the schema does not name, so a field
        // added to `HarvestSpec` and not here makes every `harvest` fail to
        // decode, against the user's own API key, with nothing on this side saying
        // so. Driven off the encoded types, so adding a field is what fails.
        let op = Self.opSchemaProperties()

        func properties(_ node: Any?) -> Set<String> {
            let object = node as? [String: Any] ?? [:]
            return Set((object["properties"] as? [String: Any] ?? [:]).keys)
        }

        #expect(
            try Self.encodedKeys(
                RegionStyle(
                    background: "#000000",
                    foreground: "#ffffff",
                    fontScale: 1,
                    maxWidthPx: 800,
                    paddingPx: 8,
                    radiusPx: 4,
                    columns: 2,
                    hideImages: true
                )
            ) == properties(op["style"])
        )

        #expect(
            try Self.encodedKeys(SortSpec(key: .harvestedField, field: "title", ascending: true))
                == properties(op["sort"])
        )

        #expect(
            try Self.encodedKeys(
                ItemPredicate(
                    terms: ["x"],
                    matchMode: .any,
                    field: .text,
                    minLinks: 0,
                    maxLinks: 1,
                    minChars: 0,
                    maxChars: 1
                )
            ) == properties(op["predicate"])
        )

        let harvest = op["harvest"]
        #expect(
            try Self.encodedKeys(
                HarvestSpec(itemSelector: ":scope > li", fields: [], into: "b")
            ) == properties(harvest)
        )

        let fields = (harvest as? [String: Any])?["properties"] as? [String: Any]
        let field = (fields?["fields"] as? [String: Any])?["items"]
        #expect(
            try Self.encodedKeys(
                HarvestField(name: "title", selector: "h3", attribute: .text)
            ) == properties(field)
        )

        // The attribute enumeration is the closed set, derived — a schema offering
        // a name the decoder does not know is a proposal that fails to decode, and
        // one missing a name the decoder does know is a column nobody can collect.
        let attribute = (field as? [String: Any])?["properties"] as? [String: Any]
        let cases = (attribute?["attribute"] as? [String: Any])?["enum"] as? [String]
        #expect(cases == HarvestField.allowedAttributes)
        #expect(Set(cases ?? []) == Set(HarvestAttribute.allCases.map(\.rawValue)))
    }

    @Test("The region schema names exactly the fields a LensRegion decodes")
    func regionSchemaMatchesTheType() throws {
        let schema = OpenAIProvider.lensRegionsSchema
        let regions = (schema["properties"] as? [String: Any])?["regions"] as? [String: Any]
        let item = regions?["items"] as? [String: Any]
        let properties = item?["properties"] as? [String: Any] ?? [:]

        // Fully populated, then one name subtracted by hand. A nil field is simply
        // omitted from the encoding, so a fixture that leaves optionals unset makes
        // a missing schema property and a missing field cancel out — which is how
        // `bucket` stayed absent from the op schema while a test claimed the two
        // agreed. `fingerprint` is the one field that is genuinely not the model's
        // to write: it is a structural signature derived here, from the catalog we
        // already hold, and a model asked for one would be inventing the very thing
        // that exists to catch a selector matching the wrong element. Subtracting it
        // by name means the *next* field added to `LensRegion` fails this test.
        let encoded = try Self.encodedKeys(
            LensRegion(
                id: "a",
                intent: "b",
                selectors: ["c"],
                fingerprint: RegionFingerprint(
                    tag: "div",
                    childCount: 4,
                    textLengthBand: 2,
                    rectBand: RegionRectBand(x: 0, y: 0, width: 4, height: 4),
                    siblingIndex: 0
                )
            )
        )
        #expect(encoded.subtracting(["fingerprint"]) == Set(properties.keys))
        #expect(encoded.contains("fingerprint"))
    }

    @Test("Every schema object requires all of its properties")
    func schemaIsStrict() throws {
        // `strict: true` rejects a schema whose objects do not require every
        // property or allow additional ones, and the rejection arrives as an API
        // error the user sees instead of their lens.
        assertStrict(OpenAIProvider.lensProposalSchema)
        assertStrict(OpenAIProvider.lensRegionsSchema)
    }

    private func assertStrict(_ node: Any) {
        guard let object = node as? [String: Any] else { return }
        let types = (object["type"] as? [String]) ?? (object["type"] as? String).map { [$0] } ?? []
        if types.contains("object") {
            let properties = object["properties"] as? [String: Any] ?? [:]
            #expect(object["additionalProperties"] as? Bool == false)
            #expect(Set(object["required"] as? [String] ?? []) == Set(properties.keys))
        }
        // `values` reaches both a property's own schema and an array's `items`.
        for value in object.values { assertStrict(value) }
    }

    /// The field names this value actually encodes, which is what a strict schema
    /// has to name exactly.
    private static func encodedKeys(_ value: some Encodable) throws -> Set<String> {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        return Set((json as? [String: Any] ?? [:]).keys)
    }

    /// The user turn of a request body — what the model is actually shown.
    private static func userMessage(_ body: [String: Any]) -> String? {
        let messages = body["messages"] as? [[String: Any]] ?? []
        return messages.first { $0["role"] as? String == "user" }?["content"] as? String
    }

    private static func opSchemaProperties() -> [String: Any] {
        let properties = OpenAIProvider.lensProposalSchema["properties"] as? [String: Any]
        let ops = properties?["ops"] as? [String: Any]
        let item = ops?["items"] as? [String: Any]
        return item?["properties"] as? [String: Any] ?? [:]
    }
}

// MARK: - Stubs

/// A provider with no lens support at all: it inherits the declining defaults.
private struct SilentProvider: LLMProvider {
    let identifier = "test.silent"
    var tier: ProviderTier { .onDevice }

    func availability() async -> ProviderAvailability { .available }

    func rewrite(_ request: RewriteRequest) -> AsyncThrowingStream<RewriteEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func inferRecipe(from skeleton: DOMSkeleton) async throws -> SiteRecipe {
        throw LLMError.providerFailed(identifier: identifier, message: "no")
    }

    func generateTheme(from prompt: String) async throws -> ThemeTokens {
        throw LLMError.providerFailed(identifier: identifier, message: "no")
    }
}

/// A provider that answers from a canned model response, decoding and validating
/// it exactly as ``OpenAIProvider`` does around its HTTP call.
private struct EchoProvider: LLMProvider {
    let identifier = "test.echo"
    var tier: ProviderTier { .byoKey }
    let response: String

    func availability() async -> ProviderAvailability { .available }

    func rewrite(_ request: RewriteRequest) -> AsyncThrowingStream<RewriteEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func inferRecipe(from skeleton: DOMSkeleton) async throws -> SiteRecipe {
        throw LLMError.providerFailed(identifier: identifier, message: "no")
    }

    func generateTheme(from prompt: String) async throws -> ThemeTokens {
        throw LLMError.providerFailed(identifier: identifier, message: "no")
    }

    /// Exactly what ``OpenAIProvider/generateLens(_:)`` does either side of its
    /// HTTP call, by calling it rather than by copying it.
    ///
    /// The catalog comes from ``OpenAIProvider/lensCall(_:model:)`` rather than
    /// from a `.validated()` written out here: capping it in the stub is how a
    /// deleted cap in the provider stayed green, which is A2.12's failure
    /// reproduced one level up.
    func generateLens(_ request: LensRequest) async throws -> LensProposal {
        let call = try OpenAIProvider.lensCall(request, model: "test")
        return try OpenAIProvider.proposal(from: Data(response.utf8), catalog: call.catalog)
    }

    func refitLens(_ request: LensRefitRequest) async throws -> [LensRegion] {
        let call = try OpenAIProvider.refitCall(request, model: "test")
        return try OpenAIProvider.regions(
            from: Data(response.utf8),
            catalog: call.catalog,
            requested: request.regions
        )
    }
}
