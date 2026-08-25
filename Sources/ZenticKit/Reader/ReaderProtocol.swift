import Foundation

// MARK: - Page → app

/// Something the injected bundle reports to the app.
///
/// Encoded as `{"v": 1, "type": "<tag>", "payload": {…}}`. The tagged shape is
/// hand-rolled rather than synthesised because Swift's default enum encoding
/// produces `{"extracted": {…}}`, which is awkward to construct and switch on
/// from TypeScript. The wire format is a contract with the bundle, so it is
/// written out explicitly.
public enum ReaderEvent: Sendable, Hashable {
    /// Bundle booted and is ready for commands.
    case ready(ReadyPayload)
    /// Extraction finished. The app decides whether to render or pass through.
    case extracted(ExtractionResult)
    /// No usable recipe; here is the page's shape so one can be inferred.
    case needsRecipe(DOMSkeleton)
    /// The original page is now visible, for the given reason.
    case revealed(RevealPayload)
    /// A pipeline stage failed. The bundle has already revealed the page.
    case failed(ReaderFailure)
    /// One report per active lens, after every op pass — including the passes
    /// that follow an SPA navigation, since drift shows up on the second view.
    case lensReport([LensReport])
    /// The textless catalog of things a lens could act on, in reply to
    /// ``ReaderCommand/requestRegions``.
    case lensRegions(RegionCatalog)
    /// The user typed a prompt in the in-page lens editor.
    case lensPrompt(LensPromptRequest)
    /// The user pressed Save in the editor. The app persists this.
    case lensDraft(Lens)
    /// The editor overlay opened or closed, so the app can sync menu state.
    case lensModeChanged(Bool)

    private enum Tag: String, Codable {
        case ready, extracted, needsRecipe, revealed, failed
        case lensReport, lensRegions, lensPrompt, lensDraft, lensModeChanged
    }

    private enum CodingKeys: String, CodingKey {
        case v, type, payload
    }
}

public struct ReadyPayload: Codable, Sendable, Hashable {
    public var bundleVersion: String
    public var url: String

    public init(bundleVersion: String, url: String) {
        self.bundleVersion = bundleVersion
        self.url = url
    }
}

public struct RevealPayload: Codable, Sendable, Hashable {
    public var reason: RevealReason
    /// Wall-clock milliseconds from injection to reveal. Used locally to spot a
    /// rising ``RevealReason/failsafe`` rate, which means extraction is too slow
    /// or a recipe has rotted. Never transmitted anywhere.
    public var elapsedMs: Int

    public init(reason: RevealReason, elapsedMs: Int) {
        self.reason = reason
        self.elapsedMs = elapsedMs
    }
}

public struct ReaderFailure: Codable, Sendable, Hashable, Error {
    public var stage: String
    public var message: String

    public init(stage: String, message: String) {
        self.stage = stage
        self.message = message
    }
}

