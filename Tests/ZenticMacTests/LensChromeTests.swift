import Foundation
import Testing
import ZenticKit

@testable import ZenticMac

/// What the toolbar button and the popover say about a page's lenses.
///
/// Both are drawn from one ``LensState``, and both are places invariant 8 breaks
/// quietly: the wrong sentence sends the user to fix something that is not broken,
/// and a number drawn over the reader's own render is a claim about a page nobody
/// is looking at. None of it was reachable by a test — the decisions were inside an
/// `NSButton` and an `NSPopover` — so ``LensButtonCopy`` was lifted out for the
/// same reason ``LevelRailCopy`` was, and the popover's own pure parts are called
/// here directly.
@Suite("Lens chrome")
struct LensChromeTests {

    // MARK: Fixtures

    static func lens(_ id: String, name: String? = nil, ops: Int, enabled: Bool = true) -> Lens {
        Lens(
            id: id,
            name: name ?? id.capitalized,
            origin: "www.youtube.com",
            isEnabled: enabled,
            prompt: "hide the suggestions",
            regions: [LensRegion(id: "rail", intent: "the sidebar", selectors: ["#secondary"])],
            ops: (1...ops).map {
                LensOp(id: "op\($0)", kind: .hide, region: "rail", note: "hide thing \($0)")
            },
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    static func report(
        _ lensID: String,
        _ statuses: [LensOpStatus],
        path: String = "/watch",
        message: String? = nil
    ) -> LensReport {
        LensReport(
            lensID: lensID,
            url: path,
            results: statuses.enumerated().map { index, status in
                LensOpResult(opID: "op\(index + 1)", status: status, message: message)
            },
            generatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// A state built the way a tab builds one, so the tests go through the same
    /// aggregation the app does rather than a hand-assembled shortcut.
    static func state(
        _ lenses: [Lens],
        _ reports: [String: LensReport] = [:],
        site: Int? = nil,
        enabled: Int? = nil,
        reader: Bool = false
    ) -> LensState {
        LensState.make(
            lenses: lenses,
            reports: reports,
            siteLensCount: site ?? lenses.count,
            enabledLensCount: enabled ?? lenses.count,
            isReaderRendered: reader
        )
    }

    // MARK: - Nothing is running here

    @Test("A site with no lens at all says how to make one")
    func noLenses() {
        let look = LensButtonCopy.appearance(for: LensState())
        #expect(look.tint == .quiet)
        #expect(look.badge == nil)
        #expect(look.tip == "No lenses for this site — ⌥⌘L to make one")
    }

    /// The defect this pair exists for. "Switched off" and "on, but for another
    /// page" are indistinguishable from the button's own inputs and they are
    /// opposite instructions: one is a switch to flip, the other is a page to visit.
    /// Saying the first when the truth was the second sent people into the popover
    /// to turn on a lens that was already on, and then to conclude the checkbox was
    /// broken.
    @Test("A lens that is on but scoped elsewhere is not a lens switched off")
    func offPathIsNotSwitchedOff() {
        // One lens, switched on, whose path pattern does not cover this page — so
        // nothing is applied here.
        let offPath = Self.state([], site: 1, enabled: 1)
        #expect(LensButtonCopy.appearance(for: offPath).tip
            == "This site's lens is on, but for other pages")

        // The same shape with the lens switched off instead.
        let switchedOff = Self.state([], site: 1, enabled: 0)
        #expect(LensButtonCopy.appearance(for: switchedOff).tip
            == "This site's lens is switched off")
    }

    /// Both sentences agree with themselves at every count, because both are built
    /// through one phrase helper. Written out rather than trusted: "This site's 1
    /// lenses are" is exactly the kind of string that ships.
    @Test("The count and the verb agree in both quiet sentences")
    func quietSentencesAgree() {
        #expect(LensButtonCopy.appearance(for: Self.state([], site: 3, enabled: 0)).tip
            == "This site's 3 lenses are switched off")
        #expect(LensButtonCopy.appearance(for: Self.state([], site: 4, enabled: 2)).tip
            == "This site's 2 lenses are on, but for other pages")
    }

