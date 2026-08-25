import Foundation

// MARK: - Errors

/// Why a lens could not be stored.
///
/// Typed rather than silent. Saving a lens is something the user is watching
/// happen, so the one failure mode we cannot have is dropping one quietly and
/// leaving them to notice a week later that the site went back to normal.
public enum LensStoreError: Error, Sendable, Equatable {
    case notFound(id: String)
    /// The per-origin cap in ``Budget/lensMaxLensesPerOrigin`` would be exceeded.
    case tooManyLenses(origin: String, limit: Int)
    /// A lens written by a build with a different shape. Not migrated — see
    /// ``Lens/currentSchemaVersion``.
    case incompatibleSchema(version: Int)
    /// Validation left nothing that could act on a page.
    case rejected(reason: String)
}

// MARK: - Store

/// Saved lenses.
///
/// A JSON file, for the same reasons ``DesignStore`` is one: lenses change rarely,
/// are small, and a file is inspectable and diffable in a way a `.store` is not.
///
/// The failure posture is ``DesignStore``'s exactly: an unreadable or undecodable
/// file yields an empty store. Losing a lens costs the user a re-fit they still
/// have the prompt for; refusing to launch costs them their browser.
///
/// Two write paths, because they carry different stakes. An edit the user made —
/// a save, a delete, a switch — goes to disk immediately: it is their work, and
/// they are watching. A ``LensReport`` is the engine talking, arriving every
/// 500ms per lens for as long as a feed is scrolling, so it is deduplicated and
/// then coalesced behind ``flush()``. See ``recordReport(_:)``.
public actor LensStore {
    /// Names are chips in a popover, not prose.
    static let maxNameLength = 80
    /// The prompt is kept for re-fit, so it needs room for a sentence, not an essay.
    static let maxPromptLength = 480
    /// Longest stored path pattern. Real patterns are a handful of segments.
    static let maxPatternLength = 240

    /// How long a changed report may sit in memory before it is written.
    ///
    /// Longer than the engine's own 500ms coalescing window, so a feed that is
    /// genuinely changing under the lens still collapses into one write rather
    /// than one per pass. Short enough that the lost work from a hard kill is a
    /// drift hint the next page load regenerates.
    static let reportFlushDelay: Duration = .seconds(2)

    private let url: URL
    private var lenses: [Lens] = []
    private var loaded = false
    /// Set by ``scheduleFlush()``, cleared by ``persist()``. See ``recordReport(_:)``.
    private var isDirty = false
    private var flushTask: Task<Void, Never>?

    public init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
    }

    public static func defaultURL() -> URL {
        let directory = URL.applicationSupportDirectory.appending(
            path: "Zentic",
            directoryHint: .isDirectory
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "Lenses.json")
    }

    // MARK: Reading

    /// The lenses that apply to one URL, newest edit first.
    ///
    /// This is the whole matching rule in one place: enabled, this host, a path
    /// pattern that covers this path.
    ///
    /// ``Lens/updatedAt`` descending, and that is a *reading* order, not an
    /// arbitration one. There used to be an explicit `Lens.order`, a
    /// drag-to-reorder list, a specificity tie-break and a conflict pass on both
    /// sides of the bridge that had to agree about which of two clashing ops the
    /// user would see — all of it answering a question the cascade already
    /// answers, and answering it twice is how an op came to be reported `skipped`
    /// by a rule the page had never applied. Where two lenses genuinely touch one
    /// element the browser decides, in public, by the specificity of the selectors
    /// involved.
    ///
    /// So this order reaches the user, not the page: it is the popover's list and
    /// the order of ``LensState/entries``, and the lens they edited last is the
    /// one they were thinking about, so it is the one they read first. The engine
    /// re-sorts what it is handed — `appliesBefore` in `web/src/lens/index.ts`
    /// puts the newest edit *last*, so that the most recently touched lens is the
    /// one the cascade lets stand.
    ///
    /// **The two directions are one relationship: that list is this one,
    /// reversed, whole.** Two sorts of one field pointing opposite ways is how the
    /// path matcher came to disagree across the bridge, so it is pinned by a test
    /// rather than by two comments agreeing with each other — `stackingOrderIsTotal`
    /// and `popoverListsTheLensThePageIsShowing` here, and "is the exact reverse of
    /// the list the store hands over" in `web/test/lens/engine.test.ts`.
    ///
    /// Ties break on id so the sequence is total: two lenses saved in the same
    /// millisecond must not swap places between one page load and the next. The
    /// engine breaks the same tie *backwards*, which is what keeps the reversal
    /// whole; when both sides broke it on ascending id the popover's first row was
    /// not the lens the page was showing.
    public func lenses(for host: String, path: String) -> [Lens] {
        load()
        let origin = Self.normalisedOrigin(host)
        return
            lenses
            .filter { lens in
                lens.isEnabled
                    && Self.normalisedOrigin(lens.origin) == origin
                    && LensPath.matches(pattern: lens.pathPattern, path: path)
            }
            .sorted(by: Self.newestFirst)
    }

    /// Every stored lens, grouped by origin and then newest edit first, for the
    /// management list.
    public func all() -> [Lens] {
        load()
        return lenses.sorted { a, b in
            let originA = Self.normalisedOrigin(a.origin)
            let originB = Self.normalisedOrigin(b.origin)
            if originA != originB { return originA < originB }
            return Self.newestFirst(a, b)
        }
    }

    public func lens(id: String) -> Lens? {
        load()
        return lenses.first { $0.id == id }
    }

    // MARK: Writing

    /// Insert or replace one lens.
    ///
    /// The cap is enforced on insert only. Editing a lens on a site that is already
    /// at the limit has to keep working — the cap exists to stop a site accumulating
    /// an unreasoning pile of lenses, not to trap the user in the pile they have.
    public func save(_ lens: Lens) throws {
        load()
        guard lens.isCompatible else {
            throw LensStoreError.incompatibleSchema(version: lens.schemaVersion)
        }
        // Everything the store hands back ends up in `ReaderConfiguration.lenses`,
        // which is interpolated into the bootstrap script, so this is the last
        // place a hand-built or model-authored lens can be stopped. Validating on
        // the way *in* rather than on the way out means the check happens once
        // per edit instead of once per navigation.
        guard let lens = lens.validated() else {
            throw LensStoreError.rejected(reason: "no op in this lens could act on a page")
        }

        if let index = lenses.firstIndex(where: { $0.id == lens.id }) {
            lenses[index] = lens
        } else {
            let origin = Self.normalisedOrigin(lens.origin)
            let existing = lenses.filter { Self.normalisedOrigin($0.origin) == origin }.count
            guard existing < Budget.lensMaxLensesPerOrigin else {
                throw LensStoreError.tooManyLenses(
                    origin: origin,
                    limit: Budget.lensMaxLensesPerOrigin
                )
            }
            lenses.append(lens)
        }
        persist()
    }

    /// Fold a draft from the editor into the stored set.
    ///
    /// Whether Save means "replace" or "add" is decided by exactly one thing: does
    /// the id the draft carries name a lens that is already here. The editor sets it
    /// when it was opened on a lens and mints a fresh one when it was not, so the
    /// question is answered by the surface that knows the answer rather than guessed
    /// from the ops.
    ///
    /// Getting this wrong is not a cosmetic duplicate. A draft that always inserted
    /// left the original enabled beside the copy, so every op ran twice, and editing
    /// a site with two lenses produced a third holding both — past 40 merged ops
    /// ``Lens/validated()`` then truncated the rest without saying so.
    ///
    /// ``Lens/createdAt`` comes from the record being replaced, never from the
    /// draft: the editor has no idea when the lens was first written and must not
    /// be able to say. ``Lens/updatedAt`` is stamped here rather than taken from
    /// the payload for the same reason, and it is load-bearing now that it is also
    /// the list order — a page that could name its own edit time could put its
    /// lens at the top of the user's list and keep it there. The origin comes from
    /// the tab on the same principle: events travel page → app, which is the
    /// untrusted direction.
    ///
    /// ## The catalog is not optional
    ///
    /// A draft is a page talking to us, so its selectors are measured against
    /// ``RegionCatalog/knownSelectors`` — the anchors that page actually offered.
    /// That is not a nicety, it is the breadth gate: ``LensToken/regionSelector(_:)``
    /// only rejects the literal spellings of the page root, because the 230-line
    /// CSS subject parser that used to reason about `:is(body)` and `*:not(.keep)`
    /// was deleted along with the one caller that needed it. Validating a draft
    /// with no catalog would put that hole back exactly where the parser was, and
    /// a lens naming `:is(body)` compiles to `{display:none!important}` over the
    /// whole site on every visit.
    ///
    /// So this takes a catalog rather than an optional one. A caller with nothing
    /// to check against has to say so to the user, not save the draft unchecked.
    @discardableResult
    public func save(draft: Lens, origin: String, against catalog: RegionCatalog) throws -> Lens {
        load()
        guard let origin = Self.validOrigin(origin) else {
            throw LensStoreError.rejected(reason: "the lens names no host")
        }

        // Matched within the origin, not across the whole store. The id is chosen by
        // the page, which is the untrusted direction: a draft naming a lens saved for
        // another site would otherwise rewrite that lens and move it here, deleting
        // the user's work on a site they are not even looking at. Refused rather than
        // re-homed, because there is no honest thing to do with it.
        let existing = lenses.first { $0.id == draft.id }
        if let existing, Self.normalisedOrigin(existing.origin) != origin {
            throw LensStoreError.rejected(reason: "that lens belongs to \(existing.origin)")
        }
        let now = Date()
        var lens = draft
        lens.origin = origin
        lens.createdAt = existing?.createdAt ?? now
        lens.updatedAt = now
        lens.schemaVersion = Lens.currentSchemaVersion
        // Editing invalidates the record of what the previous shape did: the report
        // counts ops by id, and the ids it counted may not be in the lens any more.
        lens.lastReport = nil

        // Against the page, before `save(_:)` re-checks the shape. `save(_:)` has
        // no catalog — it is also the disk-read path — so it cannot be the place
        // this happens.
        guard let checked = lens.validated(against: catalog) else {
            throw LensStoreError.rejected(reason: "nothing in this lens is on this page")
        }
        try save(checked)
        // The record as stored, not as offered: it has been through the catalog
        // gate and then the shape gate, and the caller re-applies what comes back
        // to the page.
        return lenses.first { $0.id == checked.id } ?? checked
    }

    public func delete(id: String) {
        load()
        lenses.removeAll { $0.id == id }
        persist()
    }

    public func setEnabled(_ isEnabled: Bool, id: String) {
        load()
        guard let index = lenses.firstIndex(where: { $0.id == id }) else { return }
        guard lenses[index].isEnabled != isEnabled else { return }
        lenses[index].isEnabled = isEnabled
        lenses[index].updatedAt = Date()
        persist()
    }

    /// Remember what a lens actually did, so drift survives a relaunch.
    ///
    /// Without this the toolbar can only show drift after the page it drifted on
    /// has finished loading, which is precisely when the user has already seen the
    /// site look wrong and concluded the browser is broken.
    ///
    /// A report for a lens that no longer exists is normal — a page keeps running
    /// the set it was given until it reloads — so it is dropped, not an error.
    ///
    /// The report is validated first, because this is the one field of a ``Lens``
    /// that travels page → app: it arrives on an event, is written to disk, is
    /// read back on every launch, and is rendered in the popover. Nothing capped
    /// its result count or any of its strings, and ``LensReport/validated()`` also
    /// reduces the URL to a path — the stripping lived only in the TypeScript,
    /// which is to say the store trusted the untrusted side to redact its own
    /// browsing history.
    ///
    /// ## Why this one write path is guarded twice
    ///
    /// This is the hottest writer in the app and the only one nobody asked for.
    /// `LensEngine` re-posts a coalesced full report every 500ms for as long as
    /// any observer is live, and the tab records one per lens, so three lenses on
    /// a scrolling feed meant six whole-store encode-and-write cycles a second on
    /// a file that reaches a few hundred kilobytes.
    ///
    /// So: a report that says the same thing as the one already stored is dropped
    /// outright — on a steady page every pass is identical but for its timestamp,
    /// which is nearly all of them. What survives that is a genuine change (a
    /// virtualised feed rewrote itself and `matchedCount` moved), and those are
    /// coalesced by ``scheduleFlush()`` instead of hitting the disk inline.
    ///
    /// The stored timestamp is therefore when this *finding* was first seen, not
    /// when the last identical pass ran. That is the more useful of the two, and
    /// it is the only one either would be honest about: nothing renders it.
    public func recordReport(_ report: LensReport) {
        load()
        guard let report = report.validated() else { return }
        guard let index = lenses.firstIndex(where: { $0.id == report.lensID }) else { return }
        if let stored = lenses[index].lastReport, stored.saysTheSameAs(report) { return }
        lenses[index].lastReport = report
        scheduleFlush()
    }

    /// Write out anything a report left pending.
    ///
    /// The counterpart to ``scheduleFlush()``, and the reason it is allowed to
    /// wait: a delayed write needs someone able to force it before the process
    /// goes away. Called on the way to termination — see
    /// `BrowserViewController.persistBeforeTermination()`.
    public func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard isDirty else { return }
        persist()
    }

    // MARK: Ordering

    /// Most recently edited first, then ascending id. See ``lenses(for:path:)``
    /// for why that is the whole rule now, and why `appliesBefore` in
    /// `web/src/lens/index.ts` breaks the same tie the other way round.
    private static func newestFirst(_ a: Lens, _ b: Lens) -> Bool {
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.id < b.id
    }

    // MARK: Origins

    /// Hosts are compared case-insensitively because DNS is, and a lens saved from
    /// `WWW.Example.com` must still match `www.example.com`.
    static func normalisedOrigin(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A host that could have come from a URL. Anything with a path, a scheme or
    /// whitespace in it did not.
    static func validOrigin(_ host: String) -> String? {
        let normalised = normalisedOrigin(host)
        guard !normalised.isEmpty, normalised.count <= 253 else { return nil }
        guard !normalised.contains(where: { $0 == "/" || $0 == " " || $0.isNewline }) else {
            return nil
        }
        return normalised
    }

    // MARK: Persistence

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url) else { return }
        // Same posture as `DesignStore`: a file we cannot read is an empty store,
        // never a throw. The user loses lenses they can re-fit from their own saved
        // prompts; the alternative is a browser that will not open.
        let decoded = (try? JSONDecoder().decode([Lens].self, from: data)) ?? []
        // Lenses from a build with a different shape are dropped rather than
        // migrated, per `Lens.currentSchemaVersion`: a lens whose ops half-apply
        // rearranges a page in a way the user cannot explain or undo. Everything
        // else goes through validation, because the file on disk is editable by
        // anything that can write to Application Support — including a previous
        // build of Zentic whose gate was looser than this one.
        lenses = decoded.compactMap { $0.validated() }
    }

    /// Everything, on disk, now.
    ///
    /// Unformatted. It used to be `[.prettyPrinted, .sortedKeys]`, which is a
    /// third again the bytes and a sort of every key in every op, for a file no
    /// human reads: the one surface that showed these bytes to a person was
    /// `export`, and that is gone. `Lenses.json` is still readable with `jq` on
    /// the rare occasion anyone wants to look.
    private func persist() {
        isDirty = false
        guard let data = try? JSONEncoder().encode(lenses) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Note that the store has changed, and arrange for exactly one write soon.
    ///
    /// Only ``recordReport(_:)`` uses this. Everything else here is an edit the
    /// user made and is watching, so it persists inline — a lens that survives a
    /// crash only if it happened to be more than a second old is not saved.
    private func scheduleFlush() {
        isDirty = true
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reportFlushDelay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }
}

