import Foundation

/// A cached, per-origin description of how to extract content from a site.
///
/// Recipes are an optimisation and a quality lever, never a requirement: when a
/// recipe is missing, stale or wrong, extraction falls back to the generic path.
/// That fallback is what makes it safe to generate them automatically.
public struct SiteRecipe: Codable, Sendable, Hashable, Identifiable {
    /// Bump when the shape changes; older recipes are discarded rather than migrated
    /// (they are cheap to regenerate, and a wrong recipe is worse than none).
    public static let currentSchemaVersion = 1

    public var id: String { "\(origin)|\(pathPattern)" }

    public var origin: String
    /// Pattern this recipe applies to, matching ``DOMSkeleton/pathPattern``.
    /// `"*"` matches the whole origin.
    public var pathPattern: String
    public var archetype: Archetype
    /// Candidate content roots, best first. First one that matches and yields
    /// content wins.
    public var contentSelectors: [String]
    /// Selectors removed before extraction: promos, related-article rails,
    /// share bars, newsletter prompts.
    public var junkSelectors: [String]
    /// For `.feed` and `.thread`: selector matching one item in the list.
    public var itemSelector: String?
    public var quirks: Set<Quirk>
    public var provenance: Provenance
    public var generatedAt: Date
    public var schemaVersion: Int

    public init(
        origin: String,
        pathPattern: String = "*",
        archetype: Archetype,
        contentSelectors: [String] = [],
        junkSelectors: [String] = [],
        itemSelector: String? = nil,
        quirks: Set<Quirk> = [],
        provenance: Provenance,
        generatedAt: Date,
        schemaVersion: Int = SiteRecipe.currentSchemaVersion
    ) {
        self.origin = origin
        self.pathPattern = pathPattern
        self.archetype = archetype
        self.contentSelectors = contentSelectors
        self.junkSelectors = junkSelectors
        self.itemSelector = itemSelector
        self.quirks = quirks
        self.provenance = provenance
        self.generatedAt = generatedAt
        self.schemaVersion = schemaVersion
    }

    /// Site-specific behaviours that generic extraction gets wrong.
    public enum Quirk: String, Codable, Sendable {
        /// Content arrives after first paint; wait for the content selector.
        case lateHydration
        /// Body text is inside a `<template>` or shadow root.
        case shadowContent
        /// Images use a non-standard lazy attribute needing rewriting to `src`.
        case lazyImageAttrs
        /// Article is split across "next page" links that should be stitched.
        case paginated
        /// Site breaks when its stylesheets are removed; keep them and overlay instead.
        case keepStylesheets
        /// Never restructure, regardless of archetype detection.
        case neverRestructure
    }

    /// Where a recipe came from. Curated recipes outrank inferred ones, and a
    /// user override outranks everything.
    public enum Provenance: String, Codable, Sendable, Comparable {
        case inferred
        case curated
        case userOverride

        private var rank: Int {
            switch self {
            case .inferred: 0
            case .curated: 1
            case .userOverride: 2
            }
        }

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
    }

    public var isCompatible: Bool { schemaVersion == Self.currentSchemaVersion }

    public func isStale(asOf now: Date = .now, maxAge: TimeInterval = Budget.recipeMaxAge) -> Bool {
        // Curated and user recipes never expire on a timer; they change when we
        // ship a new build or the user edits them.
        guard provenance == .inferred else { return false }
        return now.timeIntervalSince(generatedAt) > maxAge
    }
}

/// Persistent recipe storage. Implementations must be safe to call from any task.
public protocol RecipeStore: Sendable {
    /// Best matching recipe for a URL, preferring the most specific path pattern
    /// and then the highest provenance. Returns nil when nothing matches.
    func recipe(for url: URL) async -> SiteRecipe?
    func save(_ recipe: SiteRecipe) async throws
    func delete(id: String) async throws
    /// Origins the user visits often that have no usable recipe, most-visited
    /// first. Drives background inference.
    func originsNeedingInference(limit: Int) async -> [String]
}
