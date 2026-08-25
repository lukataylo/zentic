import Foundation
import Testing
import ZenticKit

@testable import ZenticMac

/// How long a page's verdict is true for.
///
/// The defect these exist for, observed on google.com. The page reported
/// `extractionEmpty` at Reader — a real verdict — and the rail capped at Calm.
/// Then the user stepped down the rail:
///
/// ```
/// revealed · extractionEmpty · 612ms   <- a verdict, at reader
/// [zentic:level] reader → calm
/// [zentic:level] calm → clean · reloading
/// revealed · passthrough · 0ms         <- at clean, correctly not a verdict
/// [zentic:level] clean → calm · reloading
/// revealed · extractionEmpty · 463ms   <- at calm, correctly not a verdict
/// [zentic:level] calm → reader
/// ```
///
/// and ended on a rail offering Reader and Rewritten on a page that had twice said
/// it has too little prose to rebuild. Two correct rules combined into a hole: the
/// verdict was cleared when a navigation started, and the only navigation that
/// followed was a reload the level change fired at a level too low to produce a
/// replacement.
///
/// The fix is the lifetime, not the rule. A verdict is a fact about a document, so
/// it is keyed to one — see ``DocumentKey`` for why that key is the URL minus its
/// fragment — and a reveal that is not a verdict is not allowed to evict one that
/// is.
@Suite("Verdict lifetime")
struct VerdictLifetimeTests {

    private let page = URL(string: "https://www.google.com/")!

    private func cap(_ memory: VerdictMemory, at url: URL?) -> (level: PageLevel, reason: String?) {
        LevelCeiling.resolve(outcome: memory.outcome(at: url), isRewriteEnabled: true)
    }

    /// The trace above, replayed event for event.
    @Test("Stepping down the rail and back does not lose the page's verdict")
    func steppingDownKeepsTheVerdict() {
        var memory = VerdictMemory()

        // revealed · extractionEmpty, reported at Reader. A verdict.
        memory.record(
            RevealOutcome(reason: .extractionEmpty, level: .reader, confidence: 0.9),
            for: page
        )
        #expect(cap(memory, at: page).level == .calm)

        // reader → calm is free. calm → clean reloads, and the reload lands at
        // Clean, where the bundle declines everything.
        memory.record(RevealOutcome(reason: .passthrough, level: .clean, confidence: nil), for: page)
        // clean → calm reloads again, and Calm declines everything too.
        memory.record(
            RevealOutcome(reason: .extractionEmpty, level: .calm, confidence: 0.9),
            for: page
        )

        // The page has not changed its mind, and neither has the rail.
        let settled = cap(memory, at: page)
        #expect(settled.level == .calm)
        #expect(settled.reason == LevelCeiling.declinedAsThin)
    }

    @Test("A reload of the same document keeps the verdict for the whole load")
    func reloadKeepsTheVerdictThroughout() {
        var memory = VerdictMemory()
        memory.record(RevealOutcome(reason: .passthrough, level: .reader, confidence: nil), for: page)

        // Mid-reload: the document is being replaced by an identical URL and no new
        // reveal has arrived. The cap must not blink off and back on, or every stop
        // is offered for the length of a load on a page that cannot reach them.
        #expect(cap(memory, at: page).reason == LevelCeiling.declinedAsApp)
    }

    @Test("A non-verdict never displaces a verdict for the same document")
    func nonVerdictDoesNotDisplace() {
        var memory = VerdictMemory()
        let verdict = RevealOutcome(reason: .extractionEmpty, level: .reader, confidence: 0.9)
        memory.record(verdict, for: page)
        memory.record(RevealOutcome(reason: .rendered, level: .calm, confidence: 0.9), for: page)

        #expect(memory.outcome(at: page) == verdict)
    }

    @Test("A non-verdict on its own is not an answer")
    func nonVerdictAloneIsNothing() {
        var memory = VerdictMemory()
        memory.record(RevealOutcome(reason: .passthrough, level: .calm, confidence: nil), for: page)

        #expect(memory.outcome(at: page) == nil)
        #expect(cap(memory, at: page).level == .rewritten)
    }

    @Test("A later verdict on the same document replaces the earlier one")
    func laterVerdictWins() {
        var memory = VerdictMemory()
        memory.record(RevealOutcome(reason: .failsafe, level: .reader, confidence: nil), for: page)
        let rendered = RevealOutcome(reason: .rendered, level: .reader, confidence: 0.8)
        memory.record(rendered, for: page)

        #expect(memory.outcome(at: page) == rendered)
    }

