import AppKit
import ZenticKit

/// Drives lenses: which ones a page gets, who authors them, and where they live.
///
/// ``RedesignController``'s sibling, and deliberately shaped like it — prompt, call
/// a model, save the answer — with one difference that runs through everything
/// here. A design is generated once and reused; a lens is generated once and
/// *replayed*, on every visit, against a page that is free to change underneath it.
/// So this type is as much about drift as it is about authoring: it owns the store
/// that persists what each lens actually did, and the re-fit path that repairs a
/// lens whose selectors stopped matching without asking the user to describe their
/// intent a second time.
@MainActor
final class LensController {
    static let shared = LensController()

    let store = LensStore()

    /// Posted after any change to the stored set, so open surfaces can refresh.
    ///
    /// The toolbar's state and an open popover both derive from the store, and a
    /// popover that keeps showing a lens the user just deleted is the kind of
    /// staleness people read as a bug. Broadcast rather than a callback because
    /// this is a process-lifetime singleton and windows are not: a hand-rolled
    /// list of `(weak owner, closure)` pairs was doing exactly what
    /// `NotificationCenter` already does — multicast, and drop a registrant that
    /// has been deallocated. Registered with the selector-based API on purpose:
    /// that one holds the observer weakly and unregisters it when it goes, which
    /// the block-based one does not.
    ///
    /// Posted on the main actor, so every handler runs before the next event.
    static let didChangeLenses = Notification.Name("ZenticLensesDidChange")

    private func notifyChanged() {
        NotificationCenter.default.post(name: Self.didChangeLenses, object: self)
    }

    /// Lens authoring is OpenAI-only.
    ///
    /// Not a routing choice the user makes: ``FoundationModelsProvider`` declines
    /// both lens calls, because authoring ops over a hundred candidate regions is a
    /// long structured generation and a small model that returns three plausible ops
    /// naming two regions that do not exist produces a lens which *appears* to work
    /// and rearranges the wrong parts of the page.
    private let openAI = OpenAIProvider()

    // MARK: - Reading

    /// The enabled lenses for one URL, in the order they must be applied.
    ///
    /// Async because the matching rule — host, path pattern, last edit — lives in
    /// ``LensStore`` and must stay there: the popover lists this set in the order
    /// it arrives and the page applies it in exactly that order reversed, so a
    /// second implementation on the app side would show the user a list the page
    /// is not running. See ``LensStore/lenses(for:path:)`` for why the two point
    /// opposite ways.
    func lenses(for url: URL) async -> [Lens] {
        guard let host = url.host() else { return [] }
        return await store.lenses(for: host, path: url.path())
    }

    /// Every lens for a host, enabled or not, in application order.
    ///
    /// The popover's list. Disabled lenses are in it because the checkbox that
    /// switches one back on has to have a row to live in.
    func allLenses(for url: URL) async -> [Lens] {
        guard let host = url.host() else { return [] }
        let origin = host.lowercased()
        return await store.all().filter { $0.origin.lowercased() == origin }
    }

    func lens(id: String) async -> Lens? {
        await store.lens(id: id)
    }

    // MARK: - Authoring

    /// Author ops from the user's words and a textless catalog of the page.
    ///
    /// **Always returns a proposal, and a proposal with no ops is the failure.** The
    /// editor is a modal surface waiting on this answer: it has put the user's prompt
    /// behind an "asking…" state and disabled Ask, and there is no other event on the
    /// wire that would ever release it. Returning nil and raising an alert left the
    /// overlay stuck there for the rest of the page's life — the alert explained the
    /// failure to someone who then had to press Escape and lose what they had typed.
    /// So the reason travels back on ``LensProposal/note``, and the alert is the
    /// second half of telling them, not the only half.
    ///
    /// The catalog is the only thing about the page that leaves the device, and it
    /// carries no characters from it: invariant 4.
    func generate(
        prompt: String,
        selectedRegionIDs: [String],
        catalog: RegionCatalog,
        origin: String?,
        over window: NSWindow?
    ) async -> LensProposal {
        if let reason = await unavailableReason(over: window) {
            return Self.failure(reason)
        }

        do {
            let proposal = try await openAI.generateLens(
                LensRequest(
                    catalog: catalog,
                    prompt: prompt,
                    selectedRegionIDs: selectedRegionIDs
                )
            )
            // The provider is contractually required to return validated output.
            // Checked again here anyway: this is the one call site that hands a
            // proposal straight to a live page, and the gate costs nothing next to
            // the request that produced it.
            let safe = proposal.validated(against: catalog)
            guard !safe.ops.isEmpty else {
                let reason = "The model did not find anything on this page it could act on."
                present(error: reason, over: window)
                return Self.failure(reason)
            }
            trace("lens", "authored \(safe.ops.count) ops for \(origin ?? "page"): \(prompt)")
            return safe
        } catch {
            let reason = RedesignController.message(for: error)
            present(error: reason, over: window)
            return Self.failure(reason)
        }
    }

