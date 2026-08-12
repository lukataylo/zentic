import Foundation

/// The kind of block a `ContentSection` holds.
///
/// This enum carries a correctness rule, not just a style hint: see
/// ``SectionKind/isRewritable``.
public enum SectionKind: String, Codable, Sendable, CaseIterable {
    case heading
    case paragraph
    case list
    case quote
    case code
    case table
    case math
    case figure
    case embed
    case footnotes

    /// Whether the rewrite layer is allowed to send this section to a model.
    ///
    /// Code, tables, math and embeds are **never** rewritten. A language model
    /// asked to restyle a code block will silently change identifiers; asked to
    /// restyle a table it will drop or invent cells; asked to restyle TeX it will
    /// produce something that no longer typesets. Prose can be re-voiced without
    /// changing what it denotes. These cannot.
    public var isRewritable: Bool {
        switch self {
        case .heading, .paragraph, .list, .quote: true
        case .code, .table, .math, .figure, .embed, .footnotes: false
        }
    }
}

/// One block of extracted content.
///
/// `markdown` is the canonical representation and the only thing ever sent to a
/// model. `html` is populated when Markdown would be lossy (tables with spans,
/// math, iframe embeds) and is pre-sanitized against the render whitelist.
public struct ContentSection: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: SectionKind
    public var markdown: String
    public var html: String?
    /// Heading depth (1–6) when `kind == .heading`, else nil. Drives the docs ToC.
    public var level: Int?

    public init(
        id: String,
        kind: SectionKind,
        markdown: String,
        html: String? = nil,
        level: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.markdown = markdown
        self.html = html
        self.level = level
    }
}

/// What extraction produced for one page.
public struct ExtractionResult: Codable, Sendable, Hashable {
    public var url: String
    public var archetype: Archetype
    public var title: String
    public var byline: String?
    public var publishedAt: Date?
    public var siteName: String?
    /// BCP-47 language tag, used for hyphenation and to set `dir` for RTL.
    public var lang: String?
    public var wordCount: Int
    public var sections: [ContentSection]
    /// Identifier of the recipe used, or nil when generic extraction handled it.
    public var usedRecipe: String?
    /// Extraction self-assessment, 0...1. Below `Budget.minConfidence` we pass through.
    public var confidence: Double
    /// True when the content looks like news/medical/legal/financial material, where
    /// fidelity is load-bearing and the rewrite layer requires an explicit confirm.
    public var isFidelitySensitive: Bool

    public init(
        url: String,
        archetype: Archetype,
        title: String,
        byline: String? = nil,
        publishedAt: Date? = nil,
        siteName: String? = nil,
        lang: String? = nil,
        wordCount: Int,
        sections: [ContentSection],
        usedRecipe: String? = nil,
        confidence: Double,
        isFidelitySensitive: Bool = false
    ) {
        self.url = url
        self.archetype = archetype
        self.title = title
        self.byline = byline
        self.publishedAt = publishedAt
        self.siteName = siteName
        self.lang = lang
        self.wordCount = wordCount
        self.sections = sections
        self.usedRecipe = usedRecipe
        self.confidence = confidence
        self.isFidelitySensitive = isFidelitySensitive
    }

    /// Sections eligible for the rewrite layer.
    public var rewritableSections: [ContentSection] {
        sections.filter { $0.kind.isRewritable }
    }

    public var readingMinutes: Int {
        max(1, Int((Double(wordCount) / 225.0).rounded()))
    }
}
