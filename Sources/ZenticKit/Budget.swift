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

    // MARK: Lenses

    /// How long one op pass may run before it stops and reports the remainder
    /// as ``LensOpStatus/skipped``.
    ///
    /// A lens replays on every visit and on every SPA navigation, so this is the
    /// difference between a browser that feels instant and one that stutters
    /// whenever the user scrolls. Finishing the current op and stopping is
    /// correct: a partly applied lens is visible and reported, a janky page is
    /// neither.
    public static let lensOpPassCeiling: Duration = .milliseconds(120)

    /// Quiet period before a mutation in a watched feed triggers another pass.
    /// Infinite scroll mutates continuously; without this every appended card
    /// would cost a full pass.
    public static let lensObserverDebounce: Duration = .milliseconds(80)

    /// Hard rate limit on observer-triggered passes. A site whose own script
    /// reacts to our mutations can otherwise drive an unbounded loop.
    public static let lensObserverMaxPassesPerSecond: Int = 8

    /// Repeated children one op may touch per pass.
    public static let lensMaxItemsPerPass: Int = 400

    /// Ops kept per lens. Model output is capped at this; beyond it a lens is
    /// no longer something a user can reason about or undo one chip at a time.
    public static let lensMaxOpsPerLens: Int = 40

    public static let lensMaxLensesPerOrigin: Int = 12

    /// Candidates offered to the model. Caps prompt size, like
    /// ``Budget/skeletonNodeLimit``.
    public static let lensRegionCandidateLimit: Int = 120

    // MARK: Tabs

    /// Live `WKWebView`s kept resident. Beyond this, least-recently-used tabs are
    /// suspended to a snapshot plus restorable state. Each live web view costs
    /// roughly 50–100MB, so this is a memory ceiling, not a preference.
    public static let maxLiveWebViews: Int = 8
}