    @Test("A site whose lenses are all inactive is drawn quiet, whichever reason")
    func inactiveIsQuiet() {
        #expect(LensButtonCopy.appearance(for: Self.state([], site: 1, enabled: 0)).tint == .quiet)
        #expect(LensButtonCopy.appearance(for: Self.state([], site: 1, enabled: 1)).tint == .quiet)
    }

    // MARK: - The page has spoken

    /// Invariant 8 at the button: a lens is on, nothing has reported, and there is
    /// no number. Not `0/2` and not a hopeful `2/2` — a count that turns out to be
    /// wrong is worse than none, because the user cannot tell which it was.
    @Test("A lens with no report yet draws no number")
    func silentDrawsNoBadge() {
        let look = LensButtonCopy.appearance(for: Self.state([Self.lens("a", ops: 2)]))
        #expect(look.tint == .active)
        #expect(look.badge == nil)
        #expect(look.tip == "Lenses are on for this page")
    }

    /// `applied` is not `total - missed`. An op can come back ambiguous or skipped
    /// with nothing having gone stale, and the tally has to say so rather than
    /// rounding it into either bucket.
    @Test("A lens holding with an unapplied op is not drift")
    func holdingCountsWhatApplied() {
        let lens = Self.lens("a", ops: 4)
        let look = LensButtonCopy.appearance(
            for: Self.state([lens], ["a": Self.report("a", [.applied, .applied, .applied, .ambiguous])])
        )
        #expect(look.tint == .active)
        #expect(look.badge == "3/4")
        #expect(look.tip == "3 of 4 changes applied by 1 lens")
    }

    @Test("Two lenses sum into one badge and one sentence")
    func twoLensesOneButton() {
        let look = LensButtonCopy.appearance(
            for: Self.state(
                [Self.lens("a", ops: 2), Self.lens("b", ops: 1)],
                [
                    "a": Self.report("a", [.applied, .applied]),
                    "b": Self.report("b", [.applied]),
                ]
            )
        )
        #expect(look.badge == "3/3")
        #expect(look.tip == "3 of 3 changes applied by 2 lenses")
    }

    @Test("A stale op is amber, and says how much of the lens is still landing")
    func driftingIsAmber() {
        let look = LensButtonCopy.appearance(
            for: Self.state([Self.lens("a", ops: 3)], ["a": Self.report("a", [.applied, .applied, .missed])])
        )
        #expect(look.tint == .attention)
        #expect(look.badge == "2/3")
        #expect(look.tip == "1 of 3 changes no longer match this page")
    }

    /// The same amber, a different sentence. "One op of six is stale" and "none of
    /// this lens is on the page any more" want different amounts of the user's
    /// attention, and the tooltip is where the toolbar says which without inventing
    /// a fourth colour.
    @Test("A lens with nothing left on the page says so, in the right number")
    func stoppedSaysSo() {
        let many = LensButtonCopy.appearance(
            for: Self.state([Self.lens("a", ops: 2)], ["a": Self.report("a", [.missed, .missed])])
        )
        #expect(many.tint == .attention)
        #expect(many.badge == "0/2")
        #expect(many.tip == "None of these 2 changes match this page any more")

        let one = LensButtonCopy.appearance(
            for: Self.state([Self.lens("a", ops: 1)], ["a": Self.report("a", [.missed])])
        )
        #expect(one.tip == "The one change made here no longer matches this page")
    }

