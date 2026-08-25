import Testing
import ZenticKit

@testable import ZenticMac

/// What the level rail is allowed to offer, and why.
///
/// The defect these exist for: on YouTube the rail drew all five stops as
/// reachable while the page had been passed through untouched, so dragging to
/// Reader moved a control and changed nothing. The old rule asked
/// `extraction?.archetype == .app`, and that condition can never be true — the
/// bundle deliberately never posts an `extracted` event for a page it recognised
/// as an app, so the archetype the rule tested for never arrives.
@Suite("Level ceiling")
struct LevelCeilingTests {

    private func resolve(
        _ outcome: RevealOutcome?,
        rewrite: Bool = true
    ) -> (level: PageLevel, reason: String?) {
        LevelCeiling.resolve(outcome: outcome, isRewriteEnabled: rewrite)
    }

    @Test("An app passes through without extracting, and caps at Calm")
    func appCapsAtCalm() {
        // Exactly what the running app traced on a YouTube watch page: revealed
        // `passthrough`, no `extracted` event, level Reader.
        let cap = resolve(RevealOutcome(reason: .passthrough, level: .reader, confidence: nil))
        #expect(cap.level == .calm)
        #expect(cap.reason == LevelCeiling.declinedAsApp)
    }

    @Test("A page with too little prose says so, rather than being called an app")
    func thinPageHasItsOwnReason() {
        let cap = resolve(
            RevealOutcome(reason: .extractionEmpty, level: .reader, confidence: 0.9)
        )
        #expect(cap.level == .calm)
        #expect(cap.reason == LevelCeiling.declinedAsThin)
    }

    @Test("A shaky extraction says so, rather than being called an app")
    func unsureExtractionHasItsOwnReason() {
        let cap = resolve(
            RevealOutcome(
                reason: .passthrough,
                level: .reader,
                confidence: Budget.minConfidence - 0.01
            )
        )
        #expect(cap.level == .calm)
        #expect(cap.reason == LevelCeiling.declinedAsUnsure)
    }

    @Test("Nothing reported yet caps nothing — a load must not collapse the rail")
    func loadingDoesNotCap() {
        let cap = resolve(nil)
        #expect(cap.level == .rewritten)
        #expect(cap.reason == nil)
    }

    @Test("A page that rendered caps nothing")
    func renderedDoesNotCap() {
        let cap = resolve(RevealOutcome(reason: .rendered, level: .reader, confidence: 0.8))
        #expect(cap.level == .rewritten)
    }

    @Test("A pass-through below Reader is the level talking, not the page")
    func passthroughAtCalmDoesNotCap() {
        // At Calm the bundle declines every page, including the ones it would
        // rebuild. Capping here would strand the user one stop below the reader
        // with no way back up to it.
        let cap = resolve(RevealOutcome(reason: .passthrough, level: .calm, confidence: 0.9))
        #expect(cap.level == .rewritten)
        #expect(cap.reason == nil)
    }

    @Test("A confident extraction that was not allowed to render caps nothing")
    func withheldRenderDoesNotCap() {
        // An origin we leave visible on arrival, or a render that threw. Pressing
        // Reader re-plans what the page may do and runs the pipeline again, so the
        // stop is reachable and must stay offered.
        let cap = resolve(RevealOutcome(reason: .passthrough, level: .reader, confidence: 0.9))
        #expect(cap.level == .rewritten)
        #expect(cap.reason == nil)
    }

    @Test("A failsafe reveal is a budget overrun, not a verdict")
    func failsafeDoesNotCap() {
        // A render that lands after the failsafe fired arrives as a second reveal
        // saying `rendered`. Capping on the first would be a sentence the page is
        // about to contradict.
        let cap = resolve(RevealOutcome(reason: .failsafe, level: .reader, confidence: nil))
        #expect(cap.level == .rewritten)
    }

    @Test("The page's own verdict outranks the rewrite setting")
    func pageVerdictBeatsRewriteSetting() {
        let cap = resolve(
            RevealOutcome(reason: .passthrough, level: .reader, confidence: nil),
            rewrite: false
        )
        #expect(cap.level == .calm)
        #expect(cap.reason == LevelCeiling.declinedAsApp)
    }

    @Test("Rewriting off is still the answer on a page that rendered")
    func rewriteOffCapsAtReader() {
        let cap = resolve(
            RevealOutcome(reason: .rendered, level: .reader, confidence: 0.8),
            rewrite: false
        )
        #expect(cap.level == .reader)
        #expect(cap.reason == LevelCeiling.rewritingOff)
    }
}
