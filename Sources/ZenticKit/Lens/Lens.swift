import Foundation

// MARK: - The lens itself

/// A saved instruction set that remodels a live page on every visit, with no
/// model call.
///
/// This is deliberately *not* restructure. Restructure extracts a page's content
/// and re-renders it in our own DOM, which invariant 2 forbids on apps. A lens
/// leaves the site's own DOM in place and interactive, and only rearranges it —
/// so it is safe exactly where restructure is not. It is what makes "YouTube
/// without the suggestions rail" possible while the real player keeps working.
///
/// Ops are authored once, by a model, from the user's words plus a textless
/// ``RegionCatalog``. Replay is deterministic and local: a lens costs nothing per
/// visit, works offline, and cannot leak what the user reads.
///
/// The shape is intentionally flat — a ``LensOpKind`` discriminator plus optional
/// fields rather than an enum with associated values — because every type here is
/// mirrored by hand in `web/src/wire.ts`, and Swift's associated-value encoding
/// has no natural TypeScript counterpart.
public struct Lens: Codable, Sendable, Hashable, Identifiable {
    /// Bump when a stored lens could be *misread* by this build. Older lenses are
    /// discarded rather than migrated: a lens whose ops half-apply is worse than no
    /// lens, and the user still has the prompt to re-fit from.
    ///
    /// Not every shape change qualifies. Dropping a field the decoder now ignores,
    /// or adding an optional one, leaves every stored lens meaning exactly what it
    /// meant — and bumping for that throws away the user's work to no end. It is
    /// only a bump when the *same bytes* would now produce a different page.
    public static let currentSchemaVersion = 1

    public var id: String
    /// User-facing name, shown in the popover and the toolbar badge.
    public var name: String
    /// Host this lens belongs to, e.g. `www.youtube.com`.
    public var origin: String
    /// Path this lens applies to, using the same generalisation as
    /// ``DOMSkeleton/pathPattern``. `"*"` matches the whole origin.
    public var pathPattern: String
    public var isEnabled: Bool
    /// The user's own words. Kept so a drifted lens can be re-fitted against a
    /// redesigned page without asking them to describe it again.
    public var prompt: String
    /// Every region an op is allowed to name. Ops referencing anything else are
    /// rejected by ``Lens/validated(against:)``, which every path into the page
    /// and every read from disk goes through.
    public var regions: [LensRegion]
    public var ops: [LensOp]
    public var createdAt: Date
    /// Last edit. Also the stacking order: lenses apply newest-first.
    ///
    /// There used to be an explicit `order` here, a drag-to-reorder list in the
    /// popover, and a conflict pass that decided which of two clashing ops the
    /// user saw and wrote the sentence explaining it. All of it existed to answer
    /// a question the CSS cascade and DOM order already answer, and answering it
    /// twice is how an op came to be reported `skipped` by a rule the page had
    /// never actually applied. The cheap model is the honest one: the lens the
    /// user touched last is the lens they were thinking about, so it goes first,
    /// and where two lenses genuinely touch one element the browser decides — in
    /// public, in the styles inspector, rather than in a string we invented.
    public var updatedAt: Date
    public var schemaVersion: Int
    /// Result of the last op pass, persisted across launches so the toolbar can
    /// show drift before the page has even loaded.
    public var lastReport: LensReport?

    public init(
        id: String,
        name: String,
        origin: String,
        pathPattern: String = "*",
        isEnabled: Bool = true,
        prompt: String,
        regions: [LensRegion] = [],
        ops: [LensOp] = [],
        createdAt: Date,
        updatedAt: Date,
        schemaVersion: Int = Lens.currentSchemaVersion,
        lastReport: LensReport? = nil
    ) {
        self.id = id
        self.name = name
        self.origin = origin
        self.pathPattern = pathPattern
        self.isEnabled = isEnabled
        self.prompt = prompt
        self.regions = regions
        self.ops = ops
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
        self.lastReport = lastReport
    }

    public var isCompatible: Bool { schemaVersion == Self.currentSchemaVersion }
}

