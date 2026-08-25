import Foundation

// MARK: - The lens

extension Lens {
    /// Reduce a whole lens to something that can only do what a lens is allowed
    /// to do, or reject it.
    ///
    /// ``LensProposal/validated(against:)`` guards the model's answer, but the
    /// type that actually crosses into a page is this one: it rides on
    /// ``ReaderConfiguration/lenses``, which is interpolated into the bootstrap
    /// JavaScript, and on ``ReaderCommand/applyLenses``. A lens read off disk or
    /// hand-built in a test reaches the page without ever having been a proposal —
    /// so without this entry point the trust boundary has a door in it that a
    /// hand-edited `Lenses.json` walks straight through.
    ///
    /// Returns `nil` when nothing usable is left: a different schema version, a
    /// host that could not have come from a URL, or an op list that validated
    /// away to nothing. A lens with no ops is not a lens, it is a row in the
    /// popover that never does anything and cannot be debugged.
    ///
    /// - Parameter catalog: The page the ops were authored against. `nil` — a
    ///   lens being read back off disk, which is the only remaining caller that
    ///   has no page in front of it — disables the selector gate but keeps every
    ///   shape check. Every path that *does* have a live catalog must pass it:
    ///   with import gone, the catalog gate is what stands between a selector and
    ///   the stylesheet, and skipping it where a catalog exists is a hole rather
    ///   than a shortcut.
    public func validated(against catalog: RegionCatalog? = nil) -> Lens? {
        guard isCompatible else { return nil }
        guard let origin = LensStore.validOrigin(origin) else { return nil }
        // The lens's own id is chosen by whoever wrote the draft or the file, and
        // it is what the store matches on, what a report keys against, and what
        // the editor is reopened with. ``LensOp/id`` and ``LensRegion/id`` are
        // both held to the identifier alphabet; this one was not.
        guard let id = LensToken.identifier(id) else { return nil }

        // Derived once, here. The catalog is itself untrusted page input and it is
        // the gate every selector is measured against, so it is capped and
        // shape-checked before it is trusted to say what this page offers — and
        // the *same* set then judges regions, item selectors and harvest
        // selectors. Deriving it twice is how the two gates came to disagree.
        let known = catalog?.validated().knownSelectors
        let regions = LensValidation.regions(self.regions, knownSelectors: known)
        let ops = LensValidation.ops(
            self.ops,
            regions: Set(regions.map(\.id)),
            knownSelectors: known
        )
        guard !ops.isEmpty else { return nil }

        var copy = self
        copy.id = id
        // A nameless lens is a blank row in the popover the user cannot identify
        // to switch off, which is worse than a dull name.
        let name = LensToken.plainText(name, limit: LensStore.maxNameLength)
        copy.name = name.isEmpty ? "Lens" : name
        copy.origin = origin
        copy.pathPattern = LensPath.stored(pathPattern)
        copy.prompt = LensToken.plainText(prompt, limit: LensStore.maxPromptLength)
        copy.schemaVersion = Lens.currentSchemaVersion
        copy.regions = regions
        copy.ops = ops
        // The report is the one field in a lens that the *page* wrote, and it was
        // the one field this function left alone — so a hand-edited `Lenses.json`
        // or a page posting a `lensReport` put unbounded strings straight into the
        // popover and back onto disk on every launch. A report naming another lens
        // describes a page load this lens was not part of, so its counts would
        // badge the wrong row.
        copy.lastReport = lastReport.flatMap { $0.lensID == id ? $0.validated() : nil }
        return copy
    }
}

// MARK: - Proposal

extension LensProposal {
    /// Regions one proposal or lens may declare.
    ///
    /// Not ``Budget/lensRegionCandidateLimit`` — that is a cap on what the
    /// *page* offers a model, and using it here made one number mean two
    /// unrelated things. An op names at most two regions (its own and a move or
    /// insert destination), so twice the op cap is the most a lens can possibly
    /// reference; anything beyond it is a model listing the page rather than
    /// answering the question.
    public static let maxRegions = Budget.lensMaxOpsPerLens * 2

    /// Reduce model output to something that can only do what a lens is allowed
    /// to do.
    ///
    /// This is a trust boundary, not a tidy-up. Everything downstream — the
    /// stylesheet compiler, the op runner, the store — treats a validated
    /// proposal as safe, so the rules are enforced here once rather than
    /// re-checked in four places:
    ///
    /// - **Regions are the vocabulary.** An op may only name a region the
    ///   proposal declares, and a region may only carry selectors the page
    ///   actually offered. A model cannot invent a selector for a page it never
    ///   saw, which is invariant 5's "validated tokens, never CSS" applied to
    ///   structure instead of colour.
    /// - **Numbers are clamped, never trusted.** A `fontScale` of 400 is a
    ///   broken page, not an error worth failing the whole proposal over.
    /// - **Counts are capped at the ``Budget`` limits**, because the op pass has
    ///   a frame budget and an unbounded op list would blow it every visit.
    ///
    /// Ops that survive none of that are dropped rather than repaired: an op
    /// with no reachable target does nothing except report drift it did not
    /// cause.
    ///
    /// - Parameter catalog: The page the ops were authored against. A proposal is
    ///   an answer *about a page we are looking at*, so `nil` here means the
    ///   selector gate is off for model output — which is the one place it must
    ///   never be. It stays optional only because the type says so; every caller
    ///   has the catalog it sent.
    public func validated(against catalog: RegionCatalog?) -> LensProposal {
        // One derivation of the catalog for the whole proposal — see
        // ``Lens/validated(against:)`` for why that is load-bearing rather than
        // tidy.
        let known = catalog?.validated().knownSelectors
        // Regions first: an op is only as valid as the region it names, so the
        // surviving region set has to exist before ops can be judged.
        let regions = LensValidation.regions(self.regions, knownSelectors: known)
        let ops = LensValidation.ops(
            self.ops,
            regions: Set(regions.map(\.id)),
            knownSelectors: known
        )

        return LensProposal(
            regions: regions,
            ops: ops,
            note: LensToken.plainText(note, limit: LensOp.maxNoteLength)
        )
    }
}

