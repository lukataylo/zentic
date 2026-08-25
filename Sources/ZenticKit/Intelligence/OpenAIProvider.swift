import Foundation

/// Bring-your-own-key provider, talking to OpenAI's Responses API.
///
/// The premium tier's first form, and the one with **zero backend**: the user's
/// key goes to the user's own account, so there is no service to run, no billing
/// relationship to broker, and no server of ours that browsing data could pass
/// through. The key lives in the Keychain (``APIKeyStore``).
///
/// ## The boundary that matters
///
/// This provider generates *design*, and design is the place where a model is
/// most tempted to emit code. It does not get to. `generateTheme` returns
/// ``ThemeTokens`` parsed from a constrained JSON schema, and the caller runs
/// `validated()` before anything is rendered. Free-form CSS from a model could
/// carry `url()`, which would beacon to an arbitrary host on every page the user
/// reads — invariant 5 exists precisely because that failure would be silent.
public actor OpenAIProvider: LLMProvider {
    public nonisolated let identifier = "openai"
    public nonisolated var tier: ProviderTier { .byoKey }

    private let model: String
    /// Laying out a whole page is a harder, longer generation than filling in
    /// twenty token fields, and the cheap model shows it.
    private let documentModel: String
    private let session: URLSession
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    public init(
        model: String = "gpt-4.1-mini",
        documentModel: String = "gpt-4.1",
        session: URLSession = .shared
    ) {
        self.model = model
        self.documentModel = documentModel
        self.session = session
    }

    public func availability() async -> ProviderAvailability {
        APIKeyStore.has(.openAI)
            ? .available
            : .unavailable(reason: "Add an OpenAI API key first — Zentic ▸ OpenAI API Key… (⌘,).")
    }

    // MARK: - Theme generation

    public func generateTheme(from prompt: String) async throws -> ThemeTokens {
        let instructions = """
            You are a typographer and interface designer. You produce reading \
            designs for a browser that re-renders web pages in its own design \
            system. You never write CSS or code — only the token values requested.

            Design for sustained reading: generous line height, a measure in the \
            55–80 character range, restrained accent colour, and enough contrast \
            that body text is comfortable. Light and dark palettes must both be \
            complete and legible in their own right; the dark palette is not the \
            light one inverted.

            Colours are #rrggbb. Fonts must come from the allowed list.
            """

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": "Design a reading theme: \(prompt)"],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "theme_tokens",
                    "strict": true,
                    "schema": Self.themeSchema,
                ],
            ],
        ]

        let json = try await post(body)
        guard let content = Self.firstMessageContent(json) else {
            throw LLMError.malformedOutput("no content in response")
        }
        guard let data = content.data(using: .utf8) else {
            throw LLMError.malformedOutput("content was not UTF-8")
        }
        do {
            // Validated by the caller too, but a provider that returned unclamped
            // tokens would make the rule advisory rather than enforced.
            return try JSONDecoder().decode(ThemeTokens.self, from: data).validated()
        } catch {
            throw LLMError.malformedOutput("\(error)")
        }
    }

    // MARK: - Document generation

    /// Ask for the whole page as markup.
    ///
    /// Plain text out, not JSON: a document wrapped in a JSON string doubles the
    /// escaping and is where long generations get truncated. What comes back is
    /// untrusted either way — `sanitize` runs on it before it is returned, so the
    /// caller cannot forget to.
    public func generateDocument(_ request: DocumentRequest) async throws -> GeneratedDocument {
        let body: [String: Any] = [
            "model": documentModel,
            "messages": [
                ["role": "system", "content": Self.documentInstructions],
                ["role": "user", "content": Self.documentPrompt(request)],
            ],
        ]

        let json = try await post(body)
        guard let content = Self.firstMessageContent(json), !content.isEmpty else {
            throw LLMError.malformedOutput("no content in response")
        }

        let html = GeneratedHTML.sanitize(content, allowing: request.contentURLs)
        guard html.contains("<") else {
            throw LLMError.malformedOutput("nothing left after sanitising")
        }
        return GeneratedDocument(html: html)
    }

    private static let documentInstructions = """
        You are a designer who implements. You are given the content of one web \
        page and a description of a look. You return the complete HTML for a \
        reading view of that page — structure and a `<style>` block, nothing else.

        Rules:
        1. Return markup only. No explanation, no markdown fence.
        2. All CSS goes in one `<style>` element at the top. No `url(...)`, no \
        `@import`, no `@font-face`, no webfonts — use locally available families.
        3. No script, no iframe, no form, no tracking pixel, no external request \
        of any kind. Anything of the sort is stripped before your output is used, \
        which will leave a hole in your design.
        4. Never change, summarise or omit the words you are given. You are laying \
        them out, not editing them.
        5. Where you see a placeholder line, emit exactly the tag it names, in the \
        position it belongs. That content is rendered locally and you do not get \
        to see or restyle it.
        6. Design for reading: a measure of 60-75 characters, real vertical rhythm, \
        and a light and dark palette via `@media (prefers-color-scheme: dark)`.
        """

    private static func documentPrompt(_ request: DocumentRequest) -> String {
        var lines = ["Look: \(request.prompt)", "", "Title: \(request.extraction.title)"]
        if let byline = request.extraction.byline { lines.append("Byline: \(byline)") }
        if let site = request.extraction.siteName { lines.append("Site: \(site)") }
        lines.append("")
        lines.append("Content, in order:")

        for section in request.extraction.sections {
            if section.kind.isRewritable {
                lines.append("")
                lines.append("[\(section.kind.rawValue)]")
                lines.append(section.markdown)
            } else {
                // Invariant 3: this section's text is not in the request at all.
                lines.append("")
                lines.append(
                    "[placeholder — emit <zentic-section section=\"\(section.id)\"></zentic-section>]"
                )
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Lens authoring

    /// Turn "hide the suggestions and make the video wider" into ops.
    ///
    /// The request carries a ``RegionCatalog`` and nothing else about the page: tags,
    /// classes, roles, geometry, counts and text *lengths*. No page character is in
    /// this call, which is invariant 4 holding for lenses exactly as it does for
    /// recipe inference — and it is why a lens can be authored for a page that shows
    /// someone's bank balance.
    ///
    /// The schema keeps the model inside the op vocabulary; ``LensProposal/validated(against:)``
    /// then throws away everything the schema could not express — ops naming regions
    /// that do not exist, selectors the page never offered, numbers out of range.
    /// Both, because the schema is a request and validation is the guarantee.
    public func generateLens(_ request: LensRequest) async throws -> LensProposal {
        let call = try Self.lensCall(request, model: model)
        return try Self.proposal(from: try await content(call.body), catalog: call.catalog)
    }

    /// One model call, in the two halves that have to agree about the page.
    ///
    /// The catalog is not a parameter of the request twice over: it is what the
    /// model is *shown* and what its answer is *measured against*, and the whole
    /// class of bug here is those two drifting apart. Returning both from one
    /// function makes them the same object by construction — the prompt used to
    /// carry `prefix(lensRegionCandidateLimit)` while validation ran against the
    /// whole catalog, so a selector past the cap, which the model was never shown
    /// and could only have invented, was accepted as "offered by the page".
    struct LensCall {
        /// The request body, carrying the capped catalog.
        let body: [String: Any]
        /// The same catalog, for ``proposal(from:catalog:)`` or
        /// ``regions(from:catalog:requested:)``.
        let catalog: RegionCatalog
    }

    /// Build the authoring call. Separate from ``generateLens(_:)`` so the capping
    /// step is on the path a test without a network can run — a copy of it in a
    /// stub provider is a step that can be deleted from here with the suite green.
    static func lensCall(_ request: LensRequest, model: String) throws -> LensCall {
        var request = request
        request.catalog = request.catalog.validated()

        return LensCall(
            body: [
                "model": model,
                "messages": [
                    ["role": "system", "content": lensInstructions],
                    ["role": "user", "content": try lensPrompt(request)],
                ],
                "response_format": [
                    "type": "json_schema",
                    "json_schema": [
                        "name": "lens_proposal",
                        "strict": true,
                        "schema": lensProposalSchema,
                    ],
                ],
            ],
            catalog: request.catalog
        )
    }

    /// Decode, validate and re-id one model answer.
    ///
    /// Everything that happens to a proposal between the HTTP response and the
    /// caller, in one place a test can reach without a network. It was inline in
    /// ``generateLens(_:)``, which meant the suite exercised a hand-written copy of
    /// it in a stub provider — and a copy of a trust boundary is a boundary that
    /// can be deleted from the real code with every test still green.
    ///
    /// Validate first, re-id after: validation keys on `region`, not on op ids, and
    /// the ids it would have checked are worthless anyway. Op ids are the keys a
    /// ``LensReport`` reports against and the chips the user removes one at a time,
    /// so they are ours to mint — a model that returns "op1" twice would otherwise
    /// make two ops indistinguishable in the drift list.
    static func proposal(from data: Data, catalog: RegionCatalog) throws -> LensProposal {
        let decoded: LensProposal
        do {
            decoded = try JSONDecoder().decode(LensProposal.self, from: data)
        } catch {
            throw LLMError.malformedOutput("\(error)")
        }

        var validated = decoded.validated(against: catalog)
        validated.ops = validated.ops.map { op in
            var copy = op
            copy.id = UUID().uuidString
            return copy
        }

        // An empty answer is a failure, not a lens. Saved, it becomes a row in the
        // popover badged `0/0, no drift` — a lens that reports itself perfectly
        // healthy and does nothing, which the user can only diagnose by deleting it
        // and trying again. ``LensStore/save(_:)`` already refuses this shape; the
        // authoring path has to refuse it too or the store is the only guard.
        guard !validated.ops.isEmpty else {
            throw LLMError.malformedOutput("the model proposed no op that could act on this page")
        }
        return validated
    }

    /// Ask for new selectors for regions whose old ones match nothing.
    ///
    /// Deliberately narrower than ``generateLens(_:)``: the ops are not in the
    /// request and cannot come back changed. A re-fit that quietly rewrote what the
    /// lens does — while the user was told it was repairing one — would be the
    /// worst kind of surprise, since the thing they asked for is the thing they can
    /// no longer see happening.
    public func refitLens(_ request: LensRefitRequest) async throws -> [LensRegion] {
        let call = try Self.refitCall(request, model: model)
        return try Self.regions(
            from: try await content(call.body),
            catalog: call.catalog,
            requested: request.regions
        )
    }

    /// Build the re-fit call. Same shape and the same reason as
    /// ``lensCall(_:model:)``: one capping step, feeding both halves.
    static func refitCall(_ request: LensRefitRequest, model: String) throws -> LensCall {
        var request = request
        request.catalog = request.catalog.validated()

        return LensCall(
            body: [
                "model": model,
                "messages": [
                    ["role": "system", "content": refitInstructions],
                    ["role": "user", "content": try refitPrompt(request)],
                ],
                "response_format": [
                    "type": "json_schema",
                    "json_schema": [
                        "name": "lens_regions",
                        "strict": true,
                        "schema": lensRegionsSchema,
                    ],
                ],
            ],
            catalog: request.catalog
        )
    }

    /// Decode a re-fit, and reconcile it with what was asked for.
    ///
    /// The answer is **merged by id into the requested list**, never substituted
    /// for it. Two things go wrong otherwise, and both make the button labelled
    /// "Re-fit" the thing that broke the lens:
    ///
    /// - A model that returns an id nobody asked about adds a region the ops do
    ///   not name. Harmless on its own — but a caller that assigns the answer to
    ///   `lens.regions` has then *lost* the region every op does name, so every one
    ///   of them reports `missed` and the lens is worse than before it was repaired.
    /// - A region the model could not place comes back with no usable selectors and
    ///   is dropped by validation. Keeping the stored region there means the user
    ///   keeps a drift chip they can act on, instead of a lens that quietly stopped
    ///   covering part of what they asked for.
    ///
    /// So the result has exactly one entry per requested region, in the order they
    /// were asked for: the re-fitted one where there is a usable one, the original
    /// otherwise.
    static func regions(
        from data: Data,
        catalog: RegionCatalog,
        requested: [LensRegion]
    ) throws -> [LensRegion] {
        let answer: LensRegionList
        do {
            answer = try JSONDecoder().decode(LensRegionList.self, from: data)
        } catch {
            throw LLMError.malformedOutput("\(error)")
        }

        // Through the same gate as a proposal, so a re-fit cannot smuggle in a
        // selector the page never offered.
        let validated = LensProposal(regions: answer.regions, ops: [], note: "")
            .validated(against: catalog)
            .regions
        let byID = Dictionary(validated.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return requested.map { original in
            guard let refitted = byID[original.id], !refitted.selectors.isEmpty else {
                return original
            }
            // The intent is the user's description of what they wanted, kept
            // verbatim: it is what the *next* re-fit works from, and a model
            // paraphrasing it each time would erode it into something that no
            // longer describes the region at all.
            var merged = refitted
            merged.intent = original.intent
            return merged
        }
    }

    /// The wrapper the schema needs. Structured output must be an object, and a
    /// bare array is not one.
    private struct LensRegionList: Decodable {
        var regions: [LensRegion]
    }

    /// Internal rather than private so `LensProviderTests` can assert against the
    /// string the model is actually sent. What a prompt *says* is load-bearing here
    /// in the way a type usually is: `harvest` was unauthorable on fourteen real
    /// sites not because anything rejected it, but because rule 2 told the model its
    /// field selectors would be discarded. A test that cannot read this string
    /// cannot notice that happening again.
    static let lensInstructions = """
        You author "lenses" for a browser. A lens is a small list of operations \
        that remodel a live web page every time the user visits it: hide a region, \
        widen one, move one, restyle one, sort or filter the repeated items inside \
        one. The page's own DOM stays live and interactive — you are rearranging \
        someone's furniture, not rebuilding the house.

        You are given a catalog of the page's regions: tag, id, classes, role, a \
        guess at what the region is, its rectangle, and counts — links, paragraphs, \
        images, repeated items, and the LENGTH of its text. A region that repeats \
        also carries "itemSelector", which matches one of those repeated items, and \
        "itemFields", the insides of one such item sampled from this page: for each, \
        a "selector" relative to the item, its "tag", "attributesPresent" — the \
        NAMES of the attributes it carries — and the LENGTH of its text. You are \
        never given the page's text, or any attribute's value, and you must not ask \
        for them, guess at them, or write ops that depend on knowing them.

        Rules:
        1. Every op's "region" must be an id you declared in "regions".
        2. Every string in a region's "selectors" must be copied character for \
        character from the catalog — a candidate's "selector" or one of its \
        "alternates". Never invent, edit, shorten or combine a region selector. \
        Invented region selectors are discarded and the op with them does nothing. \
        The two kinds of selector inside a "harvest" are copied from a different \
        part of the same catalog entry — see rule 5 — and are the only exception.
        3. List several selectors per region when the catalog offers alternates, \
        best first. They are what keeps the lens working when the site changes.
        4. "itemSelector" must be copied from a candidate's own "itemSelector", \
        and it is REQUIRED on every "reorder" and "filter" op. Without it the op \
        is discarded: an op that fell back to guessing what one item is would \
        reorder or hide a different set of things than the one you chose.
        5. A "harvest" collects columns out of the repeated items in one region, \
        and both of its selectors come from that region's catalog entry rather than \
        from its "selectors" list. "harvest.itemSelector" is copied from the \
        candidate's own "itemSelector". Every "harvest.fields[].selector" is copied \
        character for character from the "selector" of one of that candidate's \
        "itemFields" — these are the fields we sampled from a real item, and they \
        are what rule 2 excepts: they are matched INSIDE one item, not against the \
        page, which is why they are not in the catalog's page-level selector list. \
        Copy them; do not invent one. A field selector you made up reads nothing \
        from every item, and the block the "insert" renders comes out empty. A \
        field's "attribute" must be "text", or one of the names in that entry's \
        "attributesPresent". A candidate with an empty "itemFields" has no sampled \
        item, so do not write a "harvest" against it.
        6. "insert" renders a harvested list somewhere else on the page, so it \
        needs both halves: "target" is the destination region, and "bucket" must \
        be exactly the "into" name of a "harvest" op in this same lens. Every \
        "into" name must be unique within the lens, and a "sort" of \
        "harvestedField" must name a field some "harvest" op produces. An insert \
        naming a bucket nobody filled is discarded.
        7. "intent" describes the region in plain words ("the suggested videos \
        rail"). It is what a future repair works from, so write it for a person.
        8. "note" is one short sentence in the user's own terms — it is the chip \
        they see and click to undo this single op.
        9. For a filter, "terms" must be an expansion of THE USER'S OWN WORDS: \
        their synonyms, plurals and obvious variants. You have no page text, so \
        never guess at phrases the page might contain. Set "filterMode" to "drop" \
        to remove matching items and "keep" to remove everything else.
        10. Use the fewest ops that do what was asked. Prefer hiding a region to \
        restyling it. Do not tidy up things the user did not mention.
        11. Colours are #rrggbb. You never write CSS, HTML or script — there is \
        nowhere in this format to put any, and anything resembling it is discarded.
        12. Every field that does not apply to an op's kind must be null.
        """

    private static let refitInstructions = """
        A saved lens stopped working because the site changed. You are given each \
        region's plain-words intent and a fresh catalog of the page, with no page \
        text in it. Return the same region ids with new selectors.

        Rules:
        1. Keep every id exactly as given. The ops that name them are not yours to \
        change and are not in this request.
        2. Selectors must be copied character for character from the catalog. \
        Never invent one.
        3. Match on intent, using the catalog's kind guess, geometry and counts: a \
        sidebar is tall and narrow and full of links, a feed has a high item count.
        4. If nothing in the catalog plausibly matches an intent, return that \
        region with an empty selector list. Saying so is right; guessing at a \
        region hides the wrong part of the page on every visit from now on.
        """

    private static func lensPrompt(_ request: LensRequest) throws -> String {
        var lines = ["What the user asked for: \(request.prompt)"]
        if !request.selectedRegionIDs.isEmpty {
            lines.append(
                "Regions the user pointed at (a hint, not a constraint): "
                    + request.selectedRegionIDs.joined(separator: ", ")
            )
        }
        if !request.existingRegions.isEmpty {
            // Reusing an id keeps the ops that already name it pointing at the same
            // thing, so an edit adds to a lens instead of replacing it.
            let existing = request.existingRegions
                .map { "\($0.id): \($0.intent)" }
                .joined(separator: "; ")
            lines.append("Regions this lens already names, reuse these ids: \(existing)")
        }
        lines.append("")
        lines.append("Page regions (no page text — see the field list):")
        lines.append(try catalogJSON(request.catalog))
        return lines.joined(separator: "\n")
    }

    private static func refitPrompt(_ request: LensRefitRequest) throws -> String {
        var lines = ["Regions to re-fit:"]
        for region in request.regions {
            lines.append("- \(region.id): \(region.intent)")
        }
        lines.append("")
        lines.append("Fresh page regions:")
        lines.append(try catalogJSON(request.catalog))
        return lines.joined(separator: "\n")
    }

    /// The catalog, encoded as itself.
    ///
    /// Encoding the type rather than hand-writing a table is the point: the privacy
    /// contract is a property of ``RegionCatalog``, asserted by `PrivacyContractTests`,
    /// so anything that reaches this prompt has already been proved textless. A
    /// bespoke string builder here would be a second place for a page character to
    /// get in, and nothing would catch it.
    ///
    /// Not capped here. ``RegionCatalog/validated()`` applies
    /// ``Budget/lensRegionCandidateLimit`` at the top of each call, so the catalog
    /// the model is shown and the catalog its answer is checked against are the
    /// same object — capping in two places is how they came to differ.
    private static func catalogJSON(_ catalog: RegionCatalog) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let text = String(data: try encoder.encode(catalog), encoding: .utf8) else {
            throw LLMError.malformedOutput("catalog was not encodable")
        }
        return text
    }

    /// Post, and return the bytes of the one JSON object that comes back.
    ///
    /// Separate from decoding so the decode-and-validate half is a `static` a test
    /// can call directly. Everything after this line is pure.
    private func content(_ body: [String: Any]) async throws -> Data {
        let json = try await post(body)
        guard let content = Self.firstMessageContent(json) else {
            throw LLMError.malformedOutput("no content in response")
        }
        guard let data = content.data(using: .utf8) else {
            throw LLMError.malformedOutput("content was not UTF-8")
        }
        return data
    }

    // MARK: - Rewrite

    public nonisolated func rewrite(
        _ request: RewriteRequest
    ) -> AsyncThrowingStream<RewriteEvent, any Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    for section in request.sections where section.kind.isRewritable {
                        try Task.checkCancellation()
                        let text = section.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        do {
                            let rewritten = try await self.rewriteSection(text, request: request)
                            continuation.yield(
                                .patch(
                                    RewritePatch(
                                        sectionID: section.id,
                                        markdown: rewritten,
                                        isFinal: true
                                    )
                                )
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            continuation.yield(.skipped(sectionID: section.id, reason: "\(error)"))
                        }
                    }
                    continuation.yield(.finished)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LLMError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private func rewriteSection(_ text: String, request: RewriteRequest) async throws -> String {
        var directives = [request.tone.directive, request.length.directive]
        if let level = request.readingLevel { directives.append(level.directive) }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": """
                        You rewrite passages from a web page. Never add a fact, figure, \
                        name, date or claim that is not in the input, and never drop one \
                        the passage depends on. Preserve Markdown links exactly. Return \
                        only the rewritten passage.
                        """,
                ],
                [
                    "role": "user",
                    "content": "\(directives.joined(separator: " "))\n\nPassage:\n\(text)",
                ],
            ],
        ]
        let json = try await post(body)
        guard let content = Self.firstMessageContent(json)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty
        else {
            throw LLMError.malformedOutput("empty rewrite")
        }
        return content
    }

    // MARK: - Not this milestone

    public nonisolated func inferRecipe(from skeleton: DOMSkeleton) async throws -> SiteRecipe {
        throw LLMError.providerFailed(
            identifier: identifier,
            message: "Recipe inference is not implemented yet (M4)."
        )
    }

    // MARK: - Transport

    private func post(_ body: [String: Any]) async throws -> [String: Any] {
        guard let key = APIKeyStore.load(.openAI) else {
            throw LLMError.notEntitled(tier: .byoKey)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 90

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.providerFailed(identifier: identifier, message: "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // The API's own error text is the most useful thing we can show, and it
            // never contains the key.
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0?["error"] as? [String: Any])?["message"] as? String }
                ?? "HTTP \(http.statusCode)"
            throw LLMError.providerFailed(identifier: identifier, message: detail)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.malformedOutput("response was not an object")
        }
        return json
    }

    private static func firstMessageContent(_ json: [String: Any]) -> String? {
        guard let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else { return nil }
        return content
    }
}

// MARK: - Schema

extension OpenAIProvider {
    /// The JSON schema the model must fill in.
    ///
    /// Every enum is a closed list and every number is bounded, so the *worst* a
    /// model can return is an ugly theme — not an illegible one, and never a
    /// network request. `ThemeTokens.validated()` then clamps ranges and repairs
    /// text/background contrast, so "ugly" is bounded too.
    static var themeSchema: [String: Any] {
        func object(_ properties: [String: Any]) -> [String: Any] {
            [
                "type": "object",
                "properties": properties,
                "required": Array(properties.keys),
                "additionalProperties": false,
            ]
        }
        let hex: [String: Any] = ["type": "string", "pattern": "^#[0-9a-fA-F]{6}$"]
        func number(_ lower: Double, _ upper: Double) -> [String: Any] {
            ["type": "number", "minimum": lower, "maximum": upper]
        }
        func enumeration(_ cases: [String]) -> [String: Any] {
            ["type": "string", "enum": cases]
        }

        let fonts = FontKey.allCases.map(\.rawValue)
        let palette = object([
            "background": hex, "surface": hex, "text": hex, "textMuted": hex,
            "accent": hex, "visited": hex, "border": hex, "codeBackground": hex,
        ])

        return object([
            "typography": object([
                "body": enumeration(fonts),
                "heading": enumeration(fonts),
                "mono": enumeration(fonts),
                "baseSize": number(14, 24),
                "scaleRatio": number(1.1, 1.5),
                "lineHeight": number(1.3, 2.0),
                "measure": number(45, 90),
                "letterSpacing": number(-0.03, 0.08),
            ]),
            "light": palette,
            "dark": palette,
            "shape": object([
                "radius": number(0, 20),
                "borderWidth": number(0, 3),
                "elevation": enumeration(ThemeTokens.Shape.Elevation.allCases.map(\.rawValue)),
            ]),
            "ornament": object([
                "rule": enumeration(ThemeTokens.Ornament.RuleStyle.allCases.map(\.rawValue)),
                "listMarker": enumeration(ThemeTokens.Ornament.ListMarker.allCases.map(\.rawValue)),
                "linkDecoration": enumeration(
                    ThemeTokens.Ornament.LinkDecoration.allCases.map(\.rawValue)
                ),
                "headingCase": enumeration(ThemeTokens.Ornament.HeadingCase.allCases.map(\.rawValue)),
                "dropCap": ["type": "boolean"],
                "justify": ["type": "boolean"],
            ]),
            "density": number(0.7, 1.4),
        ])
    }
}

// MARK: - Lens schema

extension OpenAIProvider {
    /// Every property required, no additional properties, optionals expressed as a
    /// union with `null`. That is what strict structured output demands, and it
    /// also happens to be what stops a model quietly omitting `filterMode` on a
    /// `filter` op and leaving the runtime to guess between keeping and dropping.
    private static func object(_ properties: [String: Any]) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": Array(properties.keys),
            "additionalProperties": false,
        ]
    }

    /// An object that may be absent. `filter` ops carry a predicate and nothing
    /// else; `restyle` ops carry a style and nothing else.
    private static func nullableObject(_ properties: [String: Any]) -> [String: Any] {
        [
            "type": ["object", "null"],
            "properties": properties,
            "required": Array(properties.keys),
            "additionalProperties": false,
        ]
    }

    private static func strings() -> [String: Any] {
        ["type": "array", "items": ["type": "string"]]
    }

    private static func enumeration(_ cases: [String]) -> [String: Any] {
        ["type": "string", "enum": cases]
    }

    private static var lensRegionSchema: [String: Any] {
        object([
            "id": ["type": "string"],
            "intent": ["type": "string"],
            "selectors": strings(),
        ])
    }

    /// The shape a lens proposal must arrive in.
    ///
    /// Bounds are on every numeric even though ``LensProposal/validated(against:)``
    /// clamps them anyway. The schema is how the model is *told* what a sane value
    /// is, so it usually returns one; validation is how we survive the time it does
    /// not. Neither is sufficient alone.
    static var lensProposalSchema: [String: Any] {
        let nullableString: [String: Any] = ["type": ["string", "null"]]
        let nullableInt: [String: Any] = ["type": ["integer", "null"]]
        let hex: [String: Any] = ["type": ["string", "null"], "pattern": "^#[0-9a-fA-F]{6}$"]

        let style = nullableObject([
            "background": hex,
            "foreground": hex,
            "fontScale": ["type": ["number", "null"], "minimum": 0.5, "maximum": 2.0],
            "maxWidthPx": ["type": ["integer", "null"], "minimum": 200, "maximum": 4_000],
            "paddingPx": ["type": ["integer", "null"], "minimum": 0, "maximum": 200],
            "radiusPx": ["type": ["integer", "null"], "minimum": 0, "maximum": 64],
            "columns": ["type": ["integer", "null"], "minimum": 1, "maximum": 4],
            "hideImages": ["type": ["boolean", "null"]],
        ])

        let sort = nullableObject([
            "key": enumeration(SortKey.allCases.map(\.rawValue)),
            "field": nullableString,
            "ascending": ["type": "boolean"],
        ])

        let predicate = nullableObject([
            // Terms come from the user's prompt, expanded. The cap is here as well
            // as in validation so the model is not encouraged to write a thesaurus.
            "terms": [
                "type": "array",
                "items": ["type": "string"],
                "maxItems": ItemPredicate.maxTerms,
            ],
            "matchMode": enumeration(MatchMode.allCases.map(\.rawValue)),
            "field": enumeration(ItemField.allCases.map(\.rawValue)),
            "minLinks": nullableInt,
            "maxLinks": nullableInt,
            "minChars": nullableInt,
            "maxChars": nullableInt,
        ])

        let harvest = nullableObject([
            "itemSelector": ["type": "string"],
            "fields": [
                "type": "array",
                "maxItems": HarvestSpec.maxFields,
                "items": object([
                    "name": ["type": "string"],
                    "selector": ["type": "string"],
                    // Derived from `HarvestAttribute`, never written out again:
                    // a schema listing an attribute the decoder does not know is
                    // a decode failure against the user's own API key.
                    "attribute": enumeration(HarvestField.allowedAttributes),
                ]),
            ],
            "into": ["type": "string"],
        ])

        let op = object([
            "id": ["type": "string"],
            "kind": enumeration(LensOpKind.allCases.map(\.rawValue)),
            "region": ["type": "string"],
            "note": ["type": "string"],
            "target": nullableString,
            "index": nullableInt,
            "fraction": ["type": ["number", "null"], "minimum": 0.1, "maximum": 1.0],
            "text": nullableString,
            "style": style,
            "sort": sort,
            "predicate": predicate,
            // Not nullable: a `filter` without a mode is unrunnable, and every
            // other kind ignores it, so requiring it costs nothing and removes the
            // one field a model most reliably forgets.
            "filterMode": enumeration(FilterMode.allCases.map(\.rawValue)),
            "harvest": harvest,
            // Which harvested bucket an `insert` renders. Absent from the schema
            // until now, and `strict: true` forbids a property it does not name —
            // so a model could not author an `insert` that survived validation,
            // which requires both `target` and `bucket`. The op kind was in the
            // vocabulary and unreachable through the model path.
            "bucket": nullableString,
            "itemSelector": nullableString,
            "limit": [
                "type": ["integer", "null"],
                "minimum": 1,
                "maximum": Budget.lensMaxItemsPerPass,
            ],
        ])

        return object([
            "regions": ["type": "array", "items": lensRegionSchema],
            "ops": [
                "type": "array",
                "maxItems": Budget.lensMaxOpsPerLens,
                "items": op,
            ],
            "note": ["type": "string"],
        ])
    }

    /// Re-fit returns regions only. The ops are not in the request, so they cannot
    /// come back altered.
    static var lensRegionsSchema: [String: Any] {
        object(["regions": ["type": "array", "items": lensRegionSchema]])
    }
}
