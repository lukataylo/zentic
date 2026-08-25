import Foundation
import Testing

@testable import ZenticKit

/// The drift accounting the toolbar and the popover are drawn from.
///
/// Every test here is a way for the chrome to say something untrue about the page
/// in front of the user: a badge that appears before the page has reported, a count
/// that includes ops from a lens that is not running, an op reported `skipped` with
/// an explanation the page never gave, an op that counts against the tally and is
/// then explained nowhere. Invariant 8 is the reason this type exists at all, so it
/// is the reason most of these tests exist.
@Suite("Lens state")
struct LensStateTests {

    // MARK: Fixtures

    /// Two regions with **different selectors**, so a test can tell "both lenses
    /// point at the same element" from "two models happened to choose the same
    /// word". Sharing one region id and one selector list throughout is what let an
    /// earlier suite pass while the popover attributed overrides across lenses by
    /// name — an attribution only the DOM could ever have made.
    func region(_ id: String = "rail", selector: String = "#secondary") -> LensRegion {
        LensRegion(id: id, intent: "the suggested videos sidebar", selectors: [selector])
    }

    func op(
        _ id: String,
        kind: LensOpKind = .hide,
        region: String = "rail",
        note: String = "hide the suggestions",
        into: String? = nil
    ) -> LensOp {
        LensOp(
            id: id,
            kind: kind,
            region: region,
            note: note,
            harvest: into.map {
                HarvestSpec(itemSelector: ":scope > li", fields: [], into: $0)
            }
        )
    }

    func lens(
        _ id: String,
        name: String? = nil,
        enabled: Bool = true,
        regions: [LensRegion]? = nil,
        ops: [LensOp],
        lastReport: LensReport? = nil
    ) -> Lens {
        Lens(
            id: id,
            name: name ?? id.capitalized,
            origin: "www.example.com",
            isEnabled: enabled,
            prompt: "hide the suggestions",
            regions: regions ?? [region()],
            ops: ops,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            lastReport: lastReport
        )
    }