/// A named part of the page an op can act on.
///
/// Named rather than addressed directly because selectors rot. `intent` is the
/// durable half: when every candidate stops matching, the re-fit pass hands the
/// intent and a fresh catalog to a model and gets new selectors, leaving the ops
/// untouched.
public struct LensRegion: Codable, Sendable, Hashable, Identifiable {
    /// Candidates one region may carry.
    ///
    /// Every selector here is unioned into the stylesheet the compiler builds for
    /// each op naming the region, so the cost is `selectors × ops` and it is paid
    /// again on every SPA navigation. A lens carrying 500 selectors across 40 ops
    /// built a five-megabyte sheet without a single selector failing a shape
    /// check. Twelve is more fallbacks than any real region has: the catalog
    /// offers a preferred selector and a handful of alternates.
    public static let maxSelectors = 12

    /// Stable within a lens. This is what ``LensOp/region`` names.
    public var id: String
    /// What this region *is*, in plain words: "the suggested videos sidebar".
    public var intent: String
    /// Candidates, best first. The first that matches wins; the rest are the
    /// cheap half of drift recovery, tried before any model call.
    public var selectors: [String]
    /// What this region *looked like* when the lens was written, so it can be
    /// found again when every selector above misses — and, more importantly, so a
    /// selector that still matches the wrong element can be caught.
    ///
    /// Optional because lenses written before fingerprinting existed must keep
    /// decoding: a stored lens with no fingerprint falls back to selectors alone,
    /// which is exactly what it did before.
    public var fingerprint: RegionFingerprint?

    public init(
        id: String,
        intent: String,
        selectors: [String],
        fingerprint: RegionFingerprint? = nil
    ) {
        self.id = id
        self.intent = intent
        self.selectors = selectors
        self.fingerprint = fingerprint
    }
}

/// A textless structural signature of one element, used to re-find it after the
/// site changes under the lens.
///
/// **Why this exists, and why it is not redundant with ``LensRegion/selectors``.**
/// The best-first candidate list only degrades gracefully when a stale selector
/// matches *nothing*. Measured across live sites, the preferred anchor is usually
/// a structural path or a build-hash class, and after a redesign those keep
/// matching — a *different* element. The second candidate is never asked. So the
/// failure that actually happens is not "the lens stopped working", it is "the
/// lens quietly started hiding the wrong box", reported `applied`, invisible to
/// the badge, to Re-fit and to the user. Scoring every plausible element against
/// this and requiring a threshold turns that into a clean `missed`, which is the
/// thing the drift UI is claiming to tell the truth about.
///
/// **Privacy contract — this type must never carry page text.** Same rule as
/// ``RegionCandidate``, and a lens is *persisted*, so the temptation is stronger:
/// a stored snippet of the region's heading would make matching trivial and would
/// put what the user reads into a file on disk forever. Structure, attribute
/// *names*, counts and *bands* are enough to tell one box from another.
/// `PrivacyContractTests` asserts the declared field set, nil or not.
public struct RegionFingerprint: Codable, Sendable, Hashable {
    /// Attribute names kept. A real element carries a handful; a hundred is a
    /// page trying to make a stored lens large.
    public static let maxAttributeNames = 16
    public static let maxClasses = 16
    /// Ancestors kept. Enough to say "a card inside the feed inside main"; not so
    /// many that the chain re-encodes the structural path the selectors already
    /// hold, which is the thing that drifts.
    public static let maxAncestors = 6
    /// Bands are doublings, so this covers a text length of two billion. A band
    /// outside it is not a page.
    public static let bandBounds = 0...31
    /// Plausible child and sibling counts for one element.
    public static let countBounds = 0...100_000

