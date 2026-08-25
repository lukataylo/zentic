import Foundation

/// What the chrome knows about the lenses acting on the page in front of the user.
///
/// A pure value derived from two things: the lens set a tab handed the page, and the
/// ``LensReport``s the page sent back. Nothing here is inferred, estimated or
/// remembered from a previous page — **invariant 8 applies to lenses exactly as it
/// does to the shield**. The badge says `3/4` only when a page reported four ops and
/// three of them ran; before a report arrives the counts are absent, not zero and
/// not optimistic, because a lens that silently stopped matching looks identical to
/// one that never ran if the chrome is willing to guess.
///
/// It lives in ZenticKit rather than beside the toolbar that draws it because it
/// touches no window and imports no AppKit. Drift accounting is the part of this
/// feature most likely to be wrong in a way nobody notices, so it is a plain value
/// with a plain input, testable without linking a UI framework at all.
public struct LensState: Equatable, Sendable {
    /// One lens, and what it actually did on this page.
    public struct Entry: Equatable, Sendable, Identifiable {
        public var lens: Lens
        /// This page load's report. `nil` until the page has run an op pass.
        public var report: LensReport?
        /// One line per op that did not simply apply, in op order.
        ///
        /// Empty while ``isSuppressed``: a suppressed lens reports every op skipped
        /// for one reason, and a list of the same sentence once per op is not an
        /// explanation, it is the same explanation shouted.
        public var notes: [OpNote]

        /// Nothing this lens did is on screen, because the user is looking at
        /// Zentic's own render of the page rather than the site's.
        ///
        /// **Not drift and not failure.** The selectors still match, the ops are
        /// still good, and the moment the user presses ⌘\ they take effect. It is
        /// its own state because the two it would otherwise be confused with lead
        /// somewhere else entirely: drift asks the user to re-fit a lens that is
        /// fine, and `0/n` in the accent tint reads as total failure of a lens that
        /// has not been given a page to act on yet.
        ///
        /// It is decided by ``LensState/isReaderRendered`` alone, not by the report.
        /// Reports arrive coalesced and late, so one saying `4/4 applied` can easily
        /// land after the switch to the reader — and repeating it then would be the
        /// exact claim invariant 8 forbids, a number that is not true of what is on
        /// screen. Matching on the engine's own sentence would work too, and would
        /// make an English phrase a load-bearing contract across two languages.
        public var isSuppressed: Bool = false
        /// The page's own sentence for the suppression, when it sent one.
        ///
        /// Rendered verbatim, like ``OpNote/detail``: the engine is the half that
        /// decided not to run, so it is the half that gets to say why.
        public var suppressionReason: String?

        public var id: String { lens.id }

        // Counts are zero while suppressed rather than the report's own figures.
        // Every one of them is drawn somewhere as a statement about the page in
        // front of the user, and while the reader's render is up, the true answer to
        // "how many of this lens's changes are on this page" is none of them.
        public var appliedCount: Int { isSuppressed ? 0 : (report?.appliedCount ?? 0) }
        public var missedCount: Int { isSuppressed ? 0 : (report?.missedCount ?? 0) }
        public var totalCount: Int { isSuppressed ? 0 : (report?.totalCount ?? 0) }
        public var isDrifted: Bool { !isSuppressed && (report?.isDrifted ?? false) }

        /// Whether this page load produced a report with anything in it.
        ///
        /// An empty `results` array is not a report about a lens — it is a lens the
        /// page had nothing to say about, which is what an engine that bailed before
        /// the op pass sends. Counting it as a report put `0/0` in the badge and a
        /// tally on the row, both of which read as "this lens did nothing", which is
        /// a claim the page never made.
        public var hasReport: Bool { totalCount > 0 }

        /// The `n/m` the row shows, or nil when the page has not reported yet.
        public var tally: String? {
            guard let report, hasReport else { return nil }
            return "\(report.appliedCount)/\(report.totalCount)"
        }

        /// The ops whose selectors matched nothing. Drift, and the only part of
        /// this list a **Re-fit** would repair.
        public var driftNotes: [OpNote] { notes.filter(\.isDrift) }