// MARK: - Shared passes

/// The region and op passes, in one place so a lens and a proposal cannot come
/// to different conclusions about the same ops.
///
/// They used to be spelled out inside ``LensProposal/validated(against:)``, which
/// meant ``Lens/validated(against:)`` would have had to repeat them — and a
/// duplicated trust boundary is one that drifts, quietly, in the direction of the
/// looser copy.
///
/// Both passes take the selector *set* rather than the catalog, and that is the
/// point rather than a convenience. Two callers deriving it separately is how the
/// region pass came to measure against `catalog.validated().knownSelectors` while
/// the op pass measured against the raw, uncapped `catalog.knownSelectors` — so a
/// selector past ``Budget/lensRegionCandidateLimit``, which the model is never
/// shown and could only have invented, was rejected as a region and accepted as
/// the thing a `drop` filter operates on.
enum LensValidation {
    static func regions(_ regions: [LensRegion], knownSelectors: Set<String>?) -> [LensRegion] {
        var seen: Set<String> = []
        var kept: [LensRegion] = []
        for region in regions {
            guard kept.count < LensProposal.maxRegions else { break }
            guard let validated = region.validated(knownSelectors: knownSelectors) else { continue }
            guard seen.insert(validated.id).inserted else { continue }
            kept.append(validated)
        }
        return kept
    }

    static func ops(
        _ ops: [LensOp],
        regions: Set<String>,
        knownSelectors: Set<String>?
    ) -> [LensOp] {
        var seen: Set<String> = []
        var kept: [LensOp] = []
        for op in ops {
            guard kept.count < Budget.lensMaxOpsPerLens else { break }
            guard let validated = op.validated(regions: regions, knownSelectors: knownSelectors)
            else { continue }
            // Two ops sharing an id make a report ambiguous: the UI could not say
            // which chip drifted, and the re-fit button would target both.
            guard seen.insert(validated.id).inserted else { continue }
            kept.append(validated)
        }
        return crossReferenced(kept)
    }

    /// The checks one op cannot make about itself.
    ///
    /// `insert` reads a bucket another op filled; a harvested-field sort reads a
    /// column another op collected. Per-op validation can only see that the names
    /// are well formed, not that anything answers to them — and an op naming a
    /// bucket nothing writes is a `missed` on every visit for a reason that has
    /// nothing to do with the site.
    private static func crossReferenced(_ ops: [LensOp]) -> [LensOp] {
        // What this lens actually produces. Buckets are unique: two harvests into
        // one name means the second silently replaces the first, so an `insert`
        // would render whichever ran last rather than what was authored.
        var buckets: Set<String> = []
        var fields: Set<String> = []
        var producers: [LensOp] = []
        for op in ops {
            guard op.kind == .harvest, let spec = op.harvest else {
                producers.append(op)
                continue
            }
            guard buckets.insert(spec.into).inserted else { continue }
            fields.formUnion(spec.fields.map(\.name))
            producers.append(op)
        }

        var kept: [LensOp] = []
        var moves: [String: String] = [:]
        for op in producers {
            var op = op

            // A sort naming a column no harvest collects would look up nothing for
            // every item, so every key would be equal and the run would come out in
            // document order anyway. Saying so is honest; leaving the name in place
            // would report a sort that never happened.
            if op.sort?.key == .harvestedField,
                let field = op.sort?.field,
                !fields.contains(field)
            {
                op.sort = SortSpec(key: .documentOrder, ascending: op.sort?.ascending ?? true)
            }

            switch op.kind {
            case .insert:
                guard let bucket = op.bucket, buckets.contains(bucket) else { continue }
            case .move:
                // A cycle of moves is a hierarchy error at best and a detached
                // subtree at worst: A into B then B into A takes both out of the
                // page, and the second op is the one that had no way to know.
                guard let target = op.target else { continue }
                guard !reaches(from: target, to: op.region, in: moves) else { continue }
                moves[op.region] = target
            default:
                break
            }

            kept.append(op)
        }
        return kept
    }

    private static func reaches(from: String, to: String, in moves: [String: String]) -> Bool {
        var cursor: String? = from
        var steps = 0
        while let current = cursor, steps <= moves.count {
            if current == to { return true }
            cursor = moves[current]
            steps += 1
        }
        return false
    }
}