    /// The 0/4 defect. Under the reader's render every op comes back `skipped` —
    /// honestly, because they resolved against a document the user cannot see — and
    /// the button drew that as `0/4` in the "this is working" tint: a working colour
    /// over a total-failure number, which reads as four changes that failed.
    ///
    /// There is no count that is true of what is on screen, so there is no number,
    /// and the sentence says where the changes went and which key brings them back.
    @Test("Under the reader's own render there is no number, and no alarm")
    func suppressedDrawsNothing() {
        let suppressed = "the reader is showing its own render; this lens applies to the original page"
        let lens = Self.lens("a", ops: 4)
        let look = LensButtonCopy.appearance(
            for: Self.state(
                [lens],
                ["a": Self.report("a", Array(repeating: .skipped, count: 4), message: suppressed)],
                reader: true
            )
        )
        #expect(look.tint == .quiet)
        #expect(look.badge == nil)
        #expect(look.tip == "This site's lens is on. Lenses act on the site's own page — ⌘\\ to see it.")
    }

    /// A report saying everything applied lands routinely just *after* ⌘\, because
    /// reports are coalesced and late. Repeating it then puts `4/4 applied` over a
    /// render showing none of it.
    @Test("A report that arrived before the switch cannot badge the reader's render")
    func staleAppliedReportIsNotDrawn() {
        let lens = Self.lens("a", ops: 2)
        let reports = ["a": Self.report("a", [.applied, .applied])]

        #expect(LensButtonCopy.appearance(for: Self.state([lens], reports, reader: true)).badge == nil)
        // The same reports, on the page the lens actually acts on.
        #expect(LensButtonCopy.appearance(for: Self.state([lens], reports)).badge == "2/2")
    }

    /// The button and every row in the popover are drawn from one
    /// ``LensState/Standing``, so they cannot classify one report two ways — but
    /// they pick their colour separately, and amber has one meaning: there is
    /// something here you can do about. This is the two halves held to it.
    @Test("Amber on the button is exactly the standings the rows call repairable")
    func amberMeansRepairable() {
        let standings: [LensState.Standing] = [
            .silent,
            .suppressed,
            .holding(applied: 3, of: 4),
            .drifting(missed: 1, of: 4),
            .stopped(of: 4),
        ]
        for standing in standings {
            let state = Self.state(reaching: standing)
            #expect(
                state.standing == standing,
                "the fixture did not reach \(standing)"
            )
            let isAmber = LensButtonCopy.appearance(for: state).tint == .attention
            #expect(isAmber == standing.needsAttention, "\(standing)")
        }
    }

    /// A state that genuinely reaches one standing, built from a lens and a report
    /// rather than asserted into being — so the mapping under test is the real one.
    private static func state(reaching standing: LensState.Standing) -> LensState {
        switch standing {
        case .silent:
            return state([lens("a", ops: 2)])
        case .suppressed:
            return state(
                [lens("a", ops: 2)],
                ["a": report("a", [.skipped, .skipped])],
                reader: true
            )
        case .holding(let applied, let total):
            let statuses = Array(repeating: LensOpStatus.applied, count: applied)
                + Array(repeating: .ambiguous, count: total - applied)
            return state([lens("a", ops: total)], ["a": report("a", statuses)])
        case .drifting(let missed, let total):
            let statuses = Array(repeating: LensOpStatus.missed, count: missed)
                + Array(repeating: .applied, count: total - missed)
            return state([lens("a", ops: total)], ["a": report("a", statuses)])
        case .stopped(let total):
            return state(
                [lens("a", ops: total)],
                ["a": report("a", Array(repeating: .missed, count: total))]
            )
        }
    }
}

// MARK: - The popover's list

/// The rows the popover draws, and when it redraws them.
///
/// Both are pure, both are hot, and both have a failure mode that is invisible
/// while the popover is closed — which is every moment anyone is looking at the
/// code.
@Suite("Lens popover list")
@MainActor
struct LensPopoverListTests {

    private func lens(
        _ id: String,
        name: String? = nil,
        enabled: Bool = true,
        pattern: String = "*",
        lastReport: LensReport? = nil
    ) -> Lens {
        Lens(
            id: id,
            name: name ?? id.capitalized,
            origin: "www.youtube.com",
            pathPattern: pattern,
            isEnabled: enabled,
            prompt: "hide the suggestions",
            regions: [LensRegion(id: "rail", intent: "the sidebar", selectors: ["#secondary"])],
            ops: [LensOp(id: "op1", kind: .hide, region: "rail", note: "hide the sidebar")],
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            lastReport: lastReport
        )
    }

