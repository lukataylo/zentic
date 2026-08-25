import AppKit
import Testing
import ZenticKit

@testable import ZenticMac

/// The rail's half of the same defect: a ceiling is only worth deriving if the
/// control draws it.
///
/// Drawing is not observable from a test — `draw(_:)` needs a graphics context and
/// asserting on pixels would be asserting on AppKit. The tooltip is the part of the
/// capped path that *is* a value: it is built from the same `ceiling` comparison the
/// struck-out dots are, so a tooltip carrying the reason is evidence the reason
/// reached the view and that the comparison ran. What is not covered here is the
/// dots themselves and the click that answers `onBlocked`.
@Suite("Level rail")
struct LevelRailTests {

    @MainActor
    @Test("A stop above the ceiling explains itself")
    func cappedStopExplainsItself() {
        let rail = LevelRailView(frame: .zero)
        rail.apply(
            level: .reader,
            automatic: .calm,
            ceiling: .calm,
            ceilingReason: LevelCeiling.declinedAsApp
        )
        // The rail describes the stop it is sitting on, and this one is above the
        // ceiling — which is what a pinned level on a page that declined looks like.
        #expect(rail.toolTip == LevelCeiling.declinedAsApp)
    }

    @MainActor
    @Test("A reachable stop describes the level, not the ceiling")
    func reachableStopDescribesItself() {
        let rail = LevelRailView(frame: .zero)
        rail.apply(level: .reader, automatic: .reader, ceiling: .rewritten, ceilingReason: nil)
        #expect(rail.toolTip?.hasPrefix("Reader — ") == true)
    }
}