extension LensRegion {
    /// Drop selectors the page never offered, and the region itself if that
    /// leaves nothing to match.
    ///
    /// - Parameter knownSelectors: `nil` skips the catalog gate; selectors are
    ///   still checked for shape.
    func validated(knownSelectors: Set<String>?) -> LensRegion? {
        guard let id = LensToken.identifier(id) else { return nil }

        var selectors: [String] = []
        for selector in self.selectors {
            // Capped, because every candidate is unioned into the stylesheet for
            // every op naming this region and the sheet is rebuilt on every SPA
            // navigation. A lens carrying 500 selectors across 40 ops made a
            // five-megabyte sheet per route change, with every selector passing
            // the shape gate.
            guard selectors.count < Self.maxSelectors else { break }
            guard let safe = LensToken.regionSelector(selector) else { continue }
            if let knownSelectors, !knownSelectors.contains(safe) { continue }
            guard !selectors.contains(safe) else { continue }
            selectors.append(safe)
        }
        guard !selectors.isEmpty else { return nil }

        return LensRegion(
            id: id,
            intent: LensToken.plainText(intent, limit: LensOp.maxNoteLength),
            selectors: selectors,
            fingerprint: fingerprint?.validated()
        )
    }
}

extension RegionFingerprint {
    /// Cap every list and clamp every number.
    ///
    /// A fingerprint arrives from the page, is written to disk, and is read back
    /// on every launch — the same untrusted round trip a ``LensReport`` makes, and
    /// the reason that one is validated. Unbounded, it is a place a page can write
    /// as much as it likes into `Lenses.json` once per saved lens.
    ///
    /// Nothing here can reject the fingerprint: a signature that survives with
    /// fewer classes than it was given still scores, just less confidently, and a
    /// region with no fingerprint at all is one that resolves by selector alone.
    /// There is no failure worth throwing away the selectors over.
    func validated() -> RegionFingerprint {
        RegionFingerprint(
            // Tags, classes and attribute names are all CSS identifiers, so they
            // go through the identifier alphabet rather than the prose gate. A
            // token that is not an identifier could not have come off an element
            // this side will ever have to match. It also drops Tailwind's
            // punctuated utilities — `md:flex`, `w-1/2` — and that is a gain
            // rather than a loss: those are shared by half the page, so they
            // identify nothing and would only dilute the score.
            tag: LensToken.identifier(tag)?.lowercased() ?? "",
            elementID: elementID.flatMap(LensToken.identifier),
            classes: Array(classes.compactMap(LensToken.identifier).prefix(Self.maxClasses)),
            attributeNames: Array(
                attributeNames.compactMap(LensToken.identifier)
                    .map { $0.lowercased() }
                    .prefix(Self.maxAttributeNames)
            ),
            role: role.flatMap(LensToken.identifier)?.lowercased(),
            childCount: childCount.clamped(to: Self.countBounds),
            textLengthBand: textLengthBand.clamped(to: Self.bandBounds),
            rectBand: RegionRectBand(
                x: rectBand.x.clamped(to: Self.bandBounds),
                y: rectBand.y.clamped(to: Self.bandBounds),
                width: rectBand.width.clamped(to: Self.bandBounds),
                height: rectBand.height.clamped(to: Self.bandBounds)
            ),
            siblingIndex: siblingIndex.clamped(to: Self.countBounds),
            ancestorTags: Array(
                ancestorTags.compactMap(LensToken.identifier)
                    .map { $0.lowercased() }
                    .prefix(Self.maxAncestors)
            )
        )
    }
}

// MARK: - Ops

