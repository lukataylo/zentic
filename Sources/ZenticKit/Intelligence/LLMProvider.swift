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
