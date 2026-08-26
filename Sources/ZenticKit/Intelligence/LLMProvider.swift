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
            message: """
                Laying out a whole page is a long, structured generation and past what \
                this model does well — half a document is worse than a refusal. \
                Zentic routes these to the cloud model; View ▸ Model is where \
                OpenAI is chosen, and where its key goes.
                """
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
            message: """
                Authoring a lens is a long, structured generation and past what \
                this model does well — half a document is worse than a refusal. \
                Zentic routes these to the cloud model; View ▸ Model is where \
                OpenAI is chosen, and where its key goes.
                """
        )
    }

    public func refitLens(_ request: LensRefitRequest) async throws -> [LensRegion] {
        throw LLMError.providerFailed(
            identifier: identifier,
            message: """
                Re-fitting a lens is a long, structured generation and past what \
                this model does well — half a document is worse than a refusal. \
                Zentic routes these to the cloud model; View ▸ Model is where \
                OpenAI is chosen, and where its key goes.
                """
        )
    }
}

// MARK: - Routing

/// One piece of model work, described by its **shape** rather than by who asked
/// for it.
///
/// The shape is the whole input to ``ModelRouting``, which is the point: routing
/// used to be a switch in the View menu that the user had to maintain, so the
/// everyday case paid for the heavy one. What decides is what the work *is*.
public enum ModelWork: Sendable, Hashable {
    /// Re-voicing prose, one section per request. The common case by far, and the
    /// only one that runs while the user waits on a page they are reading.
    case rewrite(words: Int, isFidelitySensitive: Bool)
    /// Presentation tokens for our own renderer, from the user's words.
    case theme
    /// A whole document laid out as markup.
    case document
    /// Authoring or re-fitting a lens: ops over a catalog of candidate regions.
    case lens
}

/// The user's standing answer to "which model", when they have given one.
///
/// ``automatic`` is the default and the one that should stay chosen: it routes by
/// the shape of the work. The two manual settings remain reachable because they
/// each answer a real question — someone with a key may want the cloud model for
/// everything, and someone on a machine where nothing may leave wants exactly
/// that — but neither is what decides by default any more.
public enum ModelPreference: String, Codable, Sendable, CaseIterable {
    case automatic
    case onDevice
    case cloud
}

/// Where one piece of work goes, and where it goes if that tier is out.
public struct ModelRoute: Sendable, Hashable {
    public var tier: ProviderTier
    /// The honest second choice, or nil where there must not be one. A route with
    /// no fallback is a policy statement, not an oversight — see
    /// ``ModelRouting/sensitiveStaysOnDevice``.
    public var fallback: ProviderTier?
    /// Why the work goes here, in the user's terms. Surfaced when the route cannot
    /// be served, so a refusal explains itself rather than just failing.
    public var reason: String

    public init(tier: ProviderTier, fallback: ProviderTier? = nil, reason: String) {
        self.tier = tier
        self.fallback = fallback
        self.reason = reason
    }
}

/// What a route came to once the tiers were asked whether they could serve it.
public enum ModelOutcome: Sendable, Equatable {
    case use(ProviderTier)
    /// Nothing on this route can run. `reason` is the blocking tier's own sentence
    /// — the answer to "why not the model you would have used" — and `cloudRoute`
    /// is true when an OpenAI key is all that stands in the way, so the UI knows
    /// whether it has a button to offer or only an explanation to give.
    case unavailable(reason: String, cloudRoute: Bool)
}

/// Which model does which work, as a pure function of the work.
///
/// A type rather than a branch inside a controller for the same reason
/// ``LevelCeiling`` is one: the failure this rule exists to prevent is silent. A
/// route that quietly sends a medical page to a third party, or that quietly runs
/// a 6000-word feature through a 3B model until the voice falls apart, looks
/// exactly like a route that worked. Held still here, both are one assertion.
public enum ModelRouting {

    // Reasons, one per rule, so a test asserts the mapping rather than the prose.

    public static let everydayOnDevice = """
        Re-voicing prose runs on your device. It is free, nothing about what you \
        are reading leaves the machine, and it is the work the on-device model is \
        actually good at.
        """

    public static let longRewriteEarnsCloud = """
        This is a long read. Prompted section by section, a small model drifts in \
        voice across dozens of passages — twenty paragraphs that read like twenty \
        writers — so Zentic sends long rewrites to the cloud model.
        """

    public static let sensitiveStaysOnDevice = """
        This page reads as news, medical, legal or financial. Zentic keeps those on \
        your device whatever their length: the answer to high stakes is the original \
        one keystroke away, not a more fluent paraphrase sent to someone else.
        """

    public static let themeOnDevice = """
        A theme is a handful of token values from a closed schema, which the \
        on-device model fills in well — and it is generated once per site, so it \
        never costs a request per page.
        """