        /// ``notes``, gathered into one block per outcome — the unit the popover
        /// draws.
        ///
        /// The reason an op did not apply is a property of the *outcome*, not of the
        /// op, and the list used to render it per row: three drifted ops meant three
        /// lines each ending "— no longer matches this page", which is one sentence
        /// shouted three times over the only part of a row that differs. Said once
        /// as a heading, the rows underneath are free to be what the user wrote.
        ///
        /// Grouped on the detail as well as the status, because two budget skips
        /// with different messages are two different facts; folding them under one
        /// heading would print a reason that is true of neither.
        public var noteGroups: [NoteGroup] {
            var order: [String] = []
            var groups: [String: NoteGroup] = [:]
            for note in notes {
                let key = "\(note.status.rawValue)\u{1}\(note.detail)"
                if groups[key] == nil {
                    order.append(key)
                    groups[key] = NoteGroup(status: note.status, detail: note.detail, notes: [])
                }
                groups[key]?.notes.append(note)
            }
            var ordered = order.compactMap { groups[$0] }

            // Drift leads, because it is the only group with a repair attached and
            // the only one the user is being asked to decide about.
            if let index = ordered.firstIndex(where: \.isDrift) {
                var drift = ordered.remove(at: index)
                // The heading counts what the *page* said, which can exceed the rows
                // we can name: a report is free to name op ids this lens no longer
                // holds, because the page runs the shape it was handed until it
                // reloads. Counting the rows instead would quietly disagree with the
                // tally beside the lens's name.
                drift.reportedCount = max(missedCount, drift.notes.count)
                ordered.insert(drift, at: 0)
            } else if missedCount > 0 {
                // Drift with nothing to list is that same race with every row lost.
                // It is still drift the page really saw, and dropping the group would
                // put Re-fit out of reach exactly where it is needed.
                ordered.insert(
                    NoteGroup(
                        status: .missed,
                        detail: LensState.driftDetail,
                        notes: [],
                        reportedCount: missedCount
                    ),
                    at: 0
                )
            }
            return ordered
        }

        /// Where this lens stands on the page in front of the user. See
        /// ``LensState/Standing``.
        public var standing: Standing {
            LensState.standing(
                suppressed: isSuppressed,
                applied: appliedCount,
                missed: missedCount,
                total: totalCount
            )
        }

        /// Whether this row has anything the user can act on with **Re-fit**.
        ///
        /// Drift with no notes is a real state and not a rare one: a report can name
        /// op ids that are not in the lens any more, because the page is still
        /// running the shape it was handed while another window has already edited
        /// it. The row was amber with nothing under it and no button, so the one
        /// action that would fix it was unreachable exactly when it was needed.
        ///
        /// Drift is the whole condition. It used to also require the lens to have
        /// regions, which is true of every lens that can be stored — an op naming no
        /// region is dropped by validation and a lens left with no ops is refused —
        /// so the term only made the rule look like it had two halves.
        public var canRefit: Bool { isDrifted }
    }

    /// Where a lens — one of them, or all of them together — stands on the page in
    /// front of the user.
    ///
    /// One vocabulary for the toolbar button and the popover, because they are two
    /// views of one fact and they were drifting apart: the button had three states
    /// and the popover had a chip, and neither could tell a lens with one stale op
    /// from a lens that had stopped landing entirely. That distinction is the whole
    /// job of this surface — a false alarm and a dead lens must not look the same —
    /// so it is a case here rather than a comparison written out at each drawing
    /// site.
    ///
    /// Every case is derived from counts the page reported. Nothing here can be
    /// reached without a report, which is invariant 8 holding at the type level:
    /// ``silent`` is the state before the page has spoken, and it draws no number.
    public enum Standing: Equatable, Sendable {
        /// No report yet. Not zero, not optimistic — nothing.
        case silent
        /// Zentic's own render is on screen, so none of what this lens does is
        /// visible. Not a failure: ⌘\ and it is all there.
        case suppressed
        /// Nothing drifted. Ops may still carry a note — an ambiguous match, a
        /// budget skip — and none of those is a warning about the site.
        case holding(applied: Int, of: Int)
        /// Part of the lens stopped matching. The rest is still on the page, which
        /// is why this is not the same state as ``stopped``.
        case drifting(missed: Int, of: Int)
        /// Nothing matched. Every change this lens makes is off the page.
        case stopped(of: Int)