    private func report(_ lensID: String, _ statuses: [LensOpStatus], path: String = "/watch") -> LensReport {
        LensReport(
            lensID: lensID,
            url: path,
            results: statuses.enumerated().map {
                LensOpResult(opID: "op\($0.offset + 1)", status: $0.element)
            },
            generatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: Joining the store's list to the page's report

    /// The join direction is the rule, and getting it backwards loses exactly the
    /// rows the user came for. A lens switched off, or scoped to `/watch` while the
    /// user is on the home page, has **no entry** — the page is not running it — and
    /// it is precisely the lens somebody opened this popover to switch back on.
    @Test("A lens the page is not running still has a row to be switched on from")
    func inactiveLensesKeepTheirRows() {
        let running = lens("live")
        let state = LensState.make(
            lenses: [running],
            reports: ["live": report("live", [.applied])]
        )
        let rows = LensPopover.Row.rows(
            for: [running, lens("off", enabled: false), lens("elsewhere", pattern: "/shorts")],
            matching: state.entries
        )

        #expect(rows.map(\.lens.id) == ["live", "off", "elsewhere"])
        #expect(rows[0].entry?.tally == "1/1")
        // No entry, so no tally. Invariant 8: a row shows a number because a page
        // said so, or it shows none.
        #expect(rows[1].entry == nil)
        #expect(rows[2].entry == nil)
    }

    /// The store's order is the popover's order — newest edit first, which is a
    /// reading order the header explains. Taking the order from the entries instead
    /// would list only the running lenses and put them in application order, which
    /// is that list reversed.
    @Test("The rows are in the store's order, not the report's")
    func orderComesFromTheStore() {
        let state = LensState.make(lenses: [lens("b"), lens("a")], reports: [:])
        let rows = LensPopover.Row.rows(for: [lens("a"), lens("b")], matching: state.entries)
        #expect(rows.map(\.lens.id) == ["a", "b"])
    }

    /// A page keeps running the set it was handed until it reloads, so an entry can
    /// outlive the lens another window has just deleted. It must not conjure a row:
    /// every action on that row resolves an id the store no longer has and returns
    /// silently, which is a menu of things that do nothing.
    @Test("An entry for a lens the store no longer has invents no row")
    func deletedLensGetsNoRow() {
        let state = LensState.make(lenses: [lens("gone"), lens("kept")], reports: [:])
        let rows = LensPopover.Row.rows(for: [lens("kept")], matching: state.entries)
        #expect(rows.map(\.lens.id) == ["kept"])
    }

    // MARK: When the list redraws

    /// The popover is rebuilt from a fingerprint of everything a row draws, because
    /// a coalesced report lands every half second on a live feed and rebuilding the
    /// view tree at that rate makes the list flicker and drops any menu open over
    /// it. The cost of that optimisation is a field that a row draws and the
    /// fingerprint does not read: it stops updating, silently, and only while
    /// somebody has the popover open.
    ///
    /// So every drawn field is walked here. A field added to a row without being
    /// added to the fingerprint fails this.
    @Test("Every field a row draws moves the fingerprint")
    func fingerprintCoversEveryDrawnField() {
        let base = LensPopover.Row(
            lens: lens("a", name: "Focus"),
            entry: LensState.make(
                lenses: [lens("a", name: "Focus")],
                reports: ["a": report("a", [.applied])]
            ).entries.first
        )
        let unchanged = LensPopover.fingerprint([base])

        var variants: [(String, LensPopover.Row)] = []

        var renamed = base
        renamed.lens.name = "Focus mode"
        variants.append(("the name on the row", renamed))

        var switchedOff = base
        switchedOff.lens.isEnabled = false
        variants.append(("the checkbox", switchedOff))

        var rescoped = base
        rescoped.lens.pathPattern = "/watch"
        variants.append(("the scope the row states", rescoped))

        var identity = base
        identity.lens.id = "b"
        variants.append(("which lens the row is for", identity))

        var retallied = base
        retallied.entry = LensState.make(
            lenses: [lens("a", name: "Focus")],
            reports: ["a": report("a", [.missed])]
        ).entries.first
        variants.append(("the tally and the drift meter", retallied))

        var noted = base
        noted.entry = LensState.make(
            lenses: [lens("a", name: "Focus")],
            reports: ["a": report("a", [.ambiguous])]
        ).entries.first
        variants.append(("the note under the row", noted))

        var suppressed = base
        suppressed.entry = LensState.make(
            lenses: [lens("a", name: "Focus")],
            reports: ["a": report("a", [.skipped])],
            isReaderRendered: true
        ).entries.first
        variants.append(("whether the lens is suppressed, and its reason", suppressed))

        var unmatched = base
        unmatched.entry = nil
        variants.append(("having no entry at all", unmatched))

        var history = base
        history.entry = nil
        history.lens.lastReport = report("a", [.missed, .applied])
        variants.append(("the line about the last time it ran", history))

        for (field, row) in variants {
            #expect(
                LensPopover.fingerprint([row]) != unchanged,
                "\(field) does not move the fingerprint, so the popover will not redraw for it"
            )
        }

        // And the other half: an identical list must not rebuild, or the list
        // flickers under a report that says nothing new.
        #expect(LensPopover.fingerprint([base]) == unchanged)
        // Two rows are not one row, however alike.
        #expect(LensPopover.fingerprint([base, base]) != unchanged)
    }

    // MARK: What this lens did last time

    /// History is shown for a row with **no entry** too, and that is where it
    /// matters most: a lens that is not applying here is exactly the one whose past
    /// the user cannot get at any other way. It used to be gated behind having an
    /// entry, so the only lenses that could explain themselves were the ones
    /// already running in front of the user.
    @Test("A lens that is not running here can still say it drifted last time")
    func historyReachesTheRowsThatNeedIt() {
        let row = LensPopover.Row(
            lens: lens("a", enabled: false, lastReport: report("a", [.missed, .applied])),
            entry: nil
        )
        #expect(
            LensPopover.historyLine(for: row)
                == "Last time this lens ran, 1 of 2 changes did not match"
        )
    }

