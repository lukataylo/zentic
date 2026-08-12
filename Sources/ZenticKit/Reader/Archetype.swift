import Foundation

/// How a page is shaped, which decides how the reader lays it out.
///
/// Detection must **fail open**: when confidence is low, prefer `.app` (pass the
/// original page through untouched) over guessing wrong. Silently mangling
/// someone's mail client is far worse than declining to restructure an article.
public enum Archetype: String, Codable, Sendable, CaseIterable {
    /// Long-form prose. Single-column reading view.
    case article
    /// Reference/API documentation. Reading view plus sticky table of contents.
    case docs
    /// Infinite or paginated list of items. Rendered incrementally as the site appends.
    case feed
    /// Rooted discussion with replies. Rendered as a collapsible tree.
    case thread
    /// An interactive application, not a document. **Never restructured.**
    case app

    /// Whether the restructure layer may replace the document at all.
    public var isRestructurable: Bool { self != .app }
}

/// Why the reader made the original page visible again.
///
/// `.failsafe` is the one that matters operationally: it means the pipeline
/// exceeded its budget and we revealed the unstyled page rather than leave the
/// user staring at a blank window. A rising `.failsafe` rate is the signal that
/// extraction is too slow or a recipe has rotted.
public enum RevealReason: String, Codable, Sendable {
    /// Restructured content rendered successfully.
    case rendered
    /// Archetype was `.app`, or the origin is on the pass-through list.
    case passthrough
    /// Extraction produced nothing usable.
    case extractionEmpty
    /// Budget exceeded; revealed unconditionally. Never leave the page hidden.
    case failsafe
    /// User asked to see the original (⌘\).
    case userRequested
}