// MARK: - Report equivalence

extension LensReport {
    /// Does this report say the same thing as that one?
    ///
    /// Everything but ``generatedAt``, which moves on every pass whether or not
    /// anything about the page did. Written out rather than mutating a copy and
    /// using `==` so that a field added to ``LensReport`` has to be considered
    /// here: a new field left out of this comparison would silently stop reports
    /// that differ in it from ever being written.
    fileprivate func saysTheSameAs(_ other: LensReport) -> Bool {
        lensID == other.lensID && url == other.url && results == other.results
    }
}

// MARK: - Path patterns

/// How a lens decides that this page is one of the pages it is for.
///
/// A port of `pathPattern()` in `web/src/skeleton.ts`, and it has to stay a port.
/// The editor shows the user the literal pattern it is about to save ("pages like
/// this: `/posts/*/*`"), and the store decides on every navigation whether that
/// pattern covers the current path. If the two generalisations disagree by one
/// rule, a lens the user watched being created silently never applies again, and
/// the drift UI cannot explain it — because nothing drifted.
enum LensPath {
    /// Matches every path in the origin.
    static let wildcard = "*"

    /// Generalise a concrete path into the pattern that covers pages like it.
    ///
    /// Character-for-character the TypeScript's rules: numeric segments, long hex
    /// runs, anything containing a UUID, anything longer than 24 characters, and
    /// short-but-numbered slugs all become `*`. `[0-9]` rather than `\d` on
    /// purpose — ICU's `\d` also matches non-ASCII digit scripts, and JavaScript's
    /// does not, so `\d` here would be a silent divergence of exactly the kind this
    /// type exists to prevent.
    static func pattern(for pathname: String) -> String {
        let segments = pathname.split(separator: "/").map(String.init)
        guard !segments.isEmpty else { return "/" }

        let generalised = segments.map { segment -> String in
            let decoded = segment.removingPercentEncoding ?? segment
            if matches(decoded, "^[0-9]+$") { return wildcard }
            if matches(decoded, "^[0-9a-fA-F]{16,}$") { return wildcard }
            if matches(decoded, "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}") { return wildcard }
            // A slug: long, or hyphenated with a number in it.
            if decoded.count > 24 { return wildcard }
            if matches(decoded, "[0-9]"), decoded.count > 4 { return wildcard }
            return decoded
        }

        return "/" + generalised.joined(separator: "/")
    }