    /// A proposal that proposes nothing, carrying the reason. The editor reads an
    /// empty op list as "that did not work" and puts the prompt back.
    private static func failure(_ reason: String) -> LensProposal {
        LensProposal(regions: [], ops: [], note: reason)
    }

    /// Re-derive a drifted lens's selectors from what its regions were *for*.
    ///
    /// The recovery path, and the reason ``LensRegion/intent`` is stored at all. The
    /// site redesigned, the saved selectors match nothing, and the ops are still
    /// exactly what the user asked for — so only the regions go back to the model,
    /// and they go back described in words rather than as the class names that just
    /// stopped existing.
    ///
    /// The old report is dropped on success: it describes a page that no longer
    /// exists, and leaving it in place would badge the repaired lens as drifted
    /// until the next visit.
    ///
    /// The lens is re-read by id and the argument is used for nothing but its id.
    /// Every other action here resolves against the store; this one wrote back the
    /// value the popover was built from, which is a value a model call's worth of
    /// seconds old. ``LensStore/save(_:)`` inserts when the id is absent, so
    /// re-fitting a lens another window had deleted **brought it back**, and
    /// re-fitting one another window had edited overwrote the edit with the shape
    /// this popover happened to be showing.
    @discardableResult
    func refit(lens: Lens, catalog: RegionCatalog, over window: NSWindow?) async -> Lens? {
        guard let current = await store.lens(id: lens.id) else {
            present(error: Self.message(for: LensStoreError.notFound(id: lens.id)), over: window)
            return nil
        }
        guard !current.regions.isEmpty else {
            present(error: "This lens has no regions to re-fit.", over: window)
            return nil
        }
        if await unavailableReason(over: window) != nil { return nil }

        do {
            let regions = try await openAI.refitLens(
                LensRefitRequest(catalog: catalog, regions: current.regions)
            )
            // Ops are untouched, so the ids they name have to survive: a region the
            // model renamed is a region every op referencing it just lost. Matching
            // by id and keeping the original where the model returned nothing is
            // what makes a partial re-fit a partial repair rather than a wipe.
            // Through the proposal gate rather than trusting the return: a region is
            // a set of selectors that will be compiled into a stylesheet, so it
            // crosses the same boundary op authoring does. Ops are empty here
            // because the model was not asked for any.
            let checked = LensProposal(regions: regions, ops: [], note: "")
                .validated(against: catalog)
            let refitted = Dictionary(
                checked.regions.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            guard !refitted.isEmpty else {
                present(
                    error: "The model could not find these regions on the page as it is now.",
                    over: window
                )
                return nil
            }

            // Read again, not reused from before the model call: a call takes
            // seconds, and a lens deleted in the meantime must not be resurrected by
            // its own repair.
            guard let latest = await store.lens(id: current.id) else {
                present(error: Self.message(for: LensStoreError.notFound(id: current.id)), over: window)
                return nil
            }
            var updated = latest
            updated.regions = latest.regions.map { refitted[$0.id] ?? $0 }
            updated.updatedAt = Date()
            updated.lastReport = nil

            do {
                try await store.save(updated)
            } catch {
                present(error: Self.message(for: error), over: window)
                return nil
            }
            notifyChanged()
            trace(
                "lens",
                "re-fitted \(updated.name): \(refitted.count)/\(updated.regions.count) regions"
            )
            return updated
        } catch {
            present(error: RedesignController.message(for: error), over: window)
            return nil
        }
    }

    /// Availability, and the key sheet at the moment it is needed.
    ///
    /// Same posture as the redesign flow: ask for the key when the user has just
    /// asked for something that needs it, rather than sending them to a menu they
    /// have not found yet.
    ///
    /// - Returns: nil when the model can be called, or the reason it cannot — which
    ///   the caller may need to pass on to a surface that is waiting on the answer,
    ///   not only put in an alert.
    private func unavailableReason(over window: NSWindow?) async -> String? {
        if !APIKeyStore.has(.openAI) {
            RedesignController.shared.promptForAPIKey()
            guard APIKeyStore.has(.openAI) else {
                // They dismissed the key sheet, so they know why nothing happened. A
                // second alert saying it again would be the app arguing with them.
                return "Authoring a lens needs an OpenAI key."
            }
        }
        switch await openAI.availability() {
        case .available:
            return nil
        case .unavailable(let reason), .ineligible(let reason):
            present(error: reason, over: window)
            return reason
        }
    }

    // MARK: - Storage

    /// Persist a lens the in-page editor produced.
    ///
    /// The origin is taken from the tab, never from the payload. Events travel
    /// page → app, which is the untrusted direction: a draft naming someone else's
    /// host would install a lens that fires on a site the user was not looking at,
    /// and "the editor is in our own content world" is a reason to expect that not
    /// to happen, not a reason to allow it if it does.
    ///
    /// Ops and regions go through the same gate as model output, in
    /// ``LensStore/save(draft:origin:against:)``. An op that survives none of it is
    /// dropped, and a draft left with no ops is refused rather than saved as a lens
    /// that does nothing on every visit.
    ///
    /// Whether this replaces a lens or adds one is decided by the id the draft
    /// carries, in ``LensStore/save(draft:origin:)``. The editor sets it when it was
    /// opened on an existing lens; a draft authored from nothing carries an id the
    /// store has never seen, and inserts.
    ///
    /// A draft with no catalog behind it is refused rather than saved unchecked:
    /// the catalog is the breadth gate on this path, and there is no honest way to
    /// wave a page's own selectors through without one. It should not be
    /// reachable — the editor cannot open on a page with no engine in it, and the
    /// engine is what builds the catalog.
    @discardableResult
    func save(
        draft: Lens,
        for url: URL,
        against catalog: RegionCatalog?,
        over window: NSWindow?
    ) async -> Lens? {
        guard let host = url.host() else {
            present(error: "A lens needs a site. This page has no address.", over: window)
            return nil
        }
        guard let catalog else {
            present(
                error: "This page did not say what is on it, so there is nothing to "
                    + "check this lens against.",
                over: window
            )
            return nil
        }

        let lens: Lens
        do {
            lens = try await store.save(draft: draft, origin: host, against: catalog)
        } catch {
            present(error: Self.message(for: error), over: window)
            return nil
        }
        notifyChanged()
        trace("lens", "saved \(lens.name) for \(host) · \(lens.ops.count) ops")
        return lens
    }

    /// - Returns: false when there was nothing there to delete, so a caller that has
    ///   just asked the user to confirm can say what happened instead of appearing
    ///   to have ignored them.
    @discardableResult
    func delete(id: String) async -> Bool {
        guard await store.lens(id: id) != nil else { return false }
        await store.delete(id: id)
        notifyChanged()
        return true
    }

    func setEnabled(_ isEnabled: Bool, id: String) async {
        await store.setEnabled(isEnabled, id: id)
        notifyChanged()
    }

    /// Copy a lens, so the user can try a variant without losing the one that works.
    ///
    /// A missing source is reported rather than returned as nil into a discarded
    /// result: the popover's rows are a snapshot, so pressing Duplicate on a lens
    /// another window deleted is an ordinary thing to do, and it used to be a menu
    /// item that did nothing whatsoever.
    @discardableResult
    func duplicate(id: String, over window: NSWindow?) async -> Lens? {
        guard let source = await store.lens(id: id) else {
            present(error: Self.message(for: LensStoreError.notFound(id: id)), over: window)
            return nil
        }
        var copy = source
        copy.id = UUID().uuidString
        copy.name = Self.copyName(of: source.name)
        copy.createdAt = Date()
        // Stamped now, so the copy is the newest lens for the site and therefore
        // the row the user lands on — which is where they were looking when they
        // pressed Duplicate.
        copy.updatedAt = Date()
        // The copy has never run. Carrying the original's report would badge it as
        // drifted for a page load it was not part of.
        copy.lastReport = nil
        do {
            try await store.save(copy)
        } catch {
            present(error: Self.message(for: error), over: window)
            return nil
        }
        notifyChanged()
        return copy
    }

    private static func copyName(of name: String) -> String {
        name.hasSuffix(" copy") ? name + " 2" : name + " copy"
    }

    /// Record what a lens did, so drift survives a relaunch.
    func record(_ report: LensReport) async {
        await store.recordReport(report)
    }

    // MARK: - Alerts

    private func present(error: String, over window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Could not do that with this lens"
        alert.informativeText = error
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    /// A store failure in the user's terms. Each case is something they did, so each
    /// gets a sentence naming the thing they can do about it.
    private static func message(for error: any Error) -> String {
        guard let store = error as? LensStoreError else { return "\(error)" }
        switch store {
        case .notFound:
            return "That lens is no longer saved."
        case .tooManyLenses(let origin, let limit):
            return """
                \(origin) already has \(limit) lenses, which is as many as one site \
                gets. Delete one first.
                """
        case .incompatibleSchema:
            return "That lens was written by a different version of Zentic."
        case .rejected(let reason):
            return "Zentic would not save that lens — \(reason)."
        }
    }
}