    public static let structuredNeedsCloud = """
        Laying out a page or authoring a lens is a long, structured generation. A \
        small model that returns half a document is worse than one that says no, so \
        these go to the cloud model.
        """

    public static let pinnedOnDevice =
        "You chose On-Device in View ▸ Model, so nothing here leaves your device."

    public static let pinnedCloud = "You chose OpenAI in View ▸ Model."

    /// Route one piece of work.
    ///
    /// Two rules do the work, and they pull in opposite directions on purpose.
    ///
    /// **Size escalates.** What grows with an article is not the difficulty of any
    /// one section but the number of independent generations, and a small model
    /// holds a voice across three passages and loses it across thirty. So past
    /// ``Budget/cloudRewriteWords`` a rewrite is the cloud model's job.
    ///
    /// **Sensitivity does not escalate — it vetoes.** Sensitivity is a statement
    /// about the stakes, and invariant 6's answer to stakes is the confirm, the
    /// badge and ⌘\, not a better model: a frontier model paraphrasing a dosage or
    /// a settlement figure is not safer than a small one, only more fluent about
    /// being wrong. Escalating on sensitivity would send precisely the pages most
    /// worth keeping private — someone's diagnosis, their bank's terms — to a third
    /// party, which is the trade this browser exists to refuse. So a
    /// fidelity-sensitive rewrite stays on the device at any length, and gets no
    /// cloud fallback either.
    ///
    /// A manual preference overrides both. That is not a hole in the rule: the rule
    /// is about what Zentic chooses *for* the user, and a setting they went to the
    /// menu to change is their own choice, made with the confirm still in front of
    /// them.
    public static func route(
        for work: ModelWork,
        preference: ModelPreference = .automatic
    ) -> ModelRoute {
        switch preference {
        case .onDevice:
            // No fallback: falling back to the cloud is the exact opposite of what
            // this setting says.
            return ModelRoute(tier: .onDevice, reason: pinnedOnDevice)
        case .cloud:
            return ModelRoute(tier: .byoKey, reason: pinnedCloud)
        case .automatic:
            break
        }

        switch work {
        case .document, .lens:
            return ModelRoute(tier: .byoKey, reason: structuredNeedsCloud)
        case .theme:
            return ModelRoute(tier: .onDevice, fallback: .byoKey, reason: themeOnDevice)
        case .rewrite(let words, let isFidelitySensitive):
            if isFidelitySensitive {
                return ModelRoute(tier: .onDevice, reason: sensitiveStaysOnDevice)
            }
            if words >= Budget.cloudRewriteWords {
                return ModelRoute(tier: .byoKey, fallback: .onDevice, reason: longRewriteEarnsCloud)
            }
            return ModelRoute(tier: .onDevice, fallback: .byoKey, reason: everydayOnDevice)
        }
    }

    /// Meet a route with what the tiers actually report.
    ///
    /// Separate from ``route(for:preference:)`` because availability is the one
    /// thing routing cannot know on its own — ``ProviderAvailability`` has real
    /// reasons behind it, and they change while the app runs — but the *handling*
    /// of it is still a decision, so it is pure and it is tested.
    public static func resolve(
        _ route: ModelRoute,
        onDevice: ProviderAvailability,
        cloud: ProviderAvailability
    ) -> ModelOutcome {
        func availability(of tier: ProviderTier) -> ProviderAvailability {
            tier == .onDevice ? onDevice : cloud
        }

        let attempts = [route.tier] + (route.fallback.map { [$0] } ?? [])
        for tier in attempts where availability(of: tier).isAvailable {
            return .use(tier)
        }

        // The blocker to name is the tier we *would* have used. Naming the fallback
        // instead answers a question the user did not ask.
        let blocker = availability(of: route.tier).reason ?? "No model is available."

        // A cloud route is only worth offering when the route permits one and a key
        // is the thing missing. An ineligible cloud tier, or a route that
        // deliberately has no cloud in it, gets the rule's own reason instead — a
        // button that would not help is worse than a sentence that explains.
        let cloudRoute =
            attempts.contains(.byoKey)
            && !cloud.isAvailable
            && cloud.isRecoverable
        return .unavailable(
            reason: cloudRoute ? blocker : blocker + "\n\n" + route.reason,
            cloudRoute: cloudRoute
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

    /// The sentence to show the user, or nil when there is nothing wrong.
    public var reason: String? {
        switch self {
        case .available: nil
        case .unavailable(let reason), .ineligible(let reason): reason
        }
    }

    /// Whether the user could change this answer today.
    ///
    /// The distinction ``ineligible`` draws is the one routing needs: "turn on
    /// Apple Intelligence" or "add a key" is worth offering, and "this Mac cannot"
    /// must never be offered again.
    public var isRecoverable: Bool {
        if case .ineligible = self { false } else { true }
    }
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
