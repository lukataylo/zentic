import AppKit
import Testing
import ZenticKit

@testable import ZenticMac

/// The rail's half of the same defect: a ceiling is only worth deriving if the
/// control draws it.
///
/// Drawing is not observable from a test — `draw(_:)` needs a graphics context and
/// asserting on pixels would be asserting on AppKit. The label, the tooltip and the
/// accessibility value are the parts of the capped path that *are* values: all three
/// are built from the same `ceiling` comparison the struck-out dots are, so a label
/// naming the stop the page reached is evidence the ceiling got to the view and that
/// the comparison ran. What is not covered here is the dots themselves — the inert
/// active dot and the strike-out — and the click that answers `onBlocked`.
@Suite("Level rail")
struct LevelRailTests {

    /// The observed defect, on google.com: the page reported too little prose to
    /// rebuild, the rail struck out Rewritten and drew the current stop inert — and
    /// the label said "Reader" over a page showing google.com's own layout.
    @MainActor
    @Test("The label names what the page is at, not what was asked for")
    func labelNamesTheEffectiveStop() {
        let rail = LevelRailView(frame: .zero)
        rail.apply(
            level: .reader,
            automatic: .calm,
            ceiling: .calm,
            ceilingReason: LevelCeiling.declinedAsThin,
            preference: .pinned(.reader)
        )
        #expect(rail.displayedTitle == "Calm (held)")
        // The request is not erased by the page that could not honour it: the pin
        // still applies on the next document, so both facts have to be readable.
        #expect(rail.toolTip?.hasPrefix("Calm — ") == true)
        #expect(rail.toolTip?.contains("Reader is not in effect on this page.") == true)
        #expect(rail.toolTip?.contains(LevelCeiling.declinedAsThin) == true)
        #expect(
            rail.accessibilityValue() as? String
                == "Calm, always Reader on this site, Reader not in effect on this page"
        )
    }

    @MainActor
    @Test("A stop above the ceiling explains itself")
    func cappedStopExplainsItself() {
        let rail = LevelRailView(frame: .zero)
        rail.apply(
            level: .reader,
            automatic: .calm,
            ceiling: .calm,
            ceilingReason: LevelCeiling.declinedAsApp,
            preference: .auto
        )
        rail.hover(.reader)
        // Pointing at a struck stop asks one question — why — and the tooltip
        // answers that one and nothing else.
        #expect(rail.toolTip == LevelCeiling.declinedAsApp)
    }

    /// The load path. A ceiling is not known until the page reports, and an unknown
    /// ceiling caps nothing — so the label must name the requested level throughout
    /// rather than dropping to Calm and springing back when the verdict lands.
    @MainActor
    @Test("Nothing reported yet names the level that was asked for")
    func loadingNamesTheRequestedLevel() {
        let rail = LevelRailView(frame: .zero)
        let cap = LevelCeiling.resolve(outcome: nil, isRewriteEnabled: true)
        rail.apply(
            level: .reader,
            automatic: .reader,
            ceiling: cap.level,
            ceilingReason: cap.reason,
            preference: .auto
        )
        #expect(rail.displayedTitle == "Reader")
    }

    @MainActor
    @Test("The label previews the stop under the pointer")
    func labelPreviewsTheHoveredStop() {
        let rail = LevelRailView(frame: .zero)
        rail.apply(
            level: .reader,
            automatic: .reader,
            ceiling: .rewritten,
            ceilingReason: nil,
            preference: .auto
        )
        rail.hover(.original)
        #expect(rail.displayedTitle == "Original")
    }

    @MainActor
    @Test("A reachable stop describes the level, not the ceiling")
    func reachableStopDescribesItself() {
        let rail = LevelRailView(frame: .zero)
        rail.apply(
            level: .reader,
            automatic: .reader,
            ceiling: .rewritten,
            ceilingReason: nil,
            preference: .auto
        )
        #expect(rail.toolTip?.hasPrefix("Reader — ") == true)
    }

    /// The reported defect: the automatic answer had exactly one indication, a
    /// hollow ring drawn only when it differed from the current stop — so under the
    /// default preference, where the two always agree, it appeared nowhere.
    @MainActor
    @Test("The automatic answer is stated even when it is where the page already sits")
    func automaticIsNamedWhenItAgrees() {
        let rail = LevelRailView(frame: .zero)
        rail.apply(
            level: .reader,
            automatic: .reader,
            ceiling: .rewritten,
            ceilingReason: nil,
            preference: .auto
        )
        #expect(rail.toolTip?.contains("Reader") == true)
        #expect(rail.toolTip?.contains("on its own") == true)
    }

    @MainActor
    @Test("A pinned site says so, and still names where the page would land")
    func pinIsVisibleOnTheRail() {
        let rail = LevelRailView(frame: .zero)
        rail.apply(
            level: .clean,
            automatic: .reader,
            ceiling: .rewritten,
            ceilingReason: nil,
            preference: .pinned(.clean)
        )
        #expect(rail.toolTip?.contains("Always Clean here") == true)
        #expect(rail.toolTip?.contains("Reader") == true)
        #expect(rail.accessibilityValue() as? String == "Clean, always Clean on this site")
    }

    /// A pin and the page's own answer are indistinguishable from `level` and
    /// `automatic` alone, so a control told only those two cannot show what the
    /// user set. This is the assertion that the preference reached the view.
    @MainActor
    @Test("The same two levels read differently when one of them was chosen")
    func preferenceIsNotDerivableFromTheLevels() {
        let auto = LevelRailView(frame: .zero)
        auto.apply(
            level: .calm,
            automatic: .calm,
            ceiling: .rewritten,
            ceilingReason: nil,
            preference: .auto
        )
        let capped = LevelRailView(frame: .zero)
        capped.apply(
            level: .calm,
            automatic: .calm,
            ceiling: .rewritten,
            ceilingReason: nil,
            preference: .ceiling(.calm)
        )

        #expect(auto.toolTip != capped.toolTip)
        #expect(auto.accessibilityValue() as? String != capped.accessibilityValue() as? String)
    }
}