    func report(_ lensID: String, _ results: [LensOpResult], path: String = "/watch") -> LensReport {
        LensReport(
            lensID: lensID,
            url: path,
            results: results,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: Aggregation

    @Test("no report means no badge, never an optimistic one")
    func silentUntilThePageSpeaks() {
        let state = LensState.make(lenses: [lens("a", ops: [op("1"), op("2")])], reports: [:])

        #expect(state.hasLenses)
        #expect(state.isActive)
        #expect(!state.hasReport)
        // The lens declares two ops. Reporting `0/2` would be a claim about a page
        // that has not answered, and `2/2` would be a fabrication.
        #expect(state.tally == nil)
        #expect(state.totalCount == 0)
    }

    @Test("an empty result list is not a report")
    func emptyResultsIsNotAReport() {
        // What an engine that bailed before the op pass sends. It used to produce
        // `hasReport == true` and a `0/0` badge, which reads as "these lenses ran
        // and did nothing" — a claim about the page that nothing on the page made.
        let state = LensState.make(
            lenses: [lens("a", ops: [op("1")])],
            reports: ["a": report("a", [])]
        )

        #expect(!state.hasReport)
        #expect(state.tally == nil)
        #expect(state.entries[0].tally == nil)
        #expect(!state.entries[0].isDrifted)
    }

    @Test("counts come from the report, not from the lens's op list")
    func countsFollowTheReport() {
        // Four ops saved, three reported: the page ran an older shape of the lens,
        // or stopped early. The badge has to describe what ran.
        let lens = lens("a", ops: [op("1"), op("2"), op("3"), op("4")])
        let state = LensState.make(
            lenses: [lens],
            reports: [
                "a": report(
                    "a",
                    [
                        LensOpResult(opID: "1", status: .applied, matchedCount: 1),
                        LensOpResult(opID: "2", status: .applied, matchedCount: 1),
                        LensOpResult(opID: "3", status: .missed),
                    ]
                )
            ]
        )

        #expect(state.tally == "2/3")
        #expect(state.missedCount == 1)
        #expect(state.isDrifted)
    }

    @Test("a report for a lens that is not applied here is not counted")
    func reportForAnUnknownLensIsIgnored() {
        // Routine, not exotic: the page keeps running the set it was given until it
        // reloads, so a lens deleted or switched off in another window keeps
        // reporting. Its ops are not on this page's list, so they are not on this
        // page's badge.
        let state = LensState.make(
            lenses: [lens("a", ops: [op("1")])],
            reports: [
                "a": report("a", [LensOpResult(opID: "1", status: .applied, matchedCount: 1)]),
                "ghost": report("ghost", [LensOpResult(opID: "9", status: .missed)]),
            ]
        )

        #expect(state.entries.count == 1)
        #expect(state.tally == "1/1")
        #expect(!state.isDrifted)
    }

    @Test("op ids the lens no longer holds produce no rows")
    func reportNamingUnknownOpsExplainsNothing() {
        // The other half of the same race: the page reports the shape it was handed,
        // and this window has already edited it. The counts are the page's, because
        // the page is what is on screen — but a line in the popover is an op's own
        // `note`, and there is no note for an op that is not here any more.
        let state = LensState.make(
            lenses: [lens("a", ops: [op("1")])],
            reports: [
                "a": report(
                    "a",
                    [
                        LensOpResult(opID: "gone", status: .missed),
                        LensOpResult(opID: "also-gone", status: .skipped, message: "budget"),
                    ]
                )
            ]
        )

        let entry = state.entries[0]
        #expect(entry.tally == "0/2")
        #expect(entry.notes.isEmpty)
        // Amber with nothing to list, which is exactly when Re-fit has to be
        // reachable — it was not, because the button hung off the missed notes.
        #expect(entry.isDrifted)
        #expect(entry.canRefit)
    }

    @Test("two lenses sum into one badge, and each keeps its own tally")
    func perLensBreakdown() {
        let first = lens("a", name: "Focus", ops: [op("1"), op("2")])
        let second = lens("b", name: "Wide", ops: [op("3", kind: .width)])
        let state = LensState.make(
            lenses: [first, second],
            reports: [
                "a": report(
                    "a",
                    [
                        LensOpResult(opID: "1", status: .applied, matchedCount: 1),
                        LensOpResult(opID: "2", status: .missed),
                    ]
                ),
                "b": report("b", [LensOpResult(opID: "3", status: .applied, matchedCount: 1)]),
            ]
        )

        #expect(state.tally == "2/3")
        #expect(state.entries.map(\.tally) == ["1/2", "1/1"])
        #expect(state.entries.map(\.isDrifted) == [true, false])
        // The drift row names the op in the user's own words, which is the only
        // description of a stale selector they can act on.
        #expect(state.entries[0].notes.filter(\.isDrift).map(\.note) == ["hide the suggestions"])
        #expect(state.entries[1].notes.allSatisfy { !$0.isDrift })
    }

    @Test("a lens that has not reported contributes nothing to the badge")
    func partialReportsDoNotInventTotals() {
        let state = LensState.make(
            lenses: [lens("a", ops: [op("1")]), lens("b", ops: [op("2"), op("3")])],
            reports: ["a": report("a", [LensOpResult(opID: "1", status: .applied, matchedCount: 1)])]
        )

        #expect(state.tally == "1/1")
        #expect(state.entries[1].tally == nil)
    }

    @Test("yesterday's drift is kept out of today's badge")
    func storedReportIsNotCounted() {
        // `Lens.lastReport` describes a page load that is over, possibly on another
        // URL entirely — a `*` lens's stored report is routinely about a different
        // page of the site. The popover reads it off the lens and says so in the
        // past tense; nothing about it may reach a count.
        let stored = report("a", [LensOpResult(opID: "1", status: .missed)])
        let state = LensState.make(lenses: [lens("a", ops: [op("1")], lastReport: stored)], reports: [:])

        #expect(state.entries[0].lens.lastReport == stored)
        #expect(state.entries[0].notes.isEmpty)
        #expect(state.tally == nil)
        #expect(!state.isDrifted)
    }

    @Test("a site whose lenses are all off has lenses but is not active")
    func disabledSiteStillHasLenses() {
        let state = LensState.make(
            lenses: [],
            reports: [:],
            siteLensCount: 2,
            enabledLensCount: 0
        )

        #expect(state.hasLenses)
        #expect(!state.isActive)
        #expect(state.tally == nil)
        // Nothing is switched on, so nothing is merely scoped elsewhere — the
        // toolbar's two sentences turn on this difference.
        #expect(state.offPathCount == 0)
    }

    @Test("a lens on but scoped to another path is not a lens switched off")
    func offPathLensesAreCounted() {
        let state = LensState.make(
            lenses: [],
            reports: [:],
            siteLensCount: 3,
            enabledLensCount: 2
        )

        #expect(!state.isActive)
        #expect(state.offPathCount == 2)
    }

    // MARK: The reader's own render is on screen

    @Test("under the reader there is no count that is true, so there is no badge")
    func suppressedLensShowsNoTally() {
        // What the engine sends from a restructured page: every op `skipped`, with
        // the reason, because the ops resolved against a document the user cannot
        // see. Honest — and drawn as `0/4` in the "this is working" tint, which reads
        // as four changes that failed.
        let suppressed =
            "the reader is showing its own render; this lens applies to the original page"
        let lens = lens("a", name: "Focus", ops: [op("1"), op("2"), op("3"), op("4")])
        let state = LensState.make(
            lenses: [lens],
            reports: [
                "a": report("a", lens.ops.map { LensOpResult(opID: $0.id, status: .skipped, message: suppressed) })
            ],
            isReaderRendered: true
        )

        #expect(state.isSuppressed)
        #expect(state.tally == nil)
        #expect(state.entries[0].tally == nil)
        #expect(state.totalCount == 0)
        #expect(state.appliedCount == 0)
        // Not drift and not a repair job: the selectors are fine, the page they act
        // on is behind the reader's render.
        #expect(!state.isDrifted)
        #expect(!state.entries[0].canRefit)
        // Said once, about the lens, rather than once per op.
        #expect(state.entries[0].notes.isEmpty)
        #expect(state.suppressionReason == suppressed)
    }

    @Test("a report from before the switch cannot claim an effect under the reader")
    func staleAppliedReportIsSuppressedToo() {
        // Reports arrive coalesced and late, so one saying everything applied lands
        // routinely just after ⌘\. Repeating it then puts `4/4 applied` over a render
        // showing none of it — invariant 8's failure, from the other direction.
        let lens = lens("a", name: "Focus", ops: [op("1"), op("2")])
        let reports = [
            "a": report(
                "a",
                [
                    LensOpResult(opID: "1", status: .applied, matchedCount: 1),
                    LensOpResult(opID: "2", status: .applied, matchedCount: 1),
                ]
            )
        ]

        let reader = LensState.make(lenses: [lens], reports: reports, isReaderRendered: true)
        #expect(reader.isSuppressed)
        #expect(reader.tally == nil)
        // A page that ran some of the lens is not describing suppression, so there is
        // no sentence of the page's to quote — the UI supplies its own.
        #expect(reader.suppressionReason == nil)

        // The same reports, on the page the lens actually acts on.
        let original = LensState.make(lenses: [lens], reports: reports, isReaderRendered: false)
        #expect(!original.isSuppressed)
        #expect(original.tally == "2/2")
    }

    @Test("only a report that is entirely skips is the page explaining suppression")
    func aBudgetSkipIsNotTheSuppressionSentence() {
        // The engine ran two ops on the site's own page, hit the op budget, and
        // skipped the rest with its own reason. Then the user pressed ⌘\. The
        // suppression sentence is rendered verbatim, so a report that is only
        // *partly* skipped would put "the op budget for this page is used up" under
        // a lens as the explanation for why none of it is visible — an answer to a
        // question the user did not ask, about a thing that is not what happened.
        let lens = lens("a", name: "Focus", ops: [op("1"), op("2"), op("3")])
        let mixed = LensState.make(
            lenses: [lens],
            reports: [
                "a": report(
                    "a",
                    [
                        LensOpResult(opID: "1", status: .applied, matchedCount: 1),
                        LensOpResult(
                            opID: "2",
                            status: .skipped,
                            message: "the op budget for this page is used up"
                        ),
                        LensOpResult(
                            opID: "3",
                            status: .skipped,
                            message: "the op budget for this page is used up"
                        ),
                    ]
                )
            ],
            isReaderRendered: true
        )

        #expect(mixed.isSuppressed)
        #expect(mixed.suppressionReason == nil)

        // The whole report skipped is the page describing suppression, and then its
        // own words are the ones shown.
        let reason = "the reader is showing its own render"
        let whole = LensState.make(
            lenses: [lens],
            reports: [
                "a": report("a", lens.ops.map { LensOpResult(opID: $0.id, status: .skipped, message: reason) })
            ],
            isReaderRendered: true
        )
        #expect(whole.suppressionReason == reason)
    }

    @Test("suppression is not drift, whatever the page reported before the switch")
    func suppressionOutranksDrift() {
        let lens = lens("a", name: "Focus", ops: [op("1"), op("2")])
        let reports = [
            "a": report(
                "a",
                [
                    LensOpResult(opID: "1", status: .applied, matchedCount: 1),
                    LensOpResult(opID: "2", status: .missed),
                ]
            )
        ]

        let reader = LensState.make(lenses: [lens], reports: reports, isReaderRendered: true)
        // Amber over a page where nothing was even attempted sends the user to Re-fit
        // a lens that has not been given a page to run on.
        #expect(!reader.isDrifted)
        #expect(reader.missedCount == 0)
        #expect(!reader.entries[0].canRefit)
        // And no per-op lines either. They used to survive suppression, so a row
        // that was not drifted — `isDrifted` is false here — still drew its stale
        // misses in amber underneath, which is the claim the suppression state
        // exists to stop the chrome making.
        #expect(reader.entries[0].notes.isEmpty)

        #expect(LensState.make(lenses: [lens], reports: reports, isReaderRendered: false).isDrifted)
    }

    @Test("a site with no lens running is not suppressed, it is just quiet")
    func nothingActiveIsNotSuppression() {
        // Suppression is a claim that there is something to see on the other side of
        // ⌘\. With nothing applied there is not, and the toolbar has its own sentence
        // for that.
        let state = LensState.make(
            lenses: [],
            reports: [:],
            siteLensCount: 2,
            enabledLensCount: 0,
            isReaderRendered: true
        )

        #expect(!state.isSuppressed)
        #expect(state.hasLenses)
        #expect(!state.isActive)
    }

    @Test("a drifted lens can be re-fitted whether or not it lists a note")
    func refitFollowsDriftAlone() {
        // `canRefit` used to also require the lens to have regions, which is true of
        // every lens that can be stored — so the term only made the rule look like it
        // had two halves that could disagree.
        let state = LensState.make(
            lenses: [lens("a", regions: [], ops: [op("1")])],
            reports: ["a": report("a", [LensOpResult(opID: "1", status: .missed)])]
        )

        #expect(state.entries[0].isDrifted)
        #expect(state.entries[0].canRefit)
    }

    // MARK: What the page said, and whether the user ever sees it

    @Test("every op status the page can report reaches the user")
    func everyStatusReachesTheUser() throws {
        // Driven from the enum, not from a list written by hand, so a status added
        // to `LensOpStatus` fails here until something renders it. That is the
        // whole point: `ambiguous` and `failed` were both producible by `ops.ts`
        // and drawn by nothing, so an op that matched three elements or threw
        // counted against the badge — `3/4` — and then appeared nowhere at all.
        //
        // `LensPopover` draws one line per `OpNote`, unconditionally, and the
        // tally for `applied`. Those are the two treatments this asserts into.
        for status in LensOpStatus.allCases {
            let state = LensState.make(
                lenses: [lens("a", ops: [op("1")])],
                reports: ["a": report("a", [LensOpResult(opID: "1", status: status)])]
            )
            let entry = try #require(state.entries.first)

            if status == .applied {
                #expect(entry.tally == "1/1", "applied is missing from the tally")
                #expect(entry.notes.isEmpty, "an applied op needs no explanation")
                continue
            }

            let note = try #require(entry.notes.first, "\(status) is rendered nowhere")
            #expect(note.status == status)
            #expect(note.note == "hide the suggestions", "the line has to be in the user's words")
            #expect(!note.detail.isEmpty, "\(status) draws a line with nothing on it")
        }
    }

    @Test("only drift is drawn as drift")
    func onlyMissedIsDrift() {
        // The four unapplied statuses are not one thing. `missed` means the site
        // changed and Re-fit is the answer; the other three are the page saying
        // what it did with an op, and offering Re-fit for them would send the user
        // to a model call that repairs nothing.
        let state = LensState.make(
            lenses: [lens("a", ops: [op("1"), op("2"), op("3"), op("4")])],
            reports: [
                "a": report(
                    "a",
                    [
                        LensOpResult(opID: "1", status: .missed),
                        LensOpResult(opID: "2", status: .ambiguous),
                        LensOpResult(opID: "3", status: .skipped),
                        LensOpResult(opID: "4", status: .failed),
                    ]
                )
            ]
        )

        let entry = state.entries[0]
        #expect(entry.notes.map(\.isDrift) == [true, false, false, false])
        #expect(entry.notes.filter(\.isDrift).map(\.opID) == ["1"])
        #expect(entry.isDrifted)
        #expect(entry.canRefit)
    }

    @Test("the page's own explanation is the explanation")
    func pageMessageWins() {
        // Every op skipped for one reason the engine gave. The engine is the only
        // half that knows what happened — it resolved the selectors and it is the
        // one that ran out of budget — so its sentence goes through verbatim. What
        // used to happen instead was a locally synthesised winner, which on any
        // restructured page told the user their own ops had overridden each other
        // when the pass had never run one of them.
        let suppressed = "the op pass ran out of budget before this op"
        let state = LensState.make(
            lenses: [lens("a", name: "Focus", ops: [op("1"), op("2", kind: .keep)])],
            reports: [
                "a": report(
                    "a",
                    [
                        LensOpResult(opID: "1", status: .skipped, message: suppressed),
                        LensOpResult(opID: "2", status: .skipped, message: suppressed),
                    ]
                )
            ]
        )

        let notes = state.entries[0].notes
        #expect(notes.count == 2)
        #expect(notes.allSatisfy { $0.detail == suppressed })
    }

    @Test("a budget skip is not blamed on a lens")
    func budgetSkipIsNotAttributed() {
        // `op pass exceeded 120ms` has nothing to do with the second lens. It was
        // blamed on it anyway, because a conflicting op existed somewhere later in
        // the set and a local scan by region name was consulted first — and region
        // ids are lens-local, so that scan was naming a lens at random.
        let state = LensState.make(
            lenses: [lens("a", name: "Focus", ops: [op("1")]), lens("b", name: "Wide", ops: [op("2")])],
            reports: [
                "a": report(
                    "a",
                    [LensOpResult(opID: "1", status: .skipped, message: "op pass exceeded 120ms")]
                )
            ]
        )

        #expect(state.entries[0].notes.first?.detail == "op pass exceeded 120ms")
    }

    @Test("the engine's cross-lens attribution is rendered verbatim")
    func crossLensAttributionComesFromThePage() {
        // Two lenses whose differently-named regions resolve to one element, with
        // the message the engine actually sends. Naming B is a conclusion only the
        // DOM could reach: the app sees two lenses calling two different things
        // `main` and `rail`, and no scan over that can get here.
        let a = lens("a", name: "A", regions: [region("main", selector: "#x")], ops: [op("1", region: "main")])
        let b = lens("b", name: "B", regions: [region("rail", selector: "#x")], ops: [op("2", region: "rail")])
        let state = LensState.make(
            lenses: [a, b],
            reports: [
                "a": report(
                    "a",
                    [
                        LensOpResult(
                            opID: "1",
                            status: .skipped,
                            message: #"overridden by "hide the suggestions" in lens "B""#
                        )
                    ]
                )
            ]
        )

        #expect(
            state.entries[0].notes.first?.detail
                == #"overridden by "hide the suggestions" in lens "B""#
        )
    }

    @Test("drift says what the user can act on, not what the engine measured")
    func driftIsExplainedInTheUsersTerms() {
        // The one status where our sentence beats the page's. `ops.ts` says "region
        // matched nothing", which is true and describes a mechanism; the user needs
        // to know the site changed under a lens they wrote. Every other status
        // keeps the page's wording, because for those the page knows something we
        // do not.
        let state = LensState.make(
            lenses: [lens("a", ops: [op("1")])],
            reports: [
                "a": report(
                    "a",
                    [LensOpResult(opID: "1", status: .missed, message: "region matched nothing")]
                )
            ]
        )

        #expect(state.entries[0].notes.first?.detail == "no longer matches this page")
    }

    @Test("a report naming ops the lens no longer holds explains nothing")
    func notesFollowTheLensNotTheReport() {
        // The page runs the shape of the lens it was handed until it reloads, so
        // after an edit in another window it can report op ids that are not in the
        // lens any more. There is no note for an op that is not here, and inventing
        // one from the report's own strings would put a selector where a sentence
        // belongs.
        let state = LensState.make(
            lenses: [lens("a", ops: [op("1")])],
            reports: [
                "a": report(
                    "a",
                    [
                        LensOpResult(opID: "gone", status: .missed),
                        LensOpResult(opID: "1", status: .skipped, message: "budget"),
                    ]
                )
            ]
        )

        #expect(state.entries[0].notes.map(\.opID) == ["1"])
        // The count still comes from the report, because the page really did try to
        // run two ops. This is the drift-with-nothing-to-list state the popover has
        // its own line for.
        #expect(state.entries[0].missedCount == 1)
        #expect(state.entries[0].notes.allSatisfy { !$0.isDrift })
    }

    // MARK: One reason per group, not one per row

    @Test("ops that stopped matching are one group with the reason said once")
    func driftIsOneGroupWithOneReason() throws {
        // The complaint this grouping exists for: three drifted ops drew three lines
        // each ending "— no longer matches this page", in amber, which buries the
        // only text on a row that differs — the op's own sentence.
        let state = LensState.make(
            lenses: [
                lens(
                    "a",
                    ops: [
                        op("1", note: "hide the suggestions rail"),
                        op("2", note: "hide the comments"),
                        op("3", note: "hide the end screen"),
                    ]
                )
            ],
            reports: [
                "a": report(
                    "a",
                    [
                        LensOpResult(opID: "1", status: .missed),
                        LensOpResult(opID: "2", status: .missed),
                        LensOpResult(opID: "3", status: .missed),
                    ]
                )
            ]
        )

        let groups = try #require(state.entries.first?.noteGroups)
        #expect(groups.count == 1)
        #expect(groups[0].isDrift)
        #expect(groups[0].count == 3)
        #expect(groups[0].title == "3 changes no longer match this page")
        #expect(
            groups[0].notes.map(\.note) == [
                "hide the suggestions rail", "hide the comments", "hide the end screen",
            ]
        )
        // The heading is the reason. Nothing is left for a row to repeat.
        #expect(groups[0].notes.allSatisfy { $0.detail == "no longer matches this page" })
    }