    /// Tag name, lowercased. A custom element's name (`shreddit-post`) counts and
    /// is the single most durable signal on the modern web: it is registered by
    /// the site's own `customElements.define()`, so renaming it breaks the site's
    /// own JavaScript.
    public var tag: String
    /// The `id` attribute, if any. An id is a selector, not content — the same
    /// judgement ``RegionCandidate/elementID`` already makes.
    public var elementID: String?
    public var classes: [String]
    /// **Names** of the stable `data-*`/`aria-*` attributes the element carries —
    /// `data-testid`, `aria-label` — never their values.
    ///
    /// The name is the durable half anyway: `data-testid` survives a redesign
    /// because a test suite depends on it, while its value is as volatile as a
    /// class. And an `aria-label` *value* is localised prose written for a screen
    /// reader — page text by any honest reading, so it stays out.
    public var attributeNames: [String]
    /// The `role` **value**, and the one attribute value kept.
    ///
    /// Justified because `role` is a closed W3C vocabulary — `feed`, `main`,
    /// `navigation`, `article` — chosen from a fixed list by the page author, so
    /// it cannot contain a character the user is reading. It is also the highest
    /// signal in the set: `div[role="feed"]` is already the correct anchor on
    /// sites where every class is a build hash.
    public var role: String?
    public var childCount: Int
    /// `floor(log2(1 + textLength))`, clamped to ``bandBounds``.
    ///
    /// A band rather than the length because the length is what changes: a feed
    /// gains a card and the number moves, so an exact match would score zero on
    /// the very page the lens was written for. Doublings are stable across a
    /// day's worth of new posts and still separate a rail from an article body.
    public var textLengthBand: Int
    /// The element's box, in the same doubling bands.
    public var rectBand: RegionRectBand
    /// Index among the element's same-tag siblings. What tells the third card in
    /// a feed from the fourth when nothing else does.
    public var siblingIndex: Int
    /// Tag names from the parent upwards, nearest first, at most
    /// ``maxAncestors``. Tag names only — no ids, classes or positions, because
    /// those are what a redesign changes.
    public var ancestorTags: [String]

    public init(
        tag: String,
        elementID: String? = nil,
        classes: [String] = [],
        attributeNames: [String] = [],
        role: String? = nil,
        childCount: Int,
        textLengthBand: Int,
        rectBand: RegionRectBand,
        siblingIndex: Int,
        ancestorTags: [String] = []
    ) {
        self.tag = tag
        self.elementID = elementID
        self.classes = classes
        self.attributeNames = attributeNames
        self.role = role
        self.childCount = childCount
        self.textLengthBand = textLengthBand
        self.rectBand = rectBand
        self.siblingIndex = siblingIndex
        self.ancestorTags = ancestorTags
    }
}

/// A rect reduced to doubling bands: `floor(log2(1 + value))` per component.
///
/// Not ``RegionRect``, deliberately. A catalog rect is measured *now* and read
/// once; a fingerprint rect is compared against a page rendered a month later at
/// a different window size, where "1004px from the left" is noise and "roughly a
/// thousand" is the signal.
public struct RegionRectBand: Codable, Sendable, Hashable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// MARK: - Ops

public enum LensOpKind: String, Codable, Sendable, CaseIterable {
    /// Take the region out of the layout. Never out of the DOM — invariant 6's
    /// reversibility rule applies here too.
    case hide
    /// Keep this region and hide its siblings.
    case keep
    /// Constrain the region's width to a fraction of its container.
    case width
    /// Reparent the region under another region.
    case move
    /// Apply validated presentation tokens.
    case restyle
    /// Sort the region's repeated children.
    case reorder
    /// Keep or drop repeated children by predicate.
    case filter
    /// Prepend a text label to the region.
    case label
    /// Collect fields from repeated children into a named bucket.
    case harvest
    /// Render a harvested bucket into a destination region.
    case insert
}

/// One instruction. Ops fail independently: a selector that matches nothing
/// no-ops and is reported ``LensOpStatus/missed``, never taking the page or the
/// other ops with it.
public struct LensOp: Codable, Sendable, Hashable, Identifiable {
    /// Longest human note kept. Model output is unbounded; the UI chip is not.
    public static let maxNoteLength = 240
    /// Longest label text. Anything longer is a paragraph, not a label.
    public static let maxLabelLength = 120
    /// Plausible positions for a `move`.
    ///
    /// Its own bound rather than ``Budget/lensMaxItemsPerPass``: a move position
    /// is an index among one element's children, and an items-per-pass budget is
    /// a frame-time limit on a feed. Sharing a number between them meant a
    /// perfectly ordinary constant looked load-bearing in two unrelated places.
    /// The runner clamps again to the destination's real child count, so this is
    /// only here to keep an absurd number off the wire.
    public static let indexBounds = 0...1_000