        /// Whether there is something here the user can act on. Exactly the two
        /// cases drawn in amber: colour means "you can do something about this".
        public var needsAttention: Bool {
            switch self {
            case .drifting, .stopped: return true
            case .silent, .suppressed, .holding: return false
            }
        }
    }

    /// The clause drift is explained with, in one place because two render it:
    /// ``detail(for:)`` puts it on a note and ``Entry/noteGroups`` puts it on a
    /// group that has no notes to take it from.
    static let driftDetail = "no longer matches this page"

    /// One outcome, and every op that shares it.
    ///
    /// See ``Entry/noteGroups``: the group is what carries the reason, so a row is
    /// free to be the op's own sentence and nothing else.
    public struct NoteGroup: Equatable, Sendable, Identifiable {
        public var status: LensOpStatus
        /// The clause every op in this group shares — the page's own words for
        /// everything except drift, which is ours. See ``LensState/detail(for:)``.
        public var detail: String
        /// The ops this group can name, in the lens's own op order.
        public var notes: [OpNote]
        /// How many ops the page put in this state, which is ``notes`` everywhere
        /// except drift. Set by ``Entry/noteGroups``; see the note there.
        public var reportedCount: Int?

        public init(
            status: LensOpStatus,
            detail: String,
            notes: [OpNote],
            reportedCount: Int? = nil
        ) {
            self.status = status
            self.detail = detail
            self.notes = notes
            self.reportedCount = reportedCount
        }

        public var id: String { "\(status.rawValue)\u{1}\(detail)" }

        /// This is the group **Re-fit** repairs.
        public var isDrift: Bool { status == .missed }

        /// How many ops the heading speaks for.
        public var count: Int { max(reportedCount ?? 0, notes.count) }

        /// The page put ops in this state that this lens cannot name — it has been
        /// edited since the page loaded. Worth one line, because otherwise the
        /// heading counts higher than the rows under it for no visible reason.
        public var hasUnnamed: Bool { count > notes.count }

        /// The heading: the reason, said once, with the count it covers.
        ///
        /// Drift gets a sentence of ours that agrees with its own subject, because
        /// drift's clause is ours to write. Every other status quotes the engine
        /// verbatim, so the count is set off with a dash rather than folded into a
        /// sentence we would have to conjugate on the page's behalf.
        public var title: String {
            guard !isDrift else {
                return count == 1
                    ? "1 change no longer matches this page"
                    : "\(count) changes no longer match this page"
            }
            return "\(count == 1 ? "1 change" : "\(count) changes") — \(detail)"
        }
    }

    /// One op that did not simply apply, in the user's terms.
    ///
    /// There is one of these for **every** ``LensOpStatus`` other than
    /// ``LensOpStatus/applied``, and that is the point of the type. `applied` is
    /// rendered by the tally; the other four used to have between them one
    /// treatment for `missed` and one for `skipped`, so an op the page reported
    /// `ambiguous` or `failed` counted against the badge and then appeared nowhere
    /// at all — the user saw `3/4` with nothing to say what the fourth was. A
    /// status no surface renders is a silent failure by construction, which is why
    /// `LensStateTests.everyStatusReachesTheUser` drives itself from the enum.
    public struct OpNote: Equatable, Sendable, Identifiable {
        /// The selector this op went through, and whether it got there.
        ///
        /// Two cases and not one string, because the difference is the whole value
        /// of showing it. ``matched`` is the page's own report of which candidate
        /// won; ``tried`` is the lens's first candidate for a region the resolver
        /// ran against and failed to find. Printing both as bare text would let the
        /// popover imply an element was found when the page said the opposite,
        /// which is the shape invariant 8 forbids.
        public enum Anchor: Equatable, Sendable {
            /// The page resolved the op through this selector and said so.
            case matched(String)
            /// Nothing matched, and this is what the lens looked for.
            case tried(String)

            public var selector: String {
                switch self {
                case .matched(let selector), .tried(let selector): return selector
                }
            }
        }

        public var opID: String
        /// The user's own sentence for what the op does ("hide the suggestions"),
        /// which is the only description of a stale op they can act on — a
        /// selector is not an explanation.
        public var note: String
        public var status: LensOpStatus
        /// What happened, as one clause to follow the note.
        public var detail: String
        /// Which anchor this op went through, when there is one to name.
        ///
        /// Carried on every ``LensOpResult`` since the wire format existed and
        /// drawn nowhere, which cost the user the single most useful fact on a
        /// drifted row: *which* anchor was tried decides whether Re-fit is the
        /// answer or the lens wants editing.
        public var anchor: Anchor?

