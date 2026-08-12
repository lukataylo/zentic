import Foundation

/// A structural fingerprint of a page, used to infer a ``SiteRecipe``.
///
/// **Privacy contract — this type must never carry page text.**
///
/// Recipe inference needs to know *where* the content lives, not *what it says*.
/// So a skeleton records tag names, class/id tokens, ARIA roles, geometry and
/// text *lengths* — never the characters themselves. That means a user's reading
/// never reaches a model in order to build a recipe, and it makes the prompt
/// dramatically cheaper than shipping the DOM.
///
/// Any change that adds a field capable of holding page content breaks this
/// contract. `ZenticKitTests.DOMSkeletonPrivacyTests` guards it.
public struct DOMSkeleton: Codable, Sendable, Hashable {
    public var origin: String
    /// URL path with numeric and slug-like components replaced by `*`, so
    /// `/posts/12345/my-title` becomes `/posts/*/*`. Groups pages of a kind.
    public var pathPattern: String
    public var viewport: Viewport
    public var nodes: [SkeletonNode]

    public init(origin: String, pathPattern: String, viewport: Viewport, nodes: [SkeletonNode]) {
        self.origin = origin
        self.pathPattern = pathPattern
        self.viewport = viewport
        self.nodes = nodes
    }

    public struct Viewport: Codable, Sendable, Hashable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }
}

/// One node in a ``DOMSkeleton``. Carries shape, never content.
public struct SkeletonNode: Codable, Sendable, Hashable {
    /// Lowercase tag name, e.g. `article`.
    public var tag: String
    /// Element id, if any. Ids are structural selectors, not content.
    public var id: String?
    /// Class tokens on the element.
    public var classes: [String]
    /// ARIA role or landmark, a strong main-content signal.
    public var role: String?
    /// A stable CSS path to this node, so an inferred recipe can name it.
    public var path: String
    public var depth: Int
    /// **Length** of the node's own text, in characters. Never the text.
    public var textLength: Int
    /// Number of descendant links. High link density means navigation or a feed.
    public var linkCount: Int
    /// Descendant paragraph count. High counts mean prose.
    public var paragraphCount: Int
    /// Rendered area in CSS px². The largest text-dense box is usually the content.
    public var area: Int
    /// True when the element is hidden at narrow widths — a reliable
    /// not-main-content signal, since sites hide chrome on mobile.
    public var hiddenOnNarrow: Bool

    public init(
        tag: String,
        id: String? = nil,
        classes: [String] = [],
        role: String? = nil,
        path: String,
        depth: Int,
        textLength: Int,
        linkCount: Int,
        paragraphCount: Int,
        area: Int,
        hiddenOnNarrow: Bool = false
    ) {
        self.tag = tag
        self.id = id
        self.classes = classes
        self.role = role
        self.path = path
        self.depth = depth
        self.textLength = textLength
        self.linkCount = linkCount
        self.paragraphCount = paragraphCount
        self.area = area
        self.hiddenOnNarrow = hiddenOnNarrow
    }
}