    public var id: String
    public var kind: LensOpKind
    /// ``LensRegion/id`` this acts on.
    public var region: String
    /// One human sentence for the UI chip: "hide the suggestions". This is also
    /// what a drift row shows, so it has to read as the user's own intent.
    public var note: String
    /// Destination region for `move` and `insert`.
    public var target: String?
    /// Position among the destination's children, for `move`.
    public var index: Int?
    /// Width as a fraction of the container, for `width`.
    public var fraction: Double?
    /// Label text, for `label`.
    public var text: String?
    public var style: RegionStyle?
    public var sort: SortSpec?
    public var predicate: ItemPredicate?
    public var filterMode: FilterMode?
    public var harvest: HarvestSpec?
    /// What one repeated child is, within the region. `reorder` and `filter`
    /// need this to know what they are operating on.
    public var itemSelector: String?
    /// Which harvested bucket an `insert` renders — a ``HarvestSpec/into`` value
    /// declared by a `harvest` op in the same lens.
    ///
    /// Without this field `insert` could not be written down at all: `harvest`
    /// names a bucket and nothing on the other side could read the name back.
    public var bucket: String?
    /// Maximum children touched in one pass.
    public var limit: Int?

    public init(
        id: String,
        kind: LensOpKind,
        region: String,
        note: String,
        target: String? = nil,
        index: Int? = nil,
        fraction: Double? = nil,
        text: String? = nil,
        style: RegionStyle? = nil,
        sort: SortSpec? = nil,
        predicate: ItemPredicate? = nil,
        filterMode: FilterMode? = nil,
        harvest: HarvestSpec? = nil,
        itemSelector: String? = nil,
        bucket: String? = nil,
        limit: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.region = region
        self.note = note
        self.target = target
        self.index = index
        self.fraction = fraction
        self.text = text
        self.style = style
        self.sort = sort
        self.predicate = predicate
        self.filterMode = filterMode
        self.harvest = harvest
        self.itemSelector = itemSelector
        self.bucket = bucket
        self.limit = limit
    }
}

/// Presentation for one region. **Validated tokens only — never a CSS string.**
///
/// Invariant 5, applied to lenses. A free-form CSS declaration can contain
/// `url()`, and one `background-image` on a lens that replays on every visit
/// would beacon to an arbitrary host every time the user opens the site. Tokens
/// cannot express a network request, so the compiler in `web/` can emit a
/// stylesheet from these without sanitising anything.
public struct RegionStyle: Codable, Sendable, Hashable {
    /// `#rrggbb`, validated. Nothing else parses.
    public var background: String?
    /// `#rrggbb`, validated.
    public var foreground: String?
    /// Multiplier on the region's inherited font size, 0.5...2.0.
    public var fontScale: Double?
    /// Content width cap in CSS px, 200...4000.
    public var maxWidthPx: Int?
    /// Inner padding in CSS px, 0...200.
    public var paddingPx: Int?
    /// Corner radius in CSS px, 0...64.
    public var radiusPx: Int?
    /// Column count, 1...4.
    public var columns: Int?
    public var hideImages: Bool?

    public init(
        background: String? = nil,
        foreground: String? = nil,
        fontScale: Double? = nil,
        maxWidthPx: Int? = nil,
        paddingPx: Int? = nil,
        radiusPx: Int? = nil,
        columns: Int? = nil,
        hideImages: Bool? = nil
    ) {
        self.background = background
        self.foreground = foreground
        self.fontScale = fontScale
        self.maxWidthPx = maxWidthPx
        self.paddingPx = paddingPx
        self.radiusPx = radiusPx
        self.columns = columns
        self.hideImages = hideImages
    }

    /// True when nothing would be emitted. A `restyle` carrying one of these is
    /// dead weight that would still be reported as applied.
    public var isEmpty: Bool {
        background == nil && foreground == nil && fontScale == nil && maxWidthPx == nil
            && paddingPx == nil && radiusPx == nil && columns == nil && hideImages == nil
    }
}