    /// This page's own report always wins. Two accounts of one lens on one screen,
    /// disagreeing, is worse than one.
    @Test("A report about this page silences the history line")
    func thisPageWins() {
        let lens = lens("a", lastReport: report("a", [.missed, .applied]))
        let entry = LensState.make(
            lenses: [lens],
            reports: ["a": report("a", [.applied])]
        ).entries.first
        #expect(LensPopover.historyLine(for: .init(lens: lens, entry: entry)) == nil)
    }

    /// Only drift is worth a line. "Last time this lens ran, everything applied" is
    /// a sentence about nothing, on a row that is already saying it.
    @Test("A lens that ran cleanly last time has nothing to report")
    func cleanHistoryIsSilent() {
        let row = LensPopover.Row(lens: lens("a", lastReport: report("a", [.applied])), entry: nil)
        #expect(LensPopover.historyLine(for: row) == nil)
        #expect(LensPopover.historyLine(for: .init(lens: lens("a"), entry: nil)) == nil)
    }

    /// A lens under the reader's render reports every op skipped, so it has no
    /// current report — and its stored one, from the last time it really ran, is
    /// what the row has to say. Suppression is not a reason to hide the lens's past.
    @Test("Suppression does not hide what the lens did the last time it ran")
    func historySurvivesSuppression() {
        let lens = lens("a", lastReport: report("a", [.missed, .applied]))
        let entry = LensState.make(
            lenses: [lens],
            reports: ["a": report("a", [.skipped, .skipped])],
            isReaderRendered: true
        ).entries.first
        #expect(LensPopover.historyLine(for: .init(lens: lens, entry: entry)) != nil)
    }
}