        public var id: String { opID }

        /// This op stopped matching the page. The one status **Re-fit** repairs,
        /// and the only one drawn as a warning.
        public var isDrift: Bool { status == .missed }

        public init(
            opID: String,
            note: String,
            status: LensOpStatus,
            detail: String,
            anchor: Anchor? = nil
        ) {
            self.opID = opID
            self.note = note
            self.status = status
            self.detail = detail
            self.anchor = anchor
        }
    }

    /// Lenses for this page, newest edit first — the order the popover lists them
    /// in. See ``LensStore/lenses(for:path:)``: it is a reading order, not a claim
    /// about which of two lenses wins where they overlap.
    public var entries: [Entry] = []

    /// How many lenses the site has in total, including the ones switched off and
    /// the ones whose path pattern does not cover this page.
    ///
    /// Separate from ``entries`` because the two answer different questions. The
    /// entries are what is acting on the page now; this is whether the button should
    /// look like there is anything behind it — a site whose only lens is disabled
    /// still needs a way back to the switch.
    public var siteLensCount: Int = 0

    /// How many of the site's lenses are switched **on**, whether or not their path
    /// pattern covers this page.
    ///
    /// The difference between this and ``entries`` is the entire content of the
    /// tooltip on a page where nothing is running, and the two states need different
    /// sentences: "switched off" is a switch to flip, "not for this page" is a page
    /// to visit. Saying the first when the truth is the second sent users to the
    /// popover to turn on a lens that was already on.
    public var enabledLensCount: Int = 0

    /// Whether the user is looking at Zentic's own render rather than the site's,
    /// which decides whether a lens can be *seen* at all.
    ///
    /// A lens remodels the site's own document. When ``ReaderView`` is rendered that
    /// document is still there — hidden with `visibility: hidden`, so every selector
    /// in the lens still resolves — but nothing it did is on screen. The page knows
    /// what it ran; only the app knows which of the two renders is in front of the
    /// user, because the app owns ⌘\. Neither half can describe this state alone,
    /// which is why it is an input here rather than something inferred from a report.
    public var isReaderRendered: Bool = false

    public init(
        entries: [Entry] = [],
        siteLensCount: Int = 0,
        enabledLensCount: Int = 0,
        isReaderRendered: Bool = false
    ) {
        self.entries = entries
        self.siteLensCount = siteLensCount
        self.enabledLensCount = enabledLensCount
        self.isReaderRendered = isReaderRendered
    }

    /// Whether the site has any lens at all, enabled or not.
    public var hasLenses: Bool { siteLensCount > 0 || !entries.isEmpty }
    /// Whether any lens is switched on for this page.
    public var isActive: Bool { entries.contains { $0.lens.isEnabled } }
    /// Whether the page has reported anything yet. Gates the badge: no report means
    /// no number, per invariant 8.
    public var hasReport: Bool { entries.contains { $0.hasReport } }

    /// Lenses are on for this page, and none of what they do is on screen — the
    /// reader is showing its own render of the document they act on.
    ///
    /// Its own toolbar state, because the two it used to be drawn as are both wrong.
    /// Every op comes back `skipped`, correctly, so the badge read `0/4` in the "this
    /// is working" tint: honestly earned, and read by anyone who saw it as four
    /// changes that had failed. Dimming it as if the site had no lenses is the other
    /// wrong answer — there is something here, it is one keystroke away.
    public var isSuppressed: Bool { isReaderRendered && isActive }

    /// The page's own sentence for the suppression, when it sent one.
    public var suppressionReason: String? {
        entries.compactMap(\.suppressionReason).first
    }

    /// How many of this site's lenses are switched on but scoped to another path.
    public var offPathCount: Int { max(0, enabledLensCount - entries.count) }

    public var totalCount: Int { entries.reduce(0) { $0 + $1.totalCount } }
    public var appliedCount: Int { entries.reduce(0) { $0 + $1.appliedCount } }
    public var missedCount: Int { entries.reduce(0) { $0 + $1.missedCount } }
    public var isDrifted: Bool { missedCount > 0 }