    @Test("one drifted op is counted in the singular")
    func oneDriftReadsAsOne() throws {
        let state = LensState.make(
            lenses: [lens("a", ops: [op("1"), op("2")])],
            reports: [
                "a": report(
                    "a",
                    [
                        LensOpResult(opID: "1", status: .applied, matchedCount: 1),
                        LensOpResult(opID: "2", status: .missed),
                    ]
                )
            ]
        )

        #expect(
            state.entries[0].noteGroups.first?.title == "1 change no longer matches this page"
        )
    }

    @Test("two different reasons are two groups, and drift leads")
    func groupsSplitOnTheReasonAndDriftComesFirst() throws {
        // Grouping on the status alone would fold two budget messages under one
        // heading that is true of neither. Grouping on the reason keeps them apart,
        // and drift is hoisted because it is the only group with a repair attached.
        let budget = "the op pass ran out of budget before this op"
        let state = LensState.make(
            lenses: [
                lens(
                    "a",
                    ops: [
                        op("1", note: "widen the player"),
                        op("2", note: "hide the comments"),
                        op("3", note: "hide the end screen"),
                        op("4", note: "hide the suggestions rail"),
                    ]
                )
            ],
            reports: [
                "a": report(
                    "a",
                    [
                        LensOpResult(opID: "1", status: .skipped, message: budget),
                        LensOpResult(opID: "2", status: .skipped, message: budget),
                        LensOpResult(opID: "3", status: .ambiguous, message: "matched 4 places"),
                        LensOpResult(opID: "4", status: .missed),
                    ]
                )
            ]
        )

        let groups = state.entries[0].noteGroups
        #expect(groups.map(\.status) == [.missed, .skipped, .ambiguous])
        #expect(groups.map(\.count) == [1, 2, 1])
        // The engine's sentence goes through verbatim, with the count set off rather
        // than folded into a clause we would have to conjugate for it.
        #expect(groups[1].title == "2 changes — \(budget)")
        #expect(groups[2].title == "1 change — matched 4 places")
        #expect(groups.filter(\.isDrift).count == 1)
    }

    @Test("a group counts what the page said, not only what the lens can name")
    func aGroupCountsThePagesReport() throws {
        // The page runs the shape of the lens it was handed until it reloads, so
        // after an edit in another window it reports op ids this lens no longer
        // holds. The heading has to agree with the tally beside the lens's name —
        // counting the rows instead would print `1` under a `0/2`.
        let state = LensState.make(
            lenses: [lens("a", ops: [op("1", note: "hide the comments")])],
            reports: [
                "a": report(
                    "a",
                    [
                        LensOpResult(opID: "1", status: .missed),
                        LensOpResult(opID: "gone", status: .missed),
                    ]
                )
            ]
        )

        let group = try #require(state.entries[0].noteGroups.first)
        #expect(group.count == 2)
        #expect(group.notes.map(\.opID) == ["1"])
        #expect(group.hasUnnamed)
        #expect(group.title == "2 changes no longer match this page")
    }

    @Test("drift with nothing to name is still a group, so Re-fit stays reachable")
    func driftWithNoNamedOpsIsStillAGroup() throws {
        let state = LensState.make(
            lenses: [lens("a", ops: [op("1")])],
            reports: ["a": report("a", [LensOpResult(opID: "gone", status: .missed)])]
        )

        let group = try #require(state.entries[0].noteGroups.first)
        #expect(group.isDrift)
        #expect(group.notes.isEmpty)
        #expect(group.count == 1)
        #expect(group.hasUnnamed)
        #expect(state.entries[0].canRefit)
    }

    @Test("under the reader there are no groups, because there is nothing to explain")
    func suppressionDrawsNoGroups() {
        let lens = lens("a", ops: [op("1"), op("2")])
        let state = LensState.make(
            lenses: [lens],
            reports: [
                "a": report(
                    "a",
                    lens.ops.map { LensOpResult(opID: $0.id, status: .skipped, message: "reader") }
                )
            ],
            isReaderRendered: true
        )

        #expect(state.entries[0].noteGroups.isEmpty)
    }

    // MARK: Which anchor was tried

    @Test("a drifted op names the anchor the lens looked for")
    func driftNamesWhatWasTried() {
        // `usedSelector` is unset on a miss, because nothing resolved — so the fact
        // worth showing is the lens's own first candidate. Which anchor was tried is
        // what decides whether Re-fit is the answer or the lens wants editing, and it
        // was carried on every result and drawn nowhere.
        let state = LensState.make(
            lenses: [lens("a", regions: [region("rail", selector: "#secondary")], ops: [op("1")])],
            reports: ["a": report("a", [LensOpResult(opID: "1", status: .missed)])]
        )

        #expect(state.entries[0].notes.first?.anchor == .tried("#secondary"))
    }

    @Test("the page's own selector wins wherever it sent one")
    func thePagesSelectorWins() {
        // The engine resolved it against a live DOM; no scan on this side can work
        // out which of a dozen candidates won.
        let state = LensState.make(
            lenses: [lens("a", regions: [region("rail", selector: "#secondary")], ops: [op("1")])],
            reports: [
                "a": report(
                    "a",
                    [
                        LensOpResult(
                            opID: "1",
                            status: .ambiguous,
                            matchedCount: 3,
                            usedSelector: "ytd-watch-next-secondary-results-renderer"
                        )
                    ]
                )
            ]
        )

        #expect(
            state.entries[0].notes.first?.anchor
                == .matched("ytd-watch-next-secondary-results-renderer")
        )
    }

    @Test("an op the pass never reached names no anchor")
    func aBudgetSkipClaimsNoAttempt() {
        // The fallback is confined to `missed`, where the resolver demonstrably ran
        // and came back empty. A budget skip never looked at a selector at all, and
        // printing one as "tried" would describe an attempt the page never made.
        let state = LensState.make(
            lenses: [lens("a", ops: [op("1")])],
            reports: [
                "a": report("a", [LensOpResult(opID: "1", status: .skipped, message: "budget")])
            ]
        )

        #expect(state.entries[0].notes.first?.anchor == nil)
    }

    // MARK: Where a lens stands

    @Test("standing separates a stale op from a lens that has stopped landing")
    func standingSeparatesPartialDriftFromTotal() {
        // The distinction the whole surface exists to draw: `5/6` and `0/6` are four
        // characters apart and were rendered identically — same amber, same chip,
        // same button.
        let partly = LensState.make(
            lenses: [lens("a", ops: [op("1"), op("2"), op("3")])],
            reports: [
                "a": report(
                    "a",
                    [
                        LensOpResult(opID: "1", status: .applied, matchedCount: 1),
                        LensOpResult(opID: "2", status: .applied, matchedCount: 1),
                        LensOpResult(opID: "3", status: .missed),
                    ]
                )
            ]
        )
        #expect(partly.standing == .drifting(missed: 1, of: 3))
        #expect(partly.entries[0].standing == .drifting(missed: 1, of: 3))
        #expect(partly.standing.needsAttention)

        let dead = LensState.make(
            lenses: [lens("a", ops: [op("1"), op("2"), op("3")])],
            reports: [
                "a": report(
                    "a",
                    [
                        LensOpResult(opID: "1", status: .missed),
                        LensOpResult(opID: "2", status: .missed),
                        LensOpResult(opID: "3", status: .missed),
                    ]
                )
            ]
        )
        #expect(dead.standing == .stopped(of: 3))
        #expect(dead.standing.needsAttention)
    }

    @Test("holding counts what applied, not what did not drift")
    func holdingCountsTheAppliedOps() {
        // An op can be skipped or ambiguous without any selector having gone stale.
        // Deriving the applied count as `total - missed` would report `2 of 2
        // applied` for a lens the page only ran half of.
        let state = LensState.make(
            lenses: [lens("a", ops: [op("1"), op("2")])],
            reports: [
                "a": report(
                    "a",
                    [
                        LensOpResult(opID: "1", status: .applied, matchedCount: 1),
                        LensOpResult(opID: "2", status: .skipped, message: "budget"),
                    ]
                )
            ]
        )

        #expect(state.standing == .holding(applied: 1, of: 2))
        // Nothing here is a warning about the site, so nothing here is amber.
        #expect(!state.standing.needsAttention)
    }

    @Test("silence and suppression are states, not a lens at zero")
    func standingBeforeAndBehindTheRender() {
        let lens = lens("a", ops: [op("1"), op("2")])
        #expect(LensState.make(lenses: [lens], reports: [:]).standing == .silent)

        let reports = [
            "a": report(
                "a",
                [
                    LensOpResult(opID: "1", status: .applied, matchedCount: 1),
                    LensOpResult(opID: "2", status: .missed),
                ]
            )
        ]
        // Suppression outranks the report it arrived with. Without that, a lens that
        // is perfectly fine lands in `.silent` under the reader and reads as a lens
        // nothing has been heard from — and a drifted one keeps asking to be repaired
        // on a page it was never given a chance to run on.
        let reader = LensState.make(lenses: [lens], reports: reports, isReaderRendered: true)
        #expect(reader.standing == .suppressed)
        #expect(!reader.standing.needsAttention)
        #expect(reader.entries[0].standing == .suppressed)
    }

    // MARK: Which page a report describes

    @Test("a report is matched to the page by path, and only by path")
    func reportsAreMatchedByPath() {
        // `LensReport.url` is a pathname: the engine strips the query before it
        // leaves the page, because the report is persisted into a file that is
        // still there next week.
        let report = report("a", [], path: "/watch")

        #expect(report.describes(URL(string: "https://www.example.com/watch")))
        // A query and a fragment are the same page. A different path is not.
        #expect(report.describes(URL(string: "https://www.example.com/watch?v=1#t=30")))
        #expect(!report.describes(URL(string: "https://www.example.com/results")))
        #expect(!report.describes(nil))
    }

    @Test("the root is the root however it is spelled")
    func rootPathsAgree() {
        // `location.pathname` is "/" and `URL.path()` on a bare origin is "", which
        // is a disagreement that would drop every report on a site's front page.
        #expect(report("a", [], path: "/").describes(URL(string: "https://www.example.com")))
        #expect(report("a", [], path: "/").describes(URL(string: "https://www.example.com/")))
        // A trailing slash is not a different page either, on either side.
        #expect(report("a", [], path: "/watch/").describes(URL(string: "https://www.example.com/watch")))
    }
}

