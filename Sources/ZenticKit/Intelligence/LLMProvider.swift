import Foundation

/// A source of language-model capability.
///
/// Three implementations sit behind this: on-device Foundation Models (the
/// default and the free tier), a hosted cloud route (premium), and a
/// bring-your-own-key route. The pipeline never names one directly — it asks
/// ``ProviderRouter`` for whatever is currently available at the highest tier
/// the user is entitled to.
public protocol LLMProvider: Sendable {
    /// Stable identifier, e.g. `"apple.foundation-models"`.
    var identifier: String { get }
    var tier: ProviderTier { get }

    /// Whether this provider can serve a request right now. On-device models can
    /// be unavailable for reasons that have nothing to do with our code — device
    /// not eligible, Apple Intelligence off, model still downloading, low power
    /// mode — so this is async and must be re-checked rather than cached forever.
    func availability() async -> ProviderAvailability

    /// Re-voice prose. Emits events as work completes so the reader can render
    /// progressively; cancelling the iterating task cancels the generation.
    ///
    /// Implementations must skip any section where
    /// ``SectionKind/isRewritable`` is false rather than trusting the caller.
    func rewrite(_ request: RewriteRequest) -> AsyncThrowingStream<RewriteEvent, any Error>

    /// Infer an extraction recipe from a page's structure.
    ///
    /// The skeleton carries no page text by construction — see ``DOMSkeleton``.
    func inferRecipe(from skeleton: DOMSkeleton) async throws -> SiteRecipe

    /// Turn a description of a look — "like Apple's docs", "1997 GeoCities",
    /// "high-contrast newsprint" — into presentation tokens.
    ///
    /// Returns ``ThemeTokens`` and never CSS; see that type for why the boundary
    /// matters. Callers must run ``ThemeTokens/validated()`` on the result before
    /// rendering, since a model can produce in-range-looking values that are still
    /// illegible together.
    ///
    /// This is off the hot path: a theme is generated once from a prompt and then
    /// reused across every page, so it never costs anything per pageview.
    func generateTheme(from prompt: String) async throws -> ThemeTokens

    /// Lay the page out as markup, rather than as tokens over our own layout.
    ///
    /// The heavier half of redesign, and the only place a model authors HTML.
    /// Providers that cannot do it usefully decline (see the default below) —
    /// a full page is a long, structured generation, and a small on-device model
    /// producing half a document is worse than one that says no.
    ///
    /// The result is sanitised by the caller before it reaches a page; see
    /// ``GeneratedHTML``. Non-rewritable sections are never in the request and
    /// come back as placeholders, so invariant 3 holds here too.
    func generateDocument(_ request: DocumentRequest) async throws -> GeneratedDocument

    /// Author lens ops from the user's words plus a textless ``RegionCatalog``.
    ///
    /// The model sees where things are on the page and how big they are, never what
    /// they say — invariant 4 — and it authors *ops*, never markup, CSS or a
    /// selector of its own invention. Implementations must return
    /// ``LensProposal/validated(against:)`` output: the trust boundary belongs to
    /// the provider, so a caller cannot forget to cross it.
    func generateLens(_ request: LensRequest) async throws -> LensProposal

    /// Re-derive selectors for a lens whose regions stopped matching.
    ///
    /// The recovery path for drift. The site redesigned, the stored selectors match
    /// nothing, and the durable half of each region — its ``LensRegion/intent`` —
    /// goes back to a model with a fresh catalog. The ops are untouched: the user
    /// asked for the suggestions rail to go away, and that has not changed just
    /// because its class names did.
    func refitLens(_ request: LensRefitRequest) async throws -> [LensRegion]
}

extension LLMProvider {
    public func generateDocument(_ request: DocumentRequest) async throws -> GeneratedDocument {
        throw LLMError.providerFailed(
            identifier: identifier,
            message: "This model does not generate full page layouts. Choose OpenAI in View ▸ Design Model."
        )
    }

    /// Decline, rather than half-answer.
    ///
    /// Authoring ops is a long structured generation over a hundred candidates, and
    /// a small on-device model that returns three plausible ops naming two regions
    /// that do not exist produces a lens which appears to work and rearranges the
    /// wrong things. A refusal the user can act on is strictly better.
    public func generateLens(_ request: LensRequest) async throws -> LensProposal {
        throw LLMError.providerFailed(
            identifier: identifier,
            message: "This model does not author lenses. Choose OpenAI in View ▸ Design Model."
        )
    }

    public func refitLens(_ request: LensRefitRequest) async throws -> [LensRegion] {
        throw LLMError.providerFailed(
            identifier: identifier,
            message: "This model cannot re-fit a lens. Choose OpenAI in View ▸ Design Model."
        )
    }
}