    /// The toolbar badge, or nil when there is nothing honest to put there.
    public var tally: String? {
        guard hasReport else { return nil }
        return "\(appliedCount)/\(totalCount)"
    }

    /// Where this page's lenses stand, taken together — the toolbar button's own
    /// state, and the same vocabulary each row in the popover is drawn from.
    ///
    /// Says nothing about a site whose lenses are all switched off or all scoped
    /// elsewhere: that is ``hasLenses`` and ``isActive``, a question about the lens
    /// set rather than about what the page did with it, and the button answers it
    /// before it gets here.
    public var standing: Standing {
        Self.standing(
            suppressed: isSuppressed,
            applied: appliedCount,
            missed: missedCount,
            total: totalCount
        )
    }

    /// The one place the counts become a state, so the button and the row cannot
    /// classify the same report differently.
    ///
    /// Order matters. Suppression outranks everything: under the reader's render
    /// the counts are zeroed, and a lens that is fine would otherwise land in
    /// ``Standing/silent`` and read as a lens nothing has been heard from. Then a
    /// page that has not reported, then drift — where the *whole* set missing is
    /// its own case, because "one op of six is stale" and "none of this lens is on
    /// the page any more" want different amounts of the user's attention.
    static func standing(suppressed: Bool, applied: Int, missed: Int, total: Int) -> Standing {
        if suppressed { return .suppressed }
        guard total > 0 else { return .silent }
        // `applied` is not `total - missed`: an op can be skipped or ambiguous
        // without any selector having gone stale, and those belong in the sentence
        // the button says as much as they belong in the tally.
        if missed == 0 { return .holding(applied: applied, of: total) }
        if missed >= total { return .stopped(of: total) }
        return .drifting(missed: missed, of: total)
    }

    /// Build the state from the applied set and whatever the page has said about it.
    ///
    /// - Parameters:
    ///   - lenses: The lens set handed to this page, already ordered by the store.
    ///     Every one of them is enabled — the store filters on that before a set is
    ///     ever resolved for a URL — which is why nothing here re-checks it.
    ///   - reports: Live reports from this page load, keyed by ``Lens/id``.
    ///   - siteLensCount: Every lens saved for this host. Defaults to the applied
    ///     set, which is right whenever the caller has nothing better to say.
    ///   - enabledLensCount: Of those, the ones switched on. Defaults to the applied
    ///     set for the same reason.
    ///   - isReaderRendered: Whether Zentic's own render is in front of the user.
    ///     See ``isReaderRendered``.
    public static func make(
        lenses: [Lens],
        reports: [String: LensReport],
        siteLensCount: Int? = nil,
        enabledLensCount: Int? = nil,
        isReaderRendered: Bool = false
    ) -> LensState {
        let suppressed = isReaderRendered
        var entries: [Entry] = []
        for lens in lenses {
            let report = reports[lens.id]
            entries.append(
                Entry(
                    lens: lens,
                    report: report,
                    notes: suppressed ? [] : notes(for: lens, report: report),
                    isSuppressed: suppressed,
                    suppressionReason: suppressed ? reason(in: report) : nil
                )
            )
        }
        return LensState(
            entries: entries,
            siteLensCount: siteLensCount ?? entries.count,
            enabledLensCount: enabledLensCount ?? entries.count,
            isReaderRendered: isReaderRendered
        )
    }

    /// The page's account of why it ran nothing, if it sent one.
    ///
    /// Taken from the skips rather than assumed, and only from a report that is
    /// *entirely* skips: a page that ran some of the lens and then stopped is not
    /// describing suppression, whatever the app believes about which render is up.
    private static func reason(in report: LensReport?) -> String? {
        guard let report, !report.results.isEmpty,
            report.results.allSatisfy({ $0.status == .skipped })
        else { return nil }
        return report.results.compactMap(\.message).first { !$0.isEmpty }
    }

    // MARK: - What the page said