// MARK: - Saving what the editor sends back

/// The one decision that turns Save into an edit rather than a duplicate.
@Suite("Lens draft save")
struct LensDraftSaveTests {

    static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "lens-draft-\(UUID().uuidString).json")
    }

    static func lens(_ id: String, name: String, ops: [LensOp]) -> Lens {
        Lens(
            id: id,
            name: name,
            origin: "www.example.com",
            prompt: "hide the suggestions",
            regions: [
                LensRegion(id: "rail", intent: "the suggestions rail", selectors: ["#secondary"])
            ],
            ops: ops,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }

    static func op(_ id: String, note: String = "hide the suggestions") -> LensOp {
        LensOp(id: id, kind: .hide, region: "rail", note: note)
    }

    /// What the page said was on it. `#secondary` and nothing else, which is what
    /// a real catalog is: a list of anchors that exist.
    static let catalog = RegionCatalog(
        origin: "www.example.com",
        pathPattern: "*",
        viewport: .init(width: 1280, height: 900),
        candidates: [
            RegionCandidate(
                id: "r0",
                selector: "#secondary",
                tag: "div",
                elementID: "secondary",
                kindGuess: "aside",
                rect: RegionRect(x: 980, y: 0, width: 300, height: 2_000),
                depth: 5,
                textLength: 4_000,
                linkCount: 40,
                paragraphCount: 2,
                imageCount: 12,
                itemCount: 0
            )
        ]
    )

    @Test("a draft carrying a known id replaces that lens")
    func editReplacesInPlace() async throws {
        let store = LensStore(url: Self.temporaryURL())
        let original = Self.lens("keep-me", name: "Focus", ops: [Self.op("1")])
        try await store.save(original)
        // Something else on the site, so the edited lens has a position in a list
        // rather than being simply "the only one".
        try await store.save(Self.lens("other", name: "Wide", ops: [Self.op("2")]))

        var draft = original
        draft.name = "Focus II"
        draft.ops = [Self.op("1", note: "hide the suggestions rail")]
        // What the page sends is not a record: the editor has no idea when the lens
        // was created and must not be able to say. `updatedAt` is the list order
        // now, so a page that could name its own would pin its lens to the top of
        // the user's list for good.
        draft.createdAt = Date(timeIntervalSince1970: 9_999)
        draft.updatedAt = Date(timeIntervalSince1970: 9_999)
        draft.origin = "evil.example.com"

        let saved = try await store.save(draft: draft, origin: "www.example.com", against: Self.catalog)
        let all = await store.all()

        // One lens, not two — this is the whole bug: Save used to insert beside the
        // original, leaving both enabled and every op running twice.
        #expect(all.count == 2)
        #expect(all.map(\.id).sorted() == ["keep-me", "other"])
        #expect(saved.name == "Focus II")
        #expect(saved.createdAt == original.createdAt)
        #expect(saved.updatedAt != Date(timeIntervalSince1970: 9_999))
        #expect(saved.origin == "www.example.com")
        #expect(saved.ops.map(\.note) == ["hide the suggestions rail"])
    }

    @Test("a draft carrying an unknown id is a new lens, listed first")
    func authoringInserts() async throws {
        let store = LensStore(url: Self.temporaryURL())
        let first = Self.lens("first", name: "Focus", ops: [Self.op("1")])
        try await store.save(first)

        let draft = Self.lens("fresh", name: "Reading", ops: [Self.op("2")])
        let saved = try await store.save(draft: draft, origin: "www.example.com", against: Self.catalog)

        #expect(await store.all().map(\.id) == ["fresh", "first"])
        #expect(saved.createdAt != first.createdAt)
    }

    @Test("a draft cannot claim a lens saved for another site")
    func draftCannotStealAnotherSitesLens() async throws {
        let store = LensStore(url: Self.temporaryURL())
        var elsewhere = Self.lens("shared-id", name: "Focus", ops: [Self.op("1")])
        elsewhere.origin = "bank.example.com"
        try await store.save(elsewhere)

        // The id on a draft is chosen by the page, and events travel page → app.
        var draft = Self.lens("shared-id", name: "Mine", ops: [Self.op("2")])
        draft.origin = "attacker.example.com"

        await #expect(throws: LensStoreError.self) {
            try await store.save(draft: draft, origin: "attacker.example.com", against: Self.catalog)
        }
        // Untouched, and still on the site it was written for.
        let stored = await store.lens(id: "shared-id")
        #expect(stored?.name == "Focus")
        #expect(stored?.origin == "bank.example.com")
    }

    @Test("a saved draft drops the report of the shape it replaced")
    func editingClearsTheStoredReport() async throws {
        let store = LensStore(url: Self.temporaryURL())
        let original = Self.lens("a", name: "Focus", ops: [Self.op("1")])
        try await store.save(original)
        await store.recordReport(
            LensReport(
                lensID: "a",
                url: "/watch",
                results: [LensOpResult(opID: "1", status: .missed)],
                generatedAt: Date(timeIntervalSince1970: 0)
            )
        )

        var draft = original
        draft.ops = [Self.op("2")]
        let saved = try await store.save(draft: draft, origin: "www.example.com", against: Self.catalog)

        // The report counts ops by id, and the ids it counted are not in the lens
        // any more. Keeping it would badge the repaired lens as drifted.
        #expect(saved.lastReport == nil)
    }

    // MARK: The breadth gate on the draft path

    @Test("a draft naming the whole page is refused, in every spelling of it")
    func draftCannotBlankThePage() async throws {
        // The ship-blocker, and the one this pass came closest to reopening.
        //
        // Breadth used to be decided by a 230-line hand-rolled CSS parser: it found
        // the subject compound of a selector, broke it into simple selectors, and
        // asked whether anything in it *narrowed*. That is what caught `:is(body)`,
        // `*:not(.keep)` and `body.dark`, all of which compile to
        // `{display:none!important}` on an element containing the whole page. The
        // parser is gone, and `LensToken.regionSelector` now rejects only the four
        // literal spellings a typo produces — which is enough for a lens read back
        // off the user's own disk and nothing like enough for a page talking to us.
        //
        // What replaced it on this path is the catalog: a draft may only name an
        // anchor the page said it had, and no page offers `:is(body)`. Validating
        // this path with `catalog: nil` — which is what it did — put the hole back
        // precisely where the parser had been standing.
        for selector in [":is(body)", "*:not(.keep)", "body.dark", "body *:not(script)", "div"] {
            let store = LensStore(url: Self.temporaryURL())
            var draft = Self.lens("blank", name: "Focus", ops: [Self.op("1")])
            draft.regions = [
                LensRegion(id: "rail", intent: "the sidebar", selectors: [selector])
            ]

            await #expect(throws: LensStoreError.self, "\(selector) was saveable") {
                try await store.save(draft: draft, origin: "www.example.com", against: Self.catalog)
            }
            #expect(await store.all().isEmpty)
        }
    }

    @Test("a draft may only name anchors the page said it had")
    func draftCannotInventASelector() async throws {
        // The same gate, from the ordinary direction: a selector that is perfectly
        // well-formed and narrow but was never offered. A draft is a page talking
        // to us, so "it parses" is not a reason to run it on every future visit.
        let store = LensStore(url: Self.temporaryURL())
        var draft = Self.lens("invented", name: "Focus", ops: [Self.op("1")])
        draft.regions = [
            LensRegion(id: "rail", intent: "the sidebar", selectors: ["#somewhere-else"])
        ]

        await #expect(throws: LensStoreError.self) {
            try await store.save(draft: draft, origin: "www.example.com", against: Self.catalog)
        }
        #expect(await store.all().isEmpty)
    }
}
