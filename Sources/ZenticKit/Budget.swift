import Foundation

/// Timing and threshold constants that the whole pipeline agrees on.
///
/// These live in one place because several are safety limits rather than tuning
/// knobs, and a subagent changing one in isolation would break an invariant
/// somewhere else.
public enum Budget {
    // MARK: Anti-flash

    /// How long the reader may keep the page hidden while it works.
    ///
    /// When this expires the page is revealed unconditionally with
    /// ``RevealReason/failsafe``. A brief flash of the original page is a blemish;
    /// a window that never paints is a broken browser. This is a hard ceiling,
    /// not a target — never raise it to make a slow site work.
    public static let revealFailsafe: Duration = .milliseconds(1500)

    /// Quiet period with no DOM mutations before the page counts as settled.
    public static let settleQuietPeriod: Duration = .milliseconds(120)

    /// Longest we wait for a settle before extracting whatever is present.
    public static let settleCeiling: Duration = .milliseconds(900)

    // MARK: Extraction

    /// Below this extraction confidence, pass the original through instead of
    /// rendering a poor reconstruction.
    public static let minConfidence: Double = 0.55

    /// Pages shorter than this are not worth restructuring.
    public static let minWordCount: Int = 40

    // MARK: Recipes

    /// Inferred recipes are re-derived after this long, since sites redesign.
    public static let recipeMaxAge: TimeInterval = 30 * 24 * 60 * 60

    /// Nodes retained in a ``DOMSkeleton``, largest-area first. Caps prompt size.
    public static let skeletonNodeLimit: Int = 220

    /// Visits to an origin before it earns background recipe inference.
    public static let inferenceVisitThreshold: Int = 3

    // MARK: Tabs

    /// Live `WKWebView`s kept resident. Beyond this, least-recently-used tabs are
    /// suspended to a snapshot plus restorable state. Each live web view costs
    /// roughly 50–100MB, so this is a memory ceiling, not a preference.
    public static let maxLiveWebViews: Int = 8
}