    /// One line per op the page did not simply apply, in the lens's own op order.
    ///
    /// Driven by the lens's own op list rather than by the report, so an op id the
    /// page reported that this lens no longer holds produces no line. It cannot:
    /// the line is the op's `note`, and there is no note for an op that is not
    /// here any more.
    ///
    /// Not called at all for a suppressed lens: that skip is about the whole lens,
    /// not about any one op, and it is said once by ``Entry/isSuppressed``.
    private static func notes(for lens: Lens, report: LensReport?) -> [OpNote] {
        guard let report else { return [] }
        let unapplied = Dictionary(
            report.results.filter { $0.status != .applied }.map { ($0.opID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard !unapplied.isEmpty else { return [] }

        return lens.ops.compactMap { op in
            guard let result = unapplied[op.id] else { return nil }
            return OpNote(
                opID: op.id,
                note: op.note,
                status: result.status,
                detail: detail(for: result),
                anchor: anchor(for: result, op: op, in: lens)
            )
        }
    }

    /// Which selector to name beside an op, if any.
    ///
    /// The page's own `usedSelector` whenever it sent one — that is the candidate
    /// that actually resolved, and no scan on this side can work it out. Falling
    /// back to the lens's first candidate is confined to ``LensOpStatus/missed``,
    /// because that is the one status where the resolver demonstrably ran and came
    /// back empty. A budget skip never reached a selector at all, so printing one
    /// as "tried" would describe an attempt the page never made.
    private static func anchor(
        for result: LensOpResult,
        op: LensOp,
        in lens: Lens
    ) -> OpNote.Anchor? {
        if let used = result.usedSelector, !used.isEmpty { return .matched(used) }
        guard result.status == .missed,
            let candidate = lens.regions.first(where: { $0.id == op.region })?.selectors.first
        else { return nil }
        return .tried(candidate)
    }

    /// What to put after the op's note.
    ///
    /// **The page's message wins for everything except drift.** The engine is the
    /// only half that knows what actually happened: it resolves selectors against
    /// a live DOM, so it can see that two differently-named regions in two lenses
    /// landed on one element, and it is also the half that runs out of budget. The
    /// app knows neither. Synthesising an explanation next to the engine's used to
    /// mean that on a restructured page — where every op comes back skipped with
    /// "the reader is showing its own render" — the popover instead claimed the
    /// user's ops had overridden each other, and a pass-ceiling skip was blamed on
    /// whichever lens happened to hold a conflicting op. A user who reads that
    /// goes and edits the innocent lens.
    ///
    /// Drift is the exception because it is the one status whose cause the app
    /// understands completely, and the engine's own wording for it describes a
    /// mechanism rather than a consequence: "region matched nothing" is true and
    /// tells the user nothing they can act on.
    ///
    /// Every remaining case gets a sentence for a report that arrived with no
    /// message — an older bundle, or one replayed from disk. A blank line under a
    /// note is a row that looks broken.
    private static func detail(for result: LensOpResult) -> String {
        if result.status == .missed { return driftDetail }
        if let message = result.message, !message.isEmpty { return message }
        switch result.status {
        case .applied, .missed:
            // `applied` never reaches here — `notes(for:report:)` filters it out,
            // and it is drawn as the tally. Named rather than defaulted so that a
            // new status is a compile error in the one place that has to have an
            // answer for it.
            return ""
        case .ambiguous:
            return "matched more than one place — applied to the first"
        case .skipped:
            return "the page did not run this one"
        case .failed:
            return "could not be applied"
        }
    }
}

// MARK: - Reports and the page they describe

extension LensReport {
    /// Whether this report describes the page currently at `url`.
    ///
    /// Reports arrive coalesced and late — the engine merges observer results into a
    /// full report and re-posts it on a timer — so on a single-page app a report for
    /// the route the user just left can land after the router has already moved. If
    /// the matching lens set did not change across that route there is nothing else
    /// to notice the move by, and the badge then counts ops that ran on a page which
    /// is no longer on screen.
    ///
    /// ``LensReport/url`` is a **path**, deliberately: it is written into
    /// `Lenses.json` and read back on every launch, and a query string is where
    /// the session tokens and the search terms live — so the one piece of browsing
    /// history this feature puts on disk is kept to the coarsest thing that still
    /// answers "which page did this lens last run on". The comparison is therefore
    /// against the path too. An empty path and `/` are the same page —
    /// `URL.path()` gives the first and `location.pathname` the second — and a
    /// trailing slash is not a different page either.
    public func describes(_ url: URL?) -> Bool {
        guard let url else { return false }
        return Self.normalisedPath(self.url) == Self.normalisedPath(url.path())
    }

    private static func normalisedPath(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.isEmpty ? "/" : trimmed
    }
}