    /// Does this pattern cover this path?
    ///
    /// Segment-wise, with `*` standing for one segment, rather than "generalise the
    /// path and compare strings". The two are not the same: `/posts/12345/my-title`
    /// generalises to `/posts/*/my-title`, because `my-title` is short and has no
    /// digits in it — so a user who chose "the whole `/posts/*/*` shape" would never
    /// match the very page they were looking at. Comparing segments makes the
    /// generalised pattern a *lower* bound on what matches, which is the behaviour
    /// the scope control promises.
    static func matches(pattern: String, path: String) -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if pattern == wildcard { return true }

        // Both sides are decoded, segment by segment. Only the path used to be,
        // and that made a "this page" lens never fire on the page it was created
        // on for any URL with a non-ASCII or spaced segment: the stored pattern
        // held `%E7%8C%AB` and the live path decoded to `猫`, so the comparison
        // was between two spellings of the same segment. Decoding after the split
        // keeps an encoded `%2F` from inventing a segment boundary.
        let patternSegments = pattern.split(separator: "/").map {
            String($0).removingPercentEncoding ?? String($0)
        }
        let pathSegments = path.split(separator: "/").map {
            String($0).removingPercentEncoding ?? String($0)
        }
        guard patternSegments.count == pathSegments.count else { return false }

        for (expected, actual) in zip(patternSegments, pathSegments) {
            guard expected == wildcard || expected == actual else { return false }
        }
        return true
    }

    /// A pattern safe to store, from input we did not author.
    ///
    /// Anything that is not a rooted path or the wildcard becomes the wildcard: a
    /// lens that applies to the whole site is a thing the user can see and turn
    /// off, whereas a malformed pattern is a lens that appears in the list and
    /// never fires.
    static func stored(_ pattern: String) -> String {
        let cleaned = LensToken.plainText(pattern, limit: LensStore.maxPatternLength)
        guard cleaned != wildcard else { return wildcard }
        guard cleaned.hasPrefix("/") else { return wildcard }
        return cleaned
    }

    private static func matches(_ value: String, _ expression: String) -> Bool {
        value.range(of: expression, options: .regularExpression) != nil
    }
}