/// The wording itself, which is the whole of what the control reflects.
@Suite("Level rail copy")
struct LevelRailCopyTests {

    /// The one property that makes the automatic answer visible at all: whatever
    /// the site is set to, the sentence says where the page lands on its own.
    @Test("Every standing sentence names the automatic level")
    func standingAlwaysNamesTheAutomaticLevel() {
        let preferences: [SitePreference] = [
            .auto,
            .pinned(.original),
            .pinned(.reader),
            .ceiling(.calm),
            .ceiling(.rewritten),
        ]
        for preference in preferences {
            for automatic in PageLevel.allCases {
                let line = LevelRailCopy.standing(preference: preference, automatic: automatic)
                #expect(line.contains(automatic.title), "\(preference) at \(automatic): \(line)")
            }
        }
    }

    @Test("A pin and a ceiling are not described the same way")
    func pinAndCeilingReadDifferently() {
        let pin = LevelRailCopy.standing(preference: .pinned(.calm), automatic: .reader)
        let cap = LevelRailCopy.standing(preference: .ceiling(.calm), automatic: .reader)
        #expect(pin.contains("Always Calm here"))
        #expect(cap.contains("Never above Calm here"))
        #expect(pin != cap)
    }

    /// A ceiling that is not biting is a different fact from one that is, and the
    /// user cannot see the difference on the rail — nothing is struck, and the ring
    /// is where the level already is.
    @Test("A ceiling says whether it is actually holding the page back")
    func ceilingSaysWhetherItBites() {
        let slack = LevelRailCopy.standing(preference: .ceiling(.reader), automatic: .calm)
        let biting = LevelRailCopy.standing(preference: .ceiling(.calm), automatic: .reader)
        #expect(!slack.contains("held back"))
        #expect(biting.contains("held back"))
    }