public enum MatchMode: String, Codable, Sendable, CaseIterable {
    case any, all, none
}

public enum FilterMode: String, Codable, Sendable, CaseIterable {
    case keep, drop
}

public enum ItemField: String, Codable, Sendable, CaseIterable {
    case text, href, ariaLabel
}

/// A closed predicate language for choosing repeated children.
///
/// Closed on purpose. A regular expression or a snippet of JavaScript would be
/// the obvious general answer, and both would let model output run arbitrary
/// matching against page content. This vocabulary can only compare an item's own
/// text against terms that came from the *user's* prompt, and the comparison
/// happens on-device — invariant 4 is untouched because no page character ever
/// travels the other way.
public struct ItemPredicate: Codable, Sendable, Hashable {
    public static let maxTerms = 64
    public static let maxTermLength = 64
    /// Plausible descendant-link counts for one feed item.
    public static let linkBounds = 0...500
    /// Plausible character counts for one feed item.
    public static let charBounds = 0...100_000

    /// Words from the user's prompt, expanded by the model. Never page text.
    public var terms: [String]
    public var matchMode: MatchMode
    public var field: ItemField
    public var minLinks: Int?
    public var maxLinks: Int?
    public var minChars: Int?
    public var maxChars: Int?

    public init(
        terms: [String],
        matchMode: MatchMode = .any,
        field: ItemField = .text,
        minLinks: Int? = nil,
        maxLinks: Int? = nil,
        minChars: Int? = nil,
        maxChars: Int? = nil
    ) {
        self.terms = terms
        self.matchMode = matchMode
        self.field = field
        self.minLinks = minLinks
        self.maxLinks = maxLinks
        self.minChars = minChars
        self.maxChars = maxChars
    }

    /// True when the predicate cannot distinguish anything.
    ///
    /// This matters more than it looks: an empty predicate under
    /// ``MatchMode/none`` matches every item, so a `drop` filter carrying one
    /// would empty the feed. Such a predicate is rejected rather than run.
    public var isVacuous: Bool {
        terms.isEmpty && minLinks == nil && maxLinks == nil && minChars == nil && maxChars == nil
    }
}

public enum SortKey: String, Codable, Sendable, CaseIterable {
    /// Leave the site's own order. Useful as a reset over an earlier lens.
    case documentOrder
    case textLength
    case linkCount
    /// Sort by a field collected by an earlier `harvest` op.
    case harvestedField
}

public struct SortSpec: Codable, Sendable, Hashable {
    public var key: SortKey
    /// ``HarvestField/name`` to sort on, when `key` is ``SortKey/harvestedField``.
    public var field: String?
    public var ascending: Bool

    public init(key: SortKey, field: String? = nil, ascending: Bool = true) {
        self.key = key
        self.field = field
        self.ascending = ascending
    }
}

/// What a harvest is allowed to read off an element.
///
/// A closed enum rather than an attribute name, on both sides of the wire. An
/// arbitrary name would let a lens lift `data-*` payloads a site never meant to
/// render — a session token, an analytics id — and drop them into the visible
/// page. Spelling the set out in the type means a lens carrying anything else
/// fails to decode, instead of being caught by a check somebody might forget to
/// write on one of the two sides.
public enum HarvestAttribute: String, Codable, Sendable, CaseIterable {
    /// The element's own text, whitespace-collapsed.
    case text
    case href
    case src
    case alt
    case title
}

extension HarvestField {
    /// The permitted attribute names, for a model's JSON schema enumeration.
    ///
    /// Derived from ``HarvestAttribute`` rather than written out again, so the
    /// set a model is told about and the set the decoder accepts cannot drift
    /// apart — which is the failure that would show up as a proposal that fails
    /// to decode for reasons nobody can see.
    public static var allowedAttributes: [String] { HarvestAttribute.allCases.map(\.rawValue) }
}