extension ReaderEvent: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let version = try container.decode(Int.self, forKey: .v)
        guard version == ZenticCoding.wireVersion else {
            throw ReaderBridgeError.unsupportedWireVersion(
                received: version,
                expected: ZenticCoding.wireVersion
            )
        }

        switch try container.decode(Tag.self, forKey: .type) {
        case .ready:
            self = .ready(try container.decode(ReadyPayload.self, forKey: .payload))
        case .extracted:
            self = .extracted(try container.decode(ExtractionResult.self, forKey: .payload))
        case .needsRecipe:
            self = .needsRecipe(try container.decode(DOMSkeleton.self, forKey: .payload))
        case .revealed:
            self = .revealed(try container.decode(RevealPayload.self, forKey: .payload))
        case .failed:
            self = .failed(try container.decode(ReaderFailure.self, forKey: .payload))
        case .lensReport:
            self = .lensReport(try container.decode([LensReport].self, forKey: .payload))
        case .lensRegions:
            self = .lensRegions(try container.decode(RegionCatalog.self, forKey: .payload))
        case .lensPrompt:
            self = .lensPrompt(try container.decode(LensPromptRequest.self, forKey: .payload))
        case .lensDraft:
            self = .lensDraft(try container.decode(Lens.self, forKey: .payload))
        case .lensModeChanged:
            self = .lensModeChanged(try container.decode(Bool.self, forKey: .payload))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ZenticCoding.wireVersion, forKey: .v)

        switch self {
        case .ready(let payload):
            try container.encode(Tag.ready, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .extracted(let payload):
            try container.encode(Tag.extracted, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .needsRecipe(let payload):
            try container.encode(Tag.needsRecipe, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .revealed(let payload):
            try container.encode(Tag.revealed, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .failed(let payload):
            try container.encode(Tag.failed, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .lensReport(let payload):
            try container.encode(Tag.lensReport, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .lensRegions(let payload):
            try container.encode(Tag.lensRegions, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .lensPrompt(let payload):
            try container.encode(Tag.lensPrompt, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .lensDraft(let payload):
            try container.encode(Tag.lensDraft, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .lensModeChanged(let payload):
            try container.encode(Tag.lensModeChanged, forKey: .type)
            try container.encode(payload, forKey: .payload)
        }
    }
}

// MARK: - App → page

/// Something the app asks the injected bundle to do.
public enum ReaderCommand: Sendable, Hashable {
    /// Install or replace the recipe for the current page and re-extract.
    case applyRecipe(SiteRecipe)
    /// Switch between the restructured view and the original document.
    case setMode(ReaderMode)
    /// Move the live page to a level.
    ///
    /// Distinct from ``setMode`` rather than folded into it, because the bundle
    /// caches what it is *permitted* to do at load time — whether it may render at
    /// all, whether it may answer a cookie wall. `setMode` can only ask for a
    /// rendering, so a page that loaded below Reader would take the mode change,
    /// run the pipeline, and then decline to render because its cached permission
    /// still said no. This carries the permission with the request.
    case setLevel(PageLevel)
    /// Ask for a ``DOMSkeleton`` so a recipe can be inferred.
    case requestSkeleton
    /// Replace one section's prose with rewritten text. Streamed, so this
    /// arrives repeatedly per section until `isFinal`.
    case applyRewrite(RewritePatch)
    /// Discard any rewrite and restore extracted text.
    case discardRewrite
    /// Restyle the current view. Purely presentational and instant — no
    /// re-extraction, no model call, no reload.
    case applyTheme(ReaderTheme)
    /// Replace the reading view with a model-authored rendering of this page.
    /// Sanitised before it is sent; see ``GeneratedDocument``.
    case applyDocument(GeneratedDocument)
    /// Replace the active lens set and re-run the op pass. Sent when a lens is
    /// saved, deleted or switched on or off — the bootstrap configuration covers
    /// the first load, this covers everything after it.
    case applyLenses([Lens])
    /// Show the in-page lens editor overlay. See ``LensEditRequest``.
    case enterLensMode(LensEditRequest?)
    case exitLensMode
    /// Preview a model's answer to a prompt. Ops are *highlighted*, not applied:
    /// prompt-straight-to-effect would let one bad selector rearrange a page the
    /// user then has to reverse-engineer.
    case proposeOps(LensProposal)
    /// Ask for a ``RegionCatalog`` for the current page.
    case requestRegions

    private enum Tag: String, Codable {
        case applyRecipe, setMode, setLevel, requestSkeleton, applyRewrite, discardRewrite
        case applyTheme, applyDocument
        case applyLenses, enterLensMode, exitLensMode, proposeOps, requestRegions
    }

    private enum CodingKeys: String, CodingKey {
        case v, type, payload
    }
}

public enum ReaderMode: String, Codable, Sendable {
    /// Zentic's rendering, in a shadow root, with the original document hidden.
    case restructured
    /// The site's own rendering. The original DOM is only ever hidden, never
    /// destroyed, so this is instant and needs no reload.
    case original
}

public struct RewritePatch: Codable, Sendable, Hashable {
    public var sectionID: String
    public var markdown: String
    /// False while streaming, true on the last chunk for this section.
    public var isFinal: Bool

    public init(sectionID: String, markdown: String, isFinal: Bool) {
        self.sectionID = sectionID
        self.markdown = markdown
        self.isFinal = isFinal
    }
}

/// A model's answer to a lens prompt: the ops, plus the regions they are allowed
/// to name.
///
/// Regions travel with the ops rather than being looked up later because they
/// *are* the validation vocabulary — ``LensProposal/validated(against:)`` checks
/// every op against this list, and a proposal that referenced regions defined
/// somewhere else could not be checked in one place.
public struct LensProposal: Codable, Sendable, Hashable {
    public var regions: [LensRegion]
    public var ops: [LensOp]
    /// One sentence describing what this would do, shown on the confirm step.
    public var note: String

    public init(regions: [LensRegion], ops: [LensOp], note: String) {
        self.regions = regions
        self.ops = ops
        self.note = note
    }
}

/// What the in-page editor sends when the user asks for something.
///
/// The catalog rides along rather than being re-derived in the app: it was
/// built from the live post-JavaScript DOM, which the app cannot see.
public struct LensPromptRequest: Codable, Sendable, Hashable {
    public var text: String
    /// Regions the user clicked before typing. A strong hint, not a constraint.
    public var selectedRegionIDs: [String]
    public var catalog: RegionCatalog

    public init(text: String, selectedRegionIDs: [String], catalog: RegionCatalog) {
        self.text = text
        self.selectedRegionIDs = selectedRegionIDs
        self.catalog = catalog
    }
}

extension ReaderCommand: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let version = try container.decode(Int.self, forKey: .v)
        guard version == ZenticCoding.wireVersion else {
            throw ReaderBridgeError.unsupportedWireVersion(
                received: version,
                expected: ZenticCoding.wireVersion
            )
        }

        switch try container.decode(Tag.self, forKey: .type) {
        case .applyRecipe:
            self = .applyRecipe(try container.decode(SiteRecipe.self, forKey: .payload))
        case .setMode:
            self = .setMode(try container.decode(ReaderMode.self, forKey: .payload))
        case .setLevel:
            self = .setLevel(try container.decode(PageLevel.self, forKey: .payload))
        case .requestSkeleton:
            self = .requestSkeleton
        case .applyRewrite:
            self = .applyRewrite(try container.decode(RewritePatch.self, forKey: .payload))
        case .discardRewrite:
            self = .discardRewrite
        case .applyTheme:
            self = .applyTheme(try container.decode(ReaderTheme.self, forKey: .payload))
        case .applyDocument:
            self = .applyDocument(try container.decode(GeneratedDocument.self, forKey: .payload))
        case .applyLenses:
            self = .applyLenses(try container.decode([Lens].self, forKey: .payload))
        case .enterLensMode:
            self = .enterLensMode(
                try container.decodeIfPresent(LensEditRequest.self, forKey: .payload)
            )
        case .exitLensMode:
            self = .exitLensMode
        case .proposeOps:
            self = .proposeOps(try container.decode(LensProposal.self, forKey: .payload))
        case .requestRegions:
            self = .requestRegions
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ZenticCoding.wireVersion, forKey: .v)

        switch self {
        case .applyRecipe(let payload):
            try container.encode(Tag.applyRecipe, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .setMode(let payload):
            try container.encode(Tag.setMode, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .setLevel(let payload):
            try container.encode(Tag.setLevel, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .requestSkeleton:
            try container.encode(Tag.requestSkeleton, forKey: .type)
        case .applyRewrite(let payload):
            try container.encode(Tag.applyRewrite, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .discardRewrite:
            try container.encode(Tag.discardRewrite, forKey: .type)
        case .applyTheme(let payload):
            try container.encode(Tag.applyTheme, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .applyDocument(let payload):
            try container.encode(Tag.applyDocument, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .applyLenses(let payload):
            try container.encode(Tag.applyLenses, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .enterLensMode(let payload):
            try container.encode(Tag.enterLensMode, forKey: .type)
            // The key is omitted entirely when there is nothing to say, so authoring
            // stays byte-identical to the command the bundle has always received.
            try container.encodeIfPresent(payload, forKey: .payload)
        case .exitLensMode:
            try container.encode(Tag.exitLensMode, forKey: .type)
        case .proposeOps(let payload):
            try container.encode(Tag.proposeOps, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .requestRegions:
            try container.encode(Tag.requestRegions, forKey: .type)
        }
    }
}

/// Which lens the in-page editor is being opened on, if any.
///
/// The distinction between authoring and editing is load-bearing, not a
/// convenience. An editor that adopts every applied lens into one draft saves a
/// *third* lens holding all of their ops, leaving the originals enabled and every
/// op running twice; past the per-lens op cap ``Lens/validated()`` then truncates
/// the rest without saying so. So authoring adopts nothing, and editing adopts the
/// one named lens and carries its id back on the draft — which is what tells
/// ``LensStore/save(draft:origin:)`` to replace that record rather than insert
/// beside it.
///
/// A struct rather than a bare string because this is the payload of the only
/// command the editor is opened with, and the next thing it needs to be told
/// should not be another wire case.
public struct LensEditRequest: Codable, Sendable, Hashable {
    /// Id of the lens to load as the draft. Nil — or absent — means a new lens.
    public var editing: String?

    public init(editing: String? = nil) {
        self.editing = editing
    }
}

// MARK: - Bootstrap configuration

/// State the bundle needs *before* it decides whether to hide the page.
///
/// This cannot be delivered as a command: commands are asynchronous and arrive
/// after `atDocumentStart`, by which point the page has already painted. So it
/// is serialised into a bootstrap user script that runs ahead of the bundle.
/// See ``ReaderBridge/updateConfiguration(_:)``.
public struct ReaderConfiguration: Codable, Sendable, Hashable {
    /// How much this page may be transformed. Decides whether the bundle hides the
    /// document, dismisses a cookie wall, or runs the pipeline at all.
    ///
    /// ``mode`` remains separate because it is the *transient* state ⌘\ toggles —
    /// a peek at the original that survives until the next navigation. The two
    /// cannot disagree, though: ``init`` clamps `mode` to `.original` whenever the
    /// level is below `.reader`, so "restructured at level Clean" is unrepresentable
    /// rather than merely discouraged.
    public var level: PageLevel { didSet { clampMode() } }
    public var mode: ReaderMode { didSet { clampMode() } }

    /// Keeps ``mode`` inside what ``level`` permits, on every write.
    ///
    /// The clamp used to live only in `init`, which made it advisory: both
    /// properties are `var`, and the mode is edited in place on every ⌘\ — so a peek
    /// at a page below Reader could leave a configuration claiming a rendering that
    /// cannot exist. Re-entry terminates because the second pass finds nothing to
    /// change.
    private mutating func clampMode() {
        let clamped: ReaderMode = level.readerMode == .original ? .original : mode
        if clamped != mode { mode = clamped }
    }
    /// Presentation tokens for the restructured view. Part of the bootstrap
    /// rather than a command so the first paint is already correctly styled.
    public var theme: ReaderTheme
    /// Recipe for the page about to load, when one is already known.
    public var recipe: SiteRecipe?
    /// Origins that must never be restructured, from the bundled deny-list plus
    /// the user's own opt-outs.
    public var passthroughOrigins: Set<String>
    /// Origins the app has learned do not get restructured, so their pages are
    /// left visible from the first paint instead of hidden while the reader works.
    ///
    /// Distinct from ``passthroughOrigins``, and deliberately so: that set is a
    /// *policy* — never restructure these — whereas this one is only a performance
    /// prior. The pipeline still runs on an instant origin, so the app keeps
    /// learning and a site that starts publishing is picked back up.
    public var instantOrigins: Set<String>
    public var revealFailsafeMs: Int
    public var settleQuietPeriodMs: Int
    public var settleCeilingMs: Int
    public var minConfidence: Double
    public var minWordCount: Int
    public var skeletonNodeLimit: Int
    /// Lenses matching the page about to load, newest edit first.
    ///
    /// Part of the bootstrap for the same reason the theme is: the `hide` and
    /// `restyle` ops compile to a stylesheet that has to exist at
    /// `document-start`, or the user watches the sidebar they removed paint and
    /// then vanish.
    ///
    /// Seven lens budgets used to ride alongside this — pass ceiling, debounce,
    /// item cap, op cap and so on. Every one was assigned from ``Budget`` and
    /// nothing else ever set them, while `web/src/lens/index.ts` declared its own
    /// copy of all seven and fell back to it per field. So they were compile-time
    /// constants, serialised into a bootstrap script, to arrive at the value the
    /// receiver already had. The TypeScript side keeps its copy; this side keeps
    /// ``Budget``; neither has to stay in step with the other, because neither
    /// reads the other.
    public var lenses: [Lens]
    /// Emit verbose stage timings to the JS console.
    public var debugLogging: Bool

    public init(
        level: PageLevel = .reader,
        mode: ReaderMode = .restructured,
        theme: ReaderTheme = .zentic,
        recipe: SiteRecipe? = nil,
        passthroughOrigins: Set<String> = [],
        instantOrigins: Set<String> = [],
        revealFailsafeMs: Int = Int(Budget.revealFailsafe.milliseconds),
        settleQuietPeriodMs: Int = Int(Budget.settleQuietPeriod.milliseconds),
        settleCeilingMs: Int = Int(Budget.settleCeiling.milliseconds),
        minConfidence: Double = Budget.minConfidence,
        minWordCount: Int = Budget.minWordCount,
        skeletonNodeLimit: Int = Budget.skeletonNodeLimit,
        lenses: [Lens] = [],
        debugLogging: Bool = false
    ) {
        self.level = level
        // The clamp, applied here so no call site can construct the contradiction.
        // A page at Clean has not been hidden and has no overlay to show, so a
        // `mode` of `.restructured` would describe a rendering that cannot exist.
        self.mode = level.readerMode == .original ? .original : mode
        self.theme = theme
        self.recipe = recipe
        self.passthroughOrigins = passthroughOrigins
        self.instantOrigins = instantOrigins
        self.revealFailsafeMs = revealFailsafeMs
        self.settleQuietPeriodMs = settleQuietPeriodMs
        self.settleCeilingMs = settleCeilingMs
        self.minConfidence = minConfidence
        self.minWordCount = minWordCount
        self.skeletonNodeLimit = skeletonNodeLimit
        self.lenses = lenses
        self.debugLogging = debugLogging
    }
}

extension Duration {
    /// Whole milliseconds, for handing budgets to JavaScript.
    public var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }
}