    /// The property the whole fix hangs on: a level is a request, and what the
    /// control describes is the request capped by what this document could do.
    @Test("The effective stop is never above the ceiling and never above the level")
    func effectiveIsBothOrLower() {
        for level in PageLevel.allCases {
            for ceiling in PageLevel.allCases {
                let stop = LevelRailCopy.effective(level: level, ceiling: ceiling)
                #expect(stop <= level)
                #expect(stop <= ceiling)
                // Nothing invented in between: it is one of the two, not a third
                // answer derived from them.
                #expect(stop == level || stop == ceiling)
            }
        }
    }

    /// The label was the last thing on the rail still naming the request. On a page
    /// that reported too little prose to rebuild it said "Reader" over the site's
    /// own layout — invariant 8, in one word.
    @Test("The label names the stop the page reached, and marks the one it did not")
    func labelNamesTheEffectiveStop() {
        #expect(LevelRailCopy.label(level: .reader, ceiling: .calm, hovered: nil) == "Calm (held)")
        #expect(LevelRailCopy.label(level: .reader, ceiling: .rewritten, hovered: nil) == "Reader")
        #expect(
            LevelRailCopy.label(level: .rewritten, ceiling: .reader, hovered: nil)
                == "Reader (held)"
        )
    }

    /// An unknown ceiling caps nothing, so a load names the level that was asked for
    /// and stays there. The alternative is a label that reads Calm for as long as the
    /// page takes to answer and then jumps.
    @Test("A ceiling that is not biting leaves the label bare")
    func labelIsBareWhenNothingIsHeldBack() {
        for level in PageLevel.allCases {
            let text = LevelRailCopy.label(level: level, ceiling: .rewritten, hovered: nil)
            #expect(text == level.title)
        }
    }

    /// Every ceiling the rail can actually be handed, derived from the only thing
    /// that produces one rather than listed by hand. `Original` is not among them,
    /// which is why the width below holds: `Original (held)` would not fit and
    /// cannot occur.
    static let reachableCeilings: [PageLevel] = {
        let reasons: [RevealReason] = [
            .rendered, .passthrough, .extractionEmpty, .failsafe, .userRequested,
        ]
        let confidences: [Double?] = [nil, 0.1, Budget.minConfidence, 1]
        let outcomes = reasons.flatMap { reason in
            PageLevel.allCases.flatMap { level in
                confidences.map { RevealOutcome(reason: reason, level: level, confidence: $0) }
            }
        }
        let levels = ([nil] + outcomes.map(Optional.init)).flatMap { outcome in
            [true, false].map {
                LevelCeiling.resolve(outcome: outcome, isRewriteEnabled: $0).level
            }
        }
        return PageLevel.allCases.filter(Set(levels).contains)
    }()

    @Test("No page ever caps the rail at Original")
    func ceilingIsNeverTheBottomStop() {
        #expect(!Self.reachableCeilings.contains(.original))
        #expect(!Self.reachableCeilings.isEmpty)
    }

    /// A label cut off mid-word is barely better than a label naming the wrong stop,
    /// and `(held)` is what pushed the longest string past the width the rail had.
    /// Measured rather than eyeballed, because the two only disagree on one string.
    @MainActor
    @Test("Every label the rail can show fits the space it has")
    func everyLabelFitsTheLabelWidth() {
        for level in PageLevel.allCases {
            for ceiling in Self.reachableCeilings {
                for hovered in [nil] + PageLevel.allCases.map(Optional.init) {
                    let text = LevelRailCopy.label(level: level, ceiling: ceiling, hovered: hovered)
                    let width = (text as NSString)
                        .size(withAttributes: [.font: LevelRailView.labelFont])
                        .width
                    #expect(width <= LevelRailView.labelWidth, "\(text) at \(width)pt")
                }
            }
        }
    }

    /// Hovering is a question about a target, not a claim about the page — and the
    /// label switches to `labelColor` for exactly as long as it is one.
    @Test("A hovered stop is previewed by name, capped or not")
    func labelPreviewsWhateverIsUnderThePointer() {
        #expect(
            LevelRailCopy.label(level: .clean, ceiling: .calm, hovered: .rewritten) == "Rewritten"
        )
        #expect(LevelRailCopy.label(level: .reader, ceiling: .calm, hovered: .clean) == "Clean")
    }

    /// The user is asking why a stop is struck out. Answer that, and nothing else.
    @Test("A stop above the ceiling answers with the reason alone")
    func cappedTooltipIsJustTheReason() {
        let tip = LevelRailCopy.tooltip(
            hovered: .reader,
            level: .reader,
            ceiling: .calm,
            ceilingReason: LevelCeiling.declinedAsThin,
            preference: .pinned(.reader),
            automatic: .reader
        )
        #expect(tip == LevelCeiling.declinedAsThin)
    }

    /// Resting, with no pointer on the rail, is the state the user reads by default
    /// — so it is the state that has to carry both halves: the stop the page is at,
    /// and the fact that the one they asked for is not in force here.
    @Test("A held-back level is named as such, under the stop the page actually reached")
    func restingTooltipNamesBothStops() {
        let tip = LevelRailCopy.tooltip(
            hovered: nil,
            level: .reader,
            ceiling: .calm,
            ceilingReason: LevelCeiling.declinedAsThin,
            preference: .pinned(.reader),
            automatic: .reader
        )
        #expect(tip?.hasPrefix("Calm — ") == true)
        #expect(tip?.contains("Reader is not in effect on this page.") == true)
        #expect(tip?.contains(LevelCeiling.declinedAsThin) == true)
        // Still the whole control's tooltip, not a truncated apology.
        #expect(tip?.contains("Always Reader here") == true)
        #expect(tip?.contains("⌥⌘]") == true)
    }

    @Test("Nothing is held back when the ceiling is not biting")
    func restingTooltipSaysNothingAboutHoldingBack() {
        let tip = LevelRailCopy.tooltip(
            hovered: nil,
            level: .calm,
            ceiling: .rewritten,
            ceilingReason: nil,
            preference: .auto,
            automatic: .calm
        )
        #expect(tip?.contains("not in effect") == false)
    }

    @Test("A reachable stop carries the level, the standing choice and the shortcuts")
    func reachableTooltipCarriesEverything() {
        let tip = LevelRailCopy.tooltip(
            hovered: .calm,
            level: .calm,
            ceiling: .rewritten,
            ceilingReason: nil,
            preference: .pinned(.calm),
            automatic: .reader
        )
        #expect(tip?.hasPrefix("Calm — ") == true)
        #expect(tip?.contains("Always Calm here") == true)
        #expect(tip?.contains("⌥⌘]") == true)
    }

    @Test("The accessibility value distinguishes a choice from the page's own answer")
    func accessibilityValueCarriesThePreference() {
        #expect(
            LevelRailCopy.accessibilityValue(level: .reader, ceiling: .rewritten, preference: .auto)
                == "Reader, automatic"
        )
        #expect(
            LevelRailCopy.accessibilityValue(
                level: .reader,
                ceiling: .rewritten,
                preference: .pinned(.reader)
            ) == "Reader, always Reader on this site"
        )
        #expect(
            LevelRailCopy.accessibilityValue(
                level: .calm,
                ceiling: .rewritten,
                preference: .ceiling(.calm)
            ) == "Calm, never above Calm on this site"
        )
    }

    /// The inert dot is the one mark on the rail VoiceOver cannot read, so the value
    /// is where "asked for, not in force" has to be said in words.
    @Test("The accessibility value names the page's stop first, then the request")
    func accessibilityValueNamesTheEffectiveStop() {
        #expect(
            LevelRailCopy.accessibilityValue(level: .reader, ceiling: .calm, preference: .auto)
                == "Calm, automatic, Reader not in effect on this page"
        )
    }

    /// "Automatic" is the default, and a default whose value the user cannot read is
    /// a setting they have to guess at.
    @Test("The menu's Automatic item names the level it resolves to")
    func automaticMenuItemNamesItsLevel() {
        for level in PageLevel.allCases {
            #expect(LevelRailCopy.automaticMenuTitle(level).contains(level.title))
        }
        #expect(LevelRailCopy.automaticMenuTitle(.calm) == "Automatic (Calm)")
    }
}