/// One column collected from a repeated child.
public struct HarvestField: Codable, Sendable, Hashable {
    /// Identifier for this column, referenced by ``SortSpec/field``.
    public var name: String
    /// Selector relative to one item, copied from the candidate's
    /// ``RegionCandidate/itemFields``.
    ///
    /// Not a page-level selector, so it is not in ``RegionCatalog/knownSelectors``
    /// and is checked for shape only — see that property for why widening the gate
    /// to include it would be worse than leaving it out. `itemFields` is what makes
    /// the shape-only check safe in practice rather than in principle: before it
    /// existed the model had no way to know what was inside a card, so this was the
    /// one selector it had to invent.
    public var selector: String
    public var attribute: HarvestAttribute

    public init(name: String, selector: String, attribute: HarvestAttribute) {
        self.name = name
        self.selector = selector
        self.attribute = attribute
    }
}

public struct HarvestSpec: Codable, Sendable, Hashable {
    public var itemSelector: String
    public var fields: [HarvestField]
    /// Bucket name an `insert` op reads back.
    public var into: String

    /// Columns one harvest may collect. Beyond this it is scraping, not framing.
    public static let maxFields = 12

    public init(itemSelector: String, fields: [HarvestField], into: String) {
        self.itemSelector = itemSelector
        self.fields = fields
        self.into = into
    }
}

// MARK: - Drift reporting

public enum LensOpStatus: String, Codable, Sendable, CaseIterable {
    /// A selector matched and the op ran.
    case applied
    /// No selector matched. This is drift — the site changed under the lens.
    case missed
    /// Matched more than expected; applied to the first match.
    case ambiguous
    /// The pass ran out of budget before reaching this op.
    ///
    /// Budget only, now that lenses no longer arbitrate between each other. Three
    /// producers, all in `web/src/lens/`: `planOps` past ``Budget/lensMaxOpsPerLens``,
    /// `runStructuralOps` past ``Budget/lensOpPassCeiling``, and `index.ts` when the
    /// whole structural pass is declined. Each is us doing less on purpose and
    /// saying so — which is why this is not ``missed``: nothing about the *site*
    /// changed.
    case skipped
    /// The op could not be applied at all: it threw, or it asked for something
    /// incoherent — an `insert` naming no bucket, two harvests claiming one.
    /// Reported, never propagated.
    ///
    /// Distinct from ``skipped``, which is a budget. This one is the lens itself
    /// being wrong, so the sentence in ``LensOpResult/message`` is something the
    /// user can act on by editing it.
    case failed
}

public struct LensOpResult: Codable, Sendable, Hashable {
    public var opID: String
    public var status: LensOpStatus
    public var matchedCount: Int
    /// Which candidate selector won, so the UI can show what a re-fit changed.
    public var usedSelector: String?
    /// Why, for the non-`applied` statuses. Which budget ran out, for
    /// ``LensOpStatus/skipped``.
    public var message: String?

    public init(
        opID: String,
        status: LensOpStatus,
        matchedCount: Int = 0,
        usedSelector: String? = nil,
        message: String? = nil
    ) {
        self.opID = opID
        self.status = status
        self.matchedCount = matchedCount
        self.usedSelector = usedSelector
        self.message = message
    }
}

/// What one lens actually did on one URL.
///
/// Persisted, because drift is the failure mode a lens system lives or dies on:
/// a site redesigns, three ops silently stop matching, and without this the user
/// just concludes the browser is broken.
public struct LensReport: Codable, Sendable, Hashable {
    /// Results one report may carry.
    ///
    /// A report is one row per op, and a lens holds at most
    /// ``Budget/lensMaxOpsPerLens`` ops, so anything beyond this is a report about
    /// ops that cannot exist. The number matters because this is page-supplied and
    /// it is persisted: without a cap, one event writes as much as it likes into
    /// `Lenses.json` and every launch reads it back.
    public static let maxResults = Budget.lensMaxOpsPerLens

    public var lensID: String
    public var url: String
    public var results: [LensOpResult]
    public var generatedAt: Date

    public init(lensID: String, url: String, results: [LensOpResult], generatedAt: Date) {
        self.lensID = lensID
        self.url = url
        self.results = results
        self.generatedAt = generatedAt
    }