extension LensOp {
    /// Clamp this op into range, or reject it.
    ///
    /// Returns `nil` when the op cannot do anything: it names a region that does
    /// not exist, or it is missing the one field its kind is defined by. Both
    /// are silent no-ops at run time that would still be reported as `applied`,
    /// which is worse than not shipping the op at all.
    ///
    /// There used to be a `validated(regions:catalog:)` beside this that took a
    /// catalog and derived the selector set itself. Nothing but a test ever
    /// called it, and a second entry point into a trust boundary is a second
    /// place for the derivation to drift — which had already happened once, when
    /// one gate measured against a capped catalog and the other against a raw one.
    ///
    /// - Parameters:
    ///   - regions: Ids declared by the lens this op belongs to.
    ///   - knownSelectors: Selectors the page offered, derived once by the
    ///     whole-lens or whole-proposal pass and shared by every op in it, so
    ///     every op in one lens is judged against the same page. `nil` disables
    ///     the catalog gate and keeps every shape check.
    func validated(regions: Set<String>, knownSelectors: Set<String>?) -> LensOp? {
        guard regions.contains(region) else { return nil }
        // Ids are compared, stored and echoed back in every ``LensOpResult``, so
        // they get the same tiny alphabet ``LensRegion/id`` does.
        guard let id = LensToken.identifier(id) else { return nil }

        var copy = self
        copy.id = id
        copy.note = LensToken.plainText(note, limit: Self.maxNoteLength)
        copy.index = index.map { $0.clamped(to: Self.indexBounds) }
        copy.fraction = fraction.flatMap { $0.clampedFinite(to: 0.1...1.0) }
        copy.limit = limit.map { $0.clamped(to: 1...Budget.lensMaxItemsPerPass) }
        copy.text = text.map { LensToken.plainText($0, limit: Self.maxLabelLength) }
        copy.style = style?.validated()
        copy.sort = sort?.validated()
        copy.predicate = predicate?.validated()
        copy.harvest = harvest?.validated(knownSelectors: knownSelectors)
        copy.bucket = bucket.flatMap(LensToken.identifier)

        // An item selector that fails the gate takes the whole op with it, rather
        // than being nulled while the op survives. Nulling turns "drop the cards
        // matching X" into "drop whatever the runner decides an item is", and the
        // runner's fallback is the region's own children — so a scoped `drop`
        // filter would quietly become an unscoped one and empty the feed.
        if let supplied = itemSelector {
            guard let safe = LensToken.pageSelector(supplied, knownSelectors: knownSelectors)
            else { return nil }
            copy.itemSelector = safe
        }

        if let target = copy.target, !regions.contains(target) { copy.target = nil }
        if let style = copy.style, style.isEmpty { copy.style = nil }
        if let predicate = copy.predicate, predicate.isVacuous { copy.predicate = nil }

        // Each kind is defined by one field. Without it there is nothing to run.
        switch copy.kind {
        case .hide, .keep:
            break
        case .width:
            guard copy.fraction != nil else { return nil }
        case .move:
            guard let target = copy.target else { return nil }
            // Moving a region into itself is `appendChild(self)`: a hierarchy
            // error, or a subtree detached from the document with the landmark
            // still inside it.
            guard target != copy.region else { return nil }
        case .insert:
            // Both halves or neither: `target` is where the block goes, `bucket`
            // is what goes in it. An insert missing either has nothing to render
            // and nowhere to render it.
            guard copy.target != nil, copy.bucket != nil else { return nil }
        case .restyle:
            guard copy.style != nil else { return nil }
        case .reorder:
            guard copy.sort != nil else { return nil }
            // `reorder` and `filter` are defined by the item they act on. Without
            // it the runner falls back to the region's own element children, which
            // is a different set from the one the op was written against.
            guard copy.itemSelector != nil else { return nil }
        case .filter:
            guard copy.predicate != nil else { return nil }
            // A filter with no mode would have to guess between keeping and
            // dropping, and guessing wrong empties the feed.
            guard copy.filterMode != nil else { return nil }
            guard copy.itemSelector != nil else { return nil }
        case .label:
            guard let text = copy.text, !text.isEmpty else { return nil }
        case .harvest:
            guard copy.harvest != nil else { return nil }
        }

        return copy
    }
}

extension RegionStyle {
    /// Clamp every numeric to its documented range and reduce colours to
    /// `#rrggbb` or nothing.
    ///
    /// A colour that does not parse becomes `nil` rather than a fallback: unlike
    /// a theme, a lens style is an overlay on the site's own design, so leaving
    /// the site's colour alone is always the correct repair.
    public func validated() -> RegionStyle {
        RegionStyle(
            background: background.flatMap(LensToken.colour),
            foreground: foreground.flatMap(LensToken.colour),
            fontScale: fontScale.flatMap { $0.clampedFinite(to: 0.5...2.0) },
            maxWidthPx: maxWidthPx?.clamped(to: 200...4_000),
            paddingPx: paddingPx?.clamped(to: 0...200),
            radiusPx: radiusPx?.clamped(to: 0...64),
            columns: columns?.clamped(to: 1...4),
            hideImages: hideImages
        )
    }
}

extension ItemPredicate {
    /// Cap the term list, drop terms that are too long to be words, and repair
    /// unsatisfiable bounds.
    ///
    /// Over-long terms are dropped rather than truncated. Truncating changes
    /// what a term means — under ``MatchMode/any`` a shortened term matches
    /// *more* items, so a `drop` filter would quietly delete things the user
    /// never asked to lose.
    ///
    /// A `min` above its `max` is swapped rather than honoured, for the same
    /// reason: an unsatisfiable range makes a `keep` filter empty the feed.
    public func validated() -> ItemPredicate {
        var copy = self

        var terms: [String] = []
        for term in self.terms {
            guard terms.count < Self.maxTerms else { break }
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= Self.maxTermLength else { continue }
            terms.append(trimmed)
        }
        copy.terms = terms

        copy.minLinks = minLinks?.clamped(to: Self.linkBounds)
        copy.maxLinks = maxLinks?.clamped(to: Self.linkBounds)
        copy.minChars = minChars?.clamped(to: Self.charBounds)
        copy.maxChars = maxChars?.clamped(to: Self.charBounds)

        if let low = copy.minLinks, let high = copy.maxLinks, low > high {
            (copy.minLinks, copy.maxLinks) = (high, low)
        }
        if let low = copy.minChars, let high = copy.maxChars, low > high {
            (copy.minChars, copy.maxChars) = (high, low)
        }

        return copy
    }
}