// MARK: - Lens requests

/// Everything a model is given to author a lens: the user's words, and a map of
/// the page with the words taken out.
public struct LensRequest: Sendable, Hashable {
    /// The page, textless. See ``RegionCatalog`` — this is the only thing about the
    /// page that ever leaves the device.
    public var catalog: RegionCatalog
    /// What the user typed, verbatim. Also the source of every `filter` term: the
    /// model expands the user's own vocabulary, never the page's.
    public var prompt: String
    /// Regions the user clicked before typing. A strong hint, not a constraint —
    /// people point at the header and mean the nav inside it.
    public var selectedRegionIDs: [String]
    /// Regions an existing lens already declares, when this is an edit. Reusing an
    /// id keeps the ops that already name it working.
    public var existingRegions: [LensRegion]

    public init(
        catalog: RegionCatalog,
        prompt: String,
        selectedRegionIDs: [String] = [],
        existingRegions: [LensRegion] = []
    ) {
        self.catalog = catalog
        self.prompt = prompt
        self.selectedRegionIDs = selectedRegionIDs
        self.existingRegions = existingRegions
    }
}

/// A drifted lens and a fresh view of the page it drifted on.
public struct LensRefitRequest: Sendable, Hashable {
    public var catalog: RegionCatalog
    /// The regions to re-derive. Their ``LensRegion/intent`` is the whole input;
    /// the selectors in them are the ones that stopped working.
    public var regions: [LensRegion]

    public init(catalog: RegionCatalog, regions: [LensRegion]) {
        self.catalog = catalog
        self.regions = regions
    }
}

public enum ProviderTier: String, Codable, Sendable, Comparable, CaseIterable {
    case onDevice
    case byoKey
    case cloud

    private var rank: Int {
        switch self {
        case .onDevice: 0
        case .byoKey: 1
        case .cloud: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public enum ProviderAvailability: Sendable, Equatable {
    case available
    /// Temporarily unusable but may recover; the router may retry later.
    case unavailable(reason: String)
    /// Permanently unusable on this device or configuration; do not retry.
    case ineligible(reason: String)

    public var isAvailable: Bool { self == .available }
}

// MARK: - Rewrite request

public struct RewriteRequest: Sendable, Hashable {
    /// Sections to rewrite. Callers should pass
    /// ``ExtractionResult/rewritableSections``; providers filter again regardless.
    public var sections: [ContentSection]
    public var tone: Tone
    public var length: LengthPreference
    public var readingLevel: ReadingLevel?
    /// Title and site name, so the model has framing without needing the full page.
    public var context: RewriteContext

    public init(
        sections: [ContentSection],
        tone: Tone,
        length: LengthPreference,
        readingLevel: ReadingLevel? = nil,
        context: RewriteContext
    ) {
        self.sections = sections
        self.tone = tone
        self.length = length
        self.readingLevel = readingLevel
        self.context = context
    }
}

public struct RewriteContext: Sendable, Hashable, Codable {
    public var title: String
    public var siteName: String?
    public var lang: String?

    public init(title: String, siteName: String? = nil, lang: String? = nil) {
        self.title = title
        self.siteName = siteName
        self.lang = lang
    }
}

public enum Tone: Sendable, Hashable, Codable {
    case neutral
    case plain
    case concise
    case friendly
    case formal
    case technical
    /// User-authored instruction, e.g. "explain like I'm new to the topic".
    case custom(String)
}

public enum LengthPreference: String, Sendable, Hashable, Codable, CaseIterable {
    /// Re-voice without changing length.
    case asIs
    case shorter
    case brief
    case bullets
    /// Expand with explanation. Never adds facts — only unpacks what is present.
    case expanded
}

public enum ReadingLevel: String, Sendable, Hashable, Codable, CaseIterable {
    case simple
    case general
    case expert
}

/// Incremental output from a rewrite.
public enum RewriteEvent: Sendable, Hashable {
    /// A chunk of rewritten Markdown for one section. Deltas accumulate; the
    /// final event for a section carries `isFinal`.
    case patch(RewritePatch)
    /// Provider declined this section (e.g. its safety filter tripped). The
    /// reader keeps the original text for it rather than showing a gap.
    case skipped(sectionID: String, reason: String)
    case finished
}

/// Failures the rewrite layer surfaces to the UI.
public enum LLMError: Error, Sendable, Equatable {
    case noProviderAvailable
    case notEntitled(tier: ProviderTier)
    case contextTooLarge(sectionID: String)
    case providerFailed(identifier: String, message: String)
    /// The model returned something that did not satisfy the requested schema
    /// after retries. Relevant to recipe inference, which is structured output.
    case malformedOutput(String)
    case cancelled
}