    public var appliedCount: Int { results.filter { $0.status == .applied }.count }
    public var missedCount: Int { results.filter { $0.status == .missed }.count }
    public var totalCount: Int { results.count }
    public var isDrifted: Bool { missedCount > 0 }
}

// MARK: - Region catalog (page → app)

/// Position and size of a candidate, in CSS px.
public struct RegionRect: Codable, Sendable, Hashable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One field a `harvest` could collect from a repeated item.
///
/// **Why this exists.** ``HarvestField/selector`` is the one selector a model must
/// supply and the one that is deliberately *not* catalog-gated, because it is
/// resolved inside a single item rather than against the document. Until this
/// type existed the model was shown the item selector and nothing about what was
/// *inside* an item — so authoring a harvest meant inventing `.title` and hoping,
/// against a system prompt that says invented selectors are discarded. Measured
/// across fourteen real sites, `harvest` was authorable on none of them. These are
/// the descendants of the first item, sampled once, so the model can name one it
/// has actually been shown.
///
/// Named `ItemFieldCandidate` and not `ItemField` because ``ItemField`` is already
/// the predicate's field vocabulary (`text`/`href`/`ariaLabel`), which is a
/// different question about the same word.
///
/// **Privacy contract — this type must never carry page text.** It is the most
/// tempting place in the whole catalog to break it: a model would pick the right
/// field instantly from `{selector: "h3", text: "How to make bread"}`. That is
/// precisely the sentence the user is reading. Attribute *names* and a text
/// *length* are what it gets. `PrivacyContractTests` asserts the declared field
/// set, nil or not.
public struct ItemFieldCandidate: Codable, Sendable, Hashable {
    /// Attribute names offered per field. A field carrying more than this is
    /// noise; the model only needs to know that `href` or `src` is there to read.
    public static let maxAttributes = 8

    /// Selector relative to one item — `h3`, `a[href]`, `.byline`. What a
    /// ``HarvestField/selector`` may be copied from.
    public var selector: String
    public var tag: String
    /// **Names** of the attributes this element carries that a harvest could
    /// read: `href`, `src`, `alt`, `title`. Never their values — an `alt` value
    /// is a sentence about the picture, and `href` is the user's destination.
    public var attributesPresent: [String]
    /// **Length** of this field's text, in characters. Never the text. Enough to
    /// tell a headline from a timestamp from a body paragraph.
    public var textLength: Int

    public init(selector: String, tag: String, attributesPresent: [String], textLength: Int) {
        self.selector = selector
        self.tag = tag
        self.attributesPresent = attributesPresent
        self.textLength = textLength
    }
}

/// One addressable part of the page, as offered to the model.
///
/// **Privacy contract — this type must never carry page text.**
///
/// Same rule as ``SkeletonNode``, for the same reason: authoring ops needs to
/// know *where* things are and *how big* they are, never *what they say*.
/// Geometry, counts and text *lengths* are enough to tell a suggestions rail
/// from an article body. `PrivacyContractTests` asserts the encoded field set,
/// so adding anything that could hold characters from the page fails a test.
public struct RegionCandidate: Codable, Sendable, Hashable, Identifiable {
    /// Item fields offered per candidate.
    ///
    /// Twelve, matching ``HarvestSpec/maxFields``: a harvest cannot collect more
    /// columns than that, so offering more is offering fields no op could use
    /// while paying for them in every prompt. It is also the cap that stops a
    /// page with two thousand nodes inside one card from writing two thousand
    /// entries into a catalog.
    public static let maxItemFields = HarvestSpec.maxFields