extension SortSpec {
    /// Fall back to document order when a harvested-field sort names no field.
    ///
    /// Falling back beats rejecting: the region still renders, just in the
    /// site's own order, which is what the user had before the lens.
    func validated() -> SortSpec {
        guard key == .harvestedField else { return SortSpec(key: key, ascending: ascending) }
        guard let name = field.flatMap(LensToken.identifier) else {
            return SortSpec(key: .documentOrder, ascending: ascending)
        }
        return SortSpec(key: .harvestedField, field: name, ascending: ascending)
    }
}

extension HarvestSpec {
    /// Reject the spec unless it has a reachable item selector and at least one
    /// well-formed field.
    func validated(knownSelectors: Set<String>?) -> HarvestSpec? {
        guard
            let item = LensToken.pageSelector(itemSelector, knownSelectors: knownSelectors),
            let bucket = LensToken.identifier(into)
        else { return nil }

        var fields: [HarvestField] = []
        for field in self.fields {
            guard fields.count < Self.maxFields else { break }
            guard
                let name = LensToken.identifier(field.name),
                // Field selectors are relative to one item, so they are not in
                // ``RegionCatalog/knownSelectors`` and can only be checked for
                // shape here. The offer they were copied from —
                // ``RegionCandidate/itemFields`` — went through this same gate on
                // the way in, so a field selector is shape-checked on both sides
                // of the model rather than only on the way back. The attribute
                // needs no check at all now that it is a closed enum: an unknown
                // name cannot survive decoding.
                let selector = LensToken.selector(field.selector)
            else { continue }
            fields.append(
                HarvestField(name: name, selector: selector, attribute: field.attribute)
            )
        }
        guard !fields.isEmpty else { return nil }

        return HarvestSpec(itemSelector: item, fields: fields, into: bucket)
    }
}

// MARK: - Reports

extension LensReport {
    /// Reduce a report the page sent us to something bounded, or reject it.
    ///
    /// This is the only part of a ``Lens`` the *page* writes. Everything else is
    /// authored on this side and validated before it crosses; a report travels the
    /// other way, is persisted into `Lenses.json`, is re-read on every launch, and
    /// is rendered in the popover — and none of it was checked. A page posting a
    /// `lensReport` with fifty thousand results and megabyte messages got all of
    /// it written to disk, and the file it went into is one every launch reads
    /// back.
    ///
    /// Returns `nil` when the report cannot be about a lens at all. Individual
    /// results are dropped rather than taking the report with them: the rows that
    /// do describe the page are still the truth about it, and a report that
    /// vanished would show as "never ran" instead of as drift.
    public func validated() -> LensReport? {
        guard let lensID = LensToken.identifier(lensID) else { return nil }

        var seen: Set<String> = []
        var kept: [LensOpResult] = []
        for result in results {
            guard kept.count < Self.maxResults else { break }
            // Op ids come back to be matched against the lens's own ops, so they
            // get the alphabet those were held to. Two results for one op make a
            // drift row ambiguous the same way two ops sharing an id do.
            guard let opID = LensToken.identifier(result.opID) else { continue }
            guard seen.insert(opID).inserted else { continue }

            let message = result.message
                .map { LensToken.plainText($0, limit: LensOp.maxNoteLength) }
                .flatMap { $0.isEmpty ? nil : $0 }
            kept.append(
                LensOpResult(
                    opID: opID,
                    status: result.status,
                    // Rendered as a count in a chip and nothing more, so an absurd
                    // number is a layout problem rather than a logic one — but it
                    // is still a number the page chose.
                    matchedCount: result.matchedCount.clamped(to: 0...Budget.lensMaxItemsPerPass),
                    // The selector shown in a drift row so the user can see what a
                    // re-fit changed. It should be one of the lens's own
                    // candidates, which means it has already passed this gate.
                    usedSelector: result.usedSelector.flatMap(LensToken.selector),
                    message: message
                )
            )
        }

        return LensReport(
            lensID: lensID,
            url: Self.pathOnly(url),
            results: kept,
            generatedAt: generatedAt
        )
    }

    /// The path, with the host, query and fragment left behind.
    ///
    /// `web/src/lens/index.ts` already strips a report before posting it, and that
    /// is the wrong side of the wire to be the only side: events travel page → app,
    /// so a page that skips the step — or a runner from a build before it existed —
    /// decides what browsing history this app writes to disk. A path is enough to
    /// say which page a lens last ran on; a query string is where the session
    /// tokens, the search terms and the message ids live. Invariant 7 is about the
    /// network, but the same reasoning applies to a file the user is encouraged to
    /// share.
    private static func pathOnly(_ value: String) -> String {
        let trimmed = LensToken.plainText(value, limit: LensStore.maxPatternLength)
        // An absolute URL: take the path component and drop the rest of it.
        if let url = URL(string: trimmed), url.scheme != nil {
            let path = url.path()
            return path.isEmpty ? "/" : path
        }
        // Already a path, which is the normal case. Cut anything a query or a
        // fragment could be hiding behind, and root it so it compares against
        // `URL.path()` — ``LensReport/describes(_:)`` is that comparison.
        let path = String(trimmed.prefix { $0 != "?" && $0 != "#" })
        return path.hasPrefix("/") ? path : "/" + path
    }
}