    @Test("Nothing reported yet is not a verdict about anything")
    func emptyMemorySaysNothing() {
        let memory = VerdictMemory()
        #expect(memory.outcome(at: page) == nil)
        #expect(memory.outcome(at: nil) == nil)
    }

    // MARK: - What counts as the same document

    @Test("A different page does not inherit the verdict")
    func navigationDiscardsTheVerdict() {
        var memory = VerdictMemory()
        memory.record(
            RevealOutcome(reason: .extractionEmpty, level: .reader, confidence: 0.9),
            for: page
        )

        let article = URL(string: "https://www.google.com/blog/post")!
        #expect(memory.outcome(at: article) == nil)
        // Fails open, like a load that has not answered yet: the rail offers every
        // stop until the new page says otherwise.
        #expect(cap(memory, at: article).level == .rewritten)
    }

    /// The SPA case. A `pushState` route change makes no new document and fires no
    /// reveal of its own at the moment it happens, so nothing clears anything — the
    /// URL simply moves and the old verdict stops describing it. The bundle re-runs
    /// its pipeline on same-document navigation and posts a fresh reveal for the new
    /// route, so the gap is a load, not a permanent amnesty.
    @Test("A route change on a single-page app is a different document")
    func spaRouteChangeDiscardsTheVerdict() {
        var memory = VerdictMemory()
        let home = URL(string: "https://www.youtube.com/")!
        let watch = URL(string: "https://www.youtube.com/watch?v=abc")!
        memory.record(RevealOutcome(reason: .passthrough, level: .reader, confidence: nil), for: home)

        #expect(memory.outcome(at: watch) == nil)

        // ...and the reveal the bundle posts for the new route answers for it.
        memory.record(RevealOutcome(reason: .passthrough, level: .reader, confidence: nil), for: watch)
        #expect(cap(memory, at: watch).reason == LevelCeiling.declinedAsApp)
    }

    /// An anchor click creates no document and produces no reveal. A key that kept
    /// the fragment would drop the verdict for the page still on screen, and the
    /// rail would start offering stops the page had already declined — invariant 8.
    @Test("An anchor on the same page is the same document")
    func fragmentIsNotANavigation() {
        var memory = VerdictMemory()
        let docs = URL(string: "https://example.com/guide")!
        memory.record(RevealOutcome(reason: .extractionEmpty, level: .reader, confidence: 0.9), for: docs)

        #expect(memory.outcome(at: URL(string: "https://example.com/guide#install")) != nil)
    }

    /// The reason the key is not host-and-path, which is what a lens plan uses: a
    /// lens matches on a path pattern, a verdict is about one page's prose.
    @Test("A different query is a different page")
    func queryIsPartOfTheDocument() {
        var memory = VerdictMemory()
        let cats = URL(string: "https://example.com/search?q=cats")!
        memory.record(RevealOutcome(reason: .extractionEmpty, level: .reader, confidence: 0.9), for: cats)

        #expect(memory.outcome(at: URL(string: "https://example.com/search?q=dogs")) == nil)
        #expect(memory.outcome(at: cats) != nil)
    }

    @Test("A verdict recorded against no URL at all is not recorded")
    func noURLIsNotADocument() {
        var memory = VerdictMemory()
        memory.record(RevealOutcome(reason: .passthrough, level: .reader, confidence: nil), for: nil)
        #expect(memory.outcome(at: nil) == nil)
        #expect(memory.outcome(at: page) == nil)
    }

    // MARK: - The key itself

    @Test("The key drops the fragment and keeps everything else")
    func keyNormalisation() {
        #expect(DocumentKey(URL(string: "https://a.com/p#x")) == DocumentKey(URL(string: "https://a.com/p")))
        #expect(DocumentKey(URL(string: "https://a.com/p?q=1")) != DocumentKey(URL(string: "https://a.com/p")))
        #expect(DocumentKey(URL(string: "https://a.com/p")) != DocumentKey(URL(string: "https://a.com/q")))
        #expect(DocumentKey(URL(string: "https://a.com/p")) != DocumentKey(URL(string: "http://a.com/p")))
        #expect(DocumentKey(nil) == nil)
    }

    /// The rule the ceiling and the memory share. Stated once so the two cannot
    /// drift into disagreeing about what an answer is.
    @Test("Only a reveal at Reader or above is an answer about the document")
    func verdictThreshold() {
        for level in PageLevel.allCases {
            let outcome = RevealOutcome(reason: .passthrough, level: level, confidence: nil)
            #expect(outcome.isVerdict == (level >= .reader))
        }
    }
}
