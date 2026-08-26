import Testing
import ZenticKit

@testable import ZenticMac

/// Whether the top stop can actually reach the rewrite layer.
///
/// The defect these exist for, reported as "when I change to the re-written tab
/// then the text doesn't automatically update". The wiring was all there —
/// `setLevel(.rewritten)` calls `startRewriteForTopStop`, which calls
/// `requestRewrite`, which calls `TabController.rewrite` — and the whole chain was
/// gated behind `canRewrite`, one half of which is `readerMode == .restructured`.
///
/// `TabController.setLevel` returned early on a level change that crosses the
/// strip layer, because that change costs a reload and there is no point sending a
/// command to a document about to be replaced. The early return sat *above*
/// `readerMode = level.readerMode`, so the mirror was left behind while the
/// configuration two lines up already carried the new mode. The page reloaded and
/// rendered a perfectly good reader; the tab still believed it was showing the
/// site's own page; `canRewrite` was false; the rewrite declined on arrival and
/// declined again on every reveal after it — with no error anywhere, because
/// declining early is exactly what "not ready yet" looks like.
///
/// So the rail sat on Rewritten and the prose never changed.
@Suite("Rewrite reach")
struct RewriteReachTests {

    @MainActor
    private func tab() -> TabController {
        TabController(
            record: Tab(urlString: "https://www.theverge.com/1/tech-story"),
            faviconService: FaviconService()
        )
    }

    /// The exact gesture from the report: drop the rail to look at the site's own
    /// layout, then pull it all the way to the top.
    @MainActor
    @Test("Dragging the rail from Clean to Rewritten leaves the tab in the reader")
    func stripCrossingClimbEndsRestructured() {
        let tab = tab()
        tab.setLevel(.calm)
        #expect(tab.readerMode == .original)
        // Calm → Clean crosses the strip layer, so it reloads.
        tab.setLevel(.clean)
        #expect(tab.readerMode == .original)

        tab.setLevel(.rewritten)
        #expect(tab.readerMode == .restructured)
    }

    /// The same staleness in the other direction: it used to leave a tab believing
    /// it was rendering a reader over a document that had reloaded into the site's
    /// own page.
    @MainActor
    @Test("Dropping the rail below the reader leaves the tab on the site's own page")
    func stripCrossingDescentEndsOriginal() {
        let tab = tab()
        #expect(tab.readerMode == .restructured)
        // Reader → Clean crosses the strip layer, so it reloads.
        tab.setLevel(.clean)
        #expect(tab.readerMode == .original)
    }

    @MainActor
    @Test("Every level agrees with the mode it projects, however it is reached")
    func modeAlwaysMatchesLevel() {
        // Each ordered pair, since what broke was one specific pair of transitions
        // and a rule that only holds for the pairs someone thought of is not a rule.
        for from in PageLevel.allCases {
            for to in PageLevel.allCases where to != from {
                let tab = tab()
                tab.setLevel(from)
                tab.setLevel(to)
                #expect(
                    tab.readerMode == to.readerMode,
                    "\(from.rawValue) → \(to.rawValue) left the tab in \(tab.readerMode.rawValue)"
                )
            }
        }
    }
}