// MARK: - Region catalog

extension RegionCatalog {
    /// Cap the candidate list and drop candidates whose selectors are unusable.
    ///
    /// ``Budget/lensRegionCandidateLimit`` is defined as a cap on *these* — the
    /// things the page offers a model — and nothing was applying it here, so a
    /// page with ten thousand divs could hand a model a prompt it would either
    /// refuse or bill for.
    ///
    /// The selector check matters more than the cap. ``knownSelectors`` is the
    /// gate every op's selector is measured against, so a catalog carrying a
    /// malformed selector would *authorise* it: the model would be told that
    /// `#secondary:has(` is a thing this page offers, and validation would agree.
    public func validated() -> RegionCatalog {
        var seen: Set<String> = []
        var kept: [RegionCandidate] = []
        for candidate in candidates {
            guard kept.count < Budget.lensRegionCandidateLimit else { break }
            guard let validated = candidate.validated() else { continue }
            guard seen.insert(validated.id).inserted else { continue }
            kept.append(validated)
        }

        return RegionCatalog(
            origin: origin,
            pathPattern: pathPattern,
            viewport: viewport,
            candidates: kept
        )
    }
}

extension RegionCandidate {
    /// A candidate is only worth offering if something can be said about it in a
    /// selector, so one that loses its preferred selector is dropped whole.
    func validated() -> RegionCandidate? {
        guard
            let id = LensToken.identifier(id),
            let selector = LensToken.regionSelector(selector)
        else { return nil }

        var copy = self
        copy.id = id
        copy.selector = selector
        copy.alternates = alternates.compactMap(LensToken.regionSelector)
        // The item selector is not a region: it is matched inside one, so it gets
        // the shape gate without the breadth limit. `:scope > article.card` is
        // exactly what `regions.ts` produces here.
        copy.itemSelector = itemSelector.flatMap(LensToken.selector)

        // Capped and shape-gated, because this is the part of the catalog a model
        // copies a selector *out of*. A field whose selector could escape the rule
        // it is written into would be handed to the model as a legitimate thing to
        // name, and the model would be right to name it — the gate has to be here,
        // where the page's offer is first believed, not only where the op is
        // checked.
        var fields: [ItemFieldCandidate] = []
        var seen: Set<String> = []
        for field in itemFields {
            guard fields.count < Self.maxItemFields else { break }
            guard let selector = LensToken.selector(field.selector) else { continue }
            // Two entries with one selector are one field described twice: the
            // model would be choosing between identical options and the second is
            // prompt weight spent on nothing.
            guard seen.insert(selector).inserted else { continue }
            fields.append(
                ItemFieldCandidate(
                    selector: selector,
                    tag: LensToken.identifier(field.tag)?.lowercased() ?? "",
                    attributesPresent: Array(
                        field.attributesPresent.compactMap(LensToken.identifier)
                            .map { $0.lowercased() }
                            .prefix(ItemFieldCandidate.maxAttributes)
                    ),
                    // ``ItemPredicate/charBounds`` is already defined as the
                    // plausible character count for one feed item, and this is a
                    // count of characters inside one feed item. Two numbers here
                    // would be two answers to one question.
                    textLength: field.textLength.clamped(to: ItemPredicate.charBounds)
                )
            )
        }
        copy.itemFields = fields
        return copy
    }
}

// MARK: - Token shapes

/// The shapes model output is allowed to take.
///
/// Every string a model writes ends up somewhere consequential: a selector goes
/// into a stylesheet we build, a colour into a declaration, a label into the
/// page. So each has exactly one permitted shape, checked here, and anything
/// else is discarded rather than escaped — escaping is a thing you get subtly
/// wrong once and then ship for a year.
enum LensToken {
    /// Longest selector accepted. Real selectors are short; a long one is
    /// either generated garbage or an attempt to hide something in the middle.
    static let maxSelectorLength = 240
    static let maxIdentifierLength = 48

    /// Substrings that would let a selector escape the rule it is written into:
    /// end it, comment past it, start an at-rule, fetch something, or close the
    /// `<style>` element around it.
    ///
    /// `>` is absent on purpose — it is the child combinator, and the catalog's
    /// own selectors are descendant paths built from it. `,` is absent too, and
    /// that is A2.0: a selector list is a breadth problem, not an escaping one, so
    /// it belongs with the rest of the breadth ban in ``regionSelector(_:)``. A
    /// harvest field is read with `querySelector` *inside one item*, where
    /// `h3, .title` means "whichever of these this card uses" — which is how a
    /// real feed is marked up, and which the shared list was rejecting.
    ///
    /// `\` used to be here too, and that was wrong. A blanket ban rejects every
    /// escaped utility class — `.md\:flex`, `.w-1\/2`, `.text-\[13px\]` — which
    /// is a large fraction of the modern web and exactly the kind of site people
    /// want to lens. Escapes are checked by shape instead, in
    /// ``escapesAreLiteral(_:)``.
    private static let forbidden = ["url(", ";", "/*", "*/", "{", "}", "<", "@"]