    /// Stable within this catalog, e.g. `r7`. Not stable across page loads.
    public var id: String
    /// Preferred selector for this element.
    public var selector: String
    /// Fallbacks, best first. These become ``LensRegion/selectors``.
    public var alternates: [String]
    public var tag: String
    /// Element id attribute, if any. Ids are selectors, not content.
    public var elementID: String?
    public var classes: [String]
    public var role: String?
    /// `header|nav|main|aside|feed|media|footer|comments|unknown`. A guess, so
    /// the model has a shorter path to the region the user means.
    public var kindGuess: String
    public var rect: RegionRect
    public var depth: Int
    /// **Length** of the element's text, in characters. Never the text.
    public var textLength: Int
    public var linkCount: Int
    public var paragraphCount: Int
    public var imageCount: Int
    /// Count of similar repeated children. High counts mean a feed.
    public var itemCount: Int
    /// Selector matching one of those repeated children.
    public var itemSelector: String?
    /// What is *inside* one of those repeated children, so a `harvest` can be
    /// authored against fields the model has been shown rather than guessed.
    /// Empty for a candidate that is not a feed.
    public var itemFields: [ItemFieldCandidate]

    public init(
        id: String,
        selector: String,
        alternates: [String] = [],
        tag: String,
        elementID: String? = nil,
        classes: [String] = [],
        role: String? = nil,
        kindGuess: String = "unknown",
        rect: RegionRect,
        depth: Int,
        textLength: Int,
        linkCount: Int,
        paragraphCount: Int,
        imageCount: Int,
        itemCount: Int,
        itemSelector: String? = nil,
        itemFields: [ItemFieldCandidate] = []
    ) {
        self.id = id
        self.selector = selector
        self.alternates = alternates
        self.tag = tag
        self.elementID = elementID
        self.classes = classes
        self.role = role
        self.kindGuess = kindGuess
        self.rect = rect
        self.depth = depth
        self.textLength = textLength
        self.linkCount = linkCount
        self.paragraphCount = paragraphCount
        self.imageCount = imageCount
        self.itemCount = itemCount
        self.itemSelector = itemSelector
        self.itemFields = itemFields
    }
}

/// Everything a model is allowed to see about a page before authoring ops.
///
/// The textless counterpart to ``DOMSkeleton``: same promise, different shape,
/// because op authoring needs geometry and repeated-child counts that recipe
/// inference does not.
public struct RegionCatalog: Codable, Sendable, Hashable {
    public var origin: String
    public var pathPattern: String
    public var viewport: DOMSkeleton.Viewport
    public var candidates: [RegionCandidate]

    public init(
        origin: String,
        pathPattern: String,
        viewport: DOMSkeleton.Viewport,
        candidates: [RegionCandidate]
    ) {
        self.origin = origin
        self.pathPattern = pathPattern
        self.viewport = viewport
        self.candidates = candidates
    }

    /// Every selector this page actually offered.
    ///
    /// The gate a model's output is checked against: an op may only name a
    /// selector that came from here, so a model cannot invent one that happens
    /// to match something on a page it never saw.
    ///
    /// Normalised on the way in, through the same token gates the *op's* selector
    /// will go through. Otherwise the two sides of the comparison are spelled
    /// differently: a catalog offering `" li "` could never authorise `li`,
    /// because the op's selector is trimmed before the lookup and the set's is
    /// not — the page offered an item selector no op could use, and the op was
    /// dropped as though a model had invented it. It also means a catalog cannot
    /// authorise something that is not a selector at all: `knownSelectors` is what
    /// says "the page offers this", so a malformed entry would authorise itself.
    public var knownSelectors: Set<String> {
        var known: Set<String> = []
        for candidate in candidates {
            if let selector = LensToken.regionSelector(candidate.selector) {
                known.insert(selector)
            }
            known.formUnion(candidate.alternates.compactMap(LensToken.regionSelector))
            // An item selector is matched inside one element, so it gets the shape
            // gate without the breadth limit — `:scope > article.card` is what
            // `regions.ts` produces here.
            if let item = candidate.itemSelector.flatMap(LensToken.selector) { known.insert(item) }
            // ``RegionCandidate/itemFields`` is deliberately *not* unioned in.
            // This set is the gate for selectors resolved against the *document*,
            // and an item field is resolved inside one card: `.title` authorising
            // itself here would let a `hide` op name every title on the page as
            // though it were a region. Field selectors get the shape gate in
            // ``HarvestSpec/validated(knownSelectors:)`` and nothing more, which
            // is what they had before this field existed.
        }
        return known
    }
}