    /// Selectors that plainly *are* the whole page.
    ///
    /// `hide` on `html` is otherwise a perfectly legal lens that blanks every
    /// visit to a site, which is §1's no-flash promise inverted into a permanent
    /// one. A lens names a *part* of a page; if it cannot, there is nothing for
    /// it to be reversible about.
    ///
    /// Written out literally rather than parsed — see ``isUnbounded(_:)`` for why
    /// that is now enough.
    private static let pageRoots: Set<String> = ["*", "html", "body", ":root", ":scope"]

    /// `#rrggbb`, lowercase-or-uppercase hex, and nothing else.
    ///
    /// The shape check is the whole defence: a string matching `^#[0-9a-fA-F]{6}$`
    /// cannot contain `url(`, `;`, `/*`, `@import` or `expression`, so there is
    /// no separate blocklist to keep in step with it.
    static func colour(_ value: String) -> String? {
        guard value.count == 7, value.hasPrefix("#") else { return nil }
        let digits = value.dropFirst()
        guard digits.allSatisfy(\.isHexDigit), digits.allSatisfy(\.isASCII) else { return nil }
        return value.lowercased()
    }

    /// A CSS selector that cannot escape the rule it is written into and cannot
    /// swallow the rules after it.
    ///
    /// This is the *shape* gate, and it applies to every selector a lens carries.
    /// It deliberately says nothing about breadth — see ``regionSelector(_:)``
    /// for that — because an item selector is evaluated against one element, not
    /// against the document, and the catalog's own item selectors are
    /// `:scope > article.card`.
    static func selector(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxSelectorLength else { return nil }
        guard !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }

        // Literal, case-folded search. Collating comparison can treat runs of
        // punctuation as equivalent, and every needle here is punctuation.
        let lowered = trimmed.lowercased()
        for needle in forbidden where lowered.range(of: needle, options: .literal) != nil {
            return nil
        }

        guard escapesAreLiteral(trimmed) else { return nil }
        guard isBalanced(trimmed) else { return nil }

        // `expression(` is the IE-era arbitrary-JavaScript hole, and it is banned
        // as a *function call* rather than as a substring: the raw substring ban
        // also rejected `.expression-editor`, an ordinary class on an ordinary
        // page, and a validator that fails on legitimate markup gets loosened by
        // whoever hits it next.
        //
        // Checked with the escapes resolved as well as without. `expression\(` is
        // not a function call — CSS reads the escape as a literal character, which
        // is why it was never exploitable in selector position — but a check that
        // one backslash steps around is a check nobody can reason about, and this
        // is the exact check the last review asked to tighten.
        for form in [lowered, unescaped(lowered)] {
            if form.range(of: "expression[[:space:]]*\\(", options: .regularExpression) != nil {
                return nil
            }
        }
        return trimmed
    }

    /// A selector naming a *region* — something a rule in our stylesheet will be
    /// written against, at document scope.
    ///
    /// The shape gate plus a breadth limit, and the breadth limit lives here and
    /// nowhere else. `hide` on `html` is otherwise a legal lens that blanks every
    /// visit to a site, which is §1's no-flash promise inverted into a permanent
    /// one; a region is a *part* of a page, or there is nothing for the lens to
    /// be reversible about.
    ///
    /// Item and field selectors do **not** go through here. `:scope > li` is what
    /// `regions.ts` generates for a feed's rows and what `harvest.ts` reads a
    /// field from, so banning `:scope` at that level would silently disable every
    /// `filter`, `reorder` and `harvest` op ever written.
    static func regionSelector(_ value: String) -> String? {
        guard let safe = selector(value) else { return nil }
        // A region is one thing. A selector list is a way to smuggle a second,
        // broader subject into a rule authored for the first — `#feed, body` is
        // the whole attack in five characters — so the comma is banned here with
        // the rest of the breadth rules rather than in the shared shape gate.
        guard !safe.contains(",") else { return nil }
        return isUnbounded(safe) ? nil : safe
    }

    /// A `\` may only introduce a *literal* escape: one punctuation character
    /// that CSS would otherwise read as syntax.
    ///
    /// That is how Tailwind spells `.md\:flex` and `.w-1\/2`, so it has to be
    /// allowed. A `\` followed by a hex digit is a *unicode* escape, and that is
    /// how a forbidden token gets past a literal search — `\75 rl(` is `url(`
    /// spelled so that nothing searching for `url(` finds it. A `\` before
    /// whitespace, or at the very end, is the same trick with the digits supplied
    /// by whatever the selector is concatenated with.
    private static func escapesAreLiteral(_ value: String) -> Bool {
        let characters = Array(value)
        var index = 0
        while index < characters.count {
            guard characters[index] == "\\" else {
                index += 1
                continue
            }
            guard index + 1 < characters.count else { return false }
            let next = characters[index + 1]
            guard next.isASCII, !next.isHexDigit, next.isPunctuation || next.isSymbol else {
                return false
            }
            index += 2
        }
        return true
    }

    /// Do `()`, `[]` and quotes close?
    ///
    /// This is the difference between a lens that hides one rail and a lens that
    /// silently disables itself. `#secondary:has(` passes every substring check
    /// above and compiles to `#secondary:has( { display:none }`; per CSS Syntax
    /// §5.4.8 the unclosed block then consumes every rule after it to the end of
    /// the sheet. Each later CSS op does nothing at all while the structural pass
    /// still resolves its selector and reports `applied` — so the drift badge
    /// says the lens fits perfectly, and the page says otherwise.
    private static func isBalanced(_ value: String) -> Bool {
        var parens = 0
        var brackets = 0
        var quote: Character?
        var escaped = false

        for character in value {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if let open = quote {
                if character == open { quote = nil }
                continue
            }

            switch character {
            case "\"", "'": quote = character
            case "(": parens += 1
            case ")":
                parens -= 1
                if parens < 0 { return false }
            case "[": brackets += 1
            case "]":
                brackets -= 1
                if brackets < 0 { return false }
            default: break
            }
        }

        return parens == 0 && brackets == 0 && quote == nil && !escaped
    }

    /// Does this selector name the whole page, plainly?
    ///
    /// A literal check, and a deliberately small one. It used to be a 230-line
    /// hand-rolled CSS parser: it found the subject compound, broke it into simple
    /// selectors, and decided whether anything in it *narrowed* — so that
    /// `:is(body)`, `*:not(.keep)`, `body.dark` and `body:not(#nope)` were all
    /// caught as the page-blanking selectors they are. That work was load-bearing
    /// for exactly one caller: a lens file validated with no catalog at all, so
    /// shape was the only gate a hostile file ever met.
    ///
    /// That caller is gone. Every region selector a model or an editor can produce is
    /// now measured against ``RegionCatalog/knownSelectors`` — a set built from
    /// what the live page actually offered — and no real page offers `:is(body)`
    /// as an anchor. A parser that agrees with the browser about what
    /// `.text-\[13px\]` means is a genuinely hard thing to keep correct, and
    /// keeping it correct to re-check something the catalog already refuses is the
    /// definition of weight nobody is carrying.
    ///
    /// What is left is belt-and-braces for the one path that still validates with
    /// no catalog: a lens read back off disk. That file is the user's own, so the
    /// threat is a typo or an old build rather than an attacker — and the literal
    /// spellings are what a typo produces.
    private static func isUnbounded(_ value: String) -> Bool {
        pageRoots.contains(value.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// The string with its literal escapes resolved, for checks that must not be
    /// steppable past by one backslash. Only meaningful after
    /// ``escapesAreLiteral(_:)`` has agreed every `\` is followed by exactly one
    /// character.
    private static func unescaped(_ value: String) -> String {
        var result = ""
        var escaped = false
        for character in value {
            if escaped {
                result.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            result.append(character)
        }
        return result
    }

    /// A selector for *one repeated item*, which must also be one the page
    /// actually offered.
    ///
    /// The comma is refused here, and for a different reason than in
    /// ``regionSelector(_:)``: not breadth, but the runner's failure mode. When
    /// `ops.ts` cannot parse an item selector it falls back to the region's own
    /// element children, so a `drop` filter that was written as "the cards
    /// matching X" quietly becomes "everything directly inside this region" — the
    /// exact degradation A1.2 made this function drop the whole op over. Until the
    /// TypeScript shape gate accepts a list, handing it one is handing it a
    /// selector it will silently not use.
    static func pageSelector(_ value: String?, knownSelectors: Set<String>?) -> String? {
        guard let value, let safe = selector(value), !safe.contains(",") else { return nil }
        if let knownSelectors, !knownSelectors.contains(safe) { return nil }
        return safe
    }

    /// A bare name: harvest buckets, harvest field names, region ids. These are
    /// only ever compared to each other, so the alphabet can be tiny.
    static func identifier(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxIdentifierLength else { return nil }
        let allowed = trimmed.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
        return allowed ? trimmed : nil
    }

    /// Prose destined for a UI chip or a text node: length-capped, with control
    /// characters removed so it cannot disturb the layout it labels.
    static func plainText(_ value: String, limit: Int) -> String {
        let stripped = value.unicodeScalars.filter { scalar in
            scalar == " " || scalar.properties.generalCategory != .control
        }
        // Truncate, *then* trim. The other order lets the cut reintroduce
        // trailing whitespace, so a second pass produces a different string —
        // and validation runs on the model's answer, again on save, and again on
        // load, so a step that is not idempotent means a stored lens quietly
        // stops being the lens the user previewed. Leading whitespace goes first
        // because dropping it cannot be undone by a later truncation.
        return String(
            String(String.UnicodeScalarView(stripped))
                .drop(while: { $0.isWhitespace })
                .prefix(limit)
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension Double {
    /// Clamp, rejecting anything that is not a finite number.
    ///
    /// The shared `Double.clamped(to:)` passes `NaN` straight through — `min` and
    /// `max` both return it — so a `fraction` of `NaN` would survive validation
    /// and reach the stylesheet compiler as `NaN%`. Returning `nil` instead makes
    /// the op fail the "defined by one field" check and be dropped, which is the
    /// right answer: there is no sensible width to repair a non-number to.
    func clampedFinite(to range: ClosedRange<Double>) -> Double? {
        guard isFinite else { return nil }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
