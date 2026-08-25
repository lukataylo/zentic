import AppKit
import WebKit
import ZenticKit

@MainActor
protocol TabControllerDelegate: AnyObject {
    /// Title, URL, favicon, or navigation-button state changed.
    func tabControllerDidChangeChrome(_ controller: TabController)
    /// The page finished loading — the cue to drop a suspended tab's snapshot.
    func tabControllerDidFinishLoad(_ controller: TabController)
    /// A main-frame navigation committed. Drives history and visit counting.
    func tabController(_ controller: TabController, didCommit url: URL, title: String)
    /// A link asked for a new tab (⌘-click, `target=_blank`, `window.open`).
    func tabController(_ controller: TabController, wantsNewTabFor url: URL)
    func tabController(_ controller: TabController, didStart download: WKDownload)
}

/// One browser tab: its record, and — only while resident — its `WKWebView` and
/// `ReaderBridge`.
///
/// The split between record and web view is the whole suspension design. The
/// record is always authoritative: URL, title, favicon and scroll offset are
/// written back as they change, so `suspend()` only has to capture what cannot be
/// observed incrementally (the opaque session state and a snapshot) before letting
/// the web view go.
@MainActor
final class TabController: NSObject {
    let id: UUID
    let record: Tab
    weak var delegate: (any TabControllerDelegate)?

    private(set) var webView: WKWebView?
    private var bridge: ReaderBridge?
    private let faviconService: FaviconService

    /// Current reader mode, so ⌘\ has something to toggle against.
    private(set) var readerMode: ReaderMode = .restructured

    /// The most recent extraction, kept because rewriting needs its sections.
    ///
    /// Cleared on navigation: rewriting the previous page's paragraphs into the
    /// current one would be the worst possible failure for a feature whose whole
    /// premise is fidelity.
    private(set) var extraction: ExtractionResult?

    /// How far a rewrite has got, for the toolbar and the tab's indicator.
    enum RewriteState: Equatable {
        case none
        case running(done: Int, total: Int)
        /// A rewrite is on screen. The original text is still in the shadow DOM.
        case shown
        case failed(String)
    }

    private(set) var rewriteState: RewriteState = .none
    private var rewriteTask: Task<Void, Never>?

    /// Whether the reader actually rendered this page, as opposed to deciding it
    /// should not and passing the original through.
    ///
    /// Taken from the reveal reason rather than inferred from `extraction != nil`:
    /// extraction runs on almost every page and often concludes that it should
    /// keep its hands off — low confidence, an app, or a few words of prose. A
    /// control that read "Transformed" on a page that was passed through would be
    /// stating the opposite of what the user is looking at.
    private(set) var didRestructure = false

    /// Whether the page on screen is Zentic's rendering or the site's own.
    var isTransformed: Bool { readerMode == .restructured && didRestructure }

    /// Scroll offset to reapply once loading finishes.
    ///
    /// Only set when `interactionState` was unavailable — WebKit restores scroll
    /// itself from a session, and scrolling on top of that fights it.
    private var pendingScrollY: Double?
    private var lastCommittedURL: URL?

    /// Set once the tab is closed. Every write to ``record`` is gated on it: the
    /// store deletes the record synchronously while snapshot capture and suspension
    /// are in flight, and SwiftData traps on any access to a deleted object.
    private var isDiscarded = false

    // MARK: Lenses

    /// A lens set, and the URL it was resolved for.
    ///
    /// The pairing is the whole point. Everything that resolves a set does so across
    /// an `await`, and a tab can be somewhere else by the time it resumes, so a set
    /// without the URL it belongs to cannot be checked against the page in front of
    /// the user — which is how the chrome ended up describing a page it was not
    /// looking at.
    private struct LensPlan {
        var url: URL
        var lenses: [Lens]
        var siteLensCount: Int
        var enabledLensCount: Int

        /// Whether this plan is still about the page at `url`. Path and host only:
        /// a fragment is not a navigation, and a query change does not re-resolve a
        /// set that matches on host and path pattern.
        func describes(_ url: URL?) -> Bool {
            guard let url else { return false }
            return url.host() == self.url.host() && url.path() == self.url.path()
        }
    }

    /// The lens set this page was given, in application order.
    ///
    /// Resolved before the navigation is allowed, so it is already in the bootstrap
    /// script by `document-start` — the `hide` and `restyle` ops compile to a
    /// stylesheet, and a stylesheet that arrives as a command arrives after the
    /// first paint, which is the user watching the sidebar they removed appear and
    /// then vanish.
    private(set) var appliedLenses: [Lens] = []

    /// The set resolved for a navigation that has not committed yet.
    ///
    /// A policy decision is not a page. The navigation it approves can fail, be
    /// cancelled by the next click, turn out to be a download, or be beaten by a
    /// redirect — and committing the new URL's lens count and badge at that moment
    /// left the *old* page on screen described by the *new* page's chrome. So the
    /// bootstrap is armed there, because that is the last moment it can be, and
    /// everything the chrome reads waits for `didCommit`.
    private var stagedPlan: LensPlan?

    /// Every lens saved for this host, matching this page or not. Only the count is
    /// used — the toolbar has to distinguish "this site has no lenses" from "this
    /// site's lenses are all switched off", and those look identical otherwise.
    private var siteLensCount = 0
    /// Of those, the ones switched on. The toolbar needs both to tell "this site's
    /// lens is off" from "this site's lens is on, for another page".
    private var enabledLensCount = 0

    /// The URL the reports and the applied set describe.
    ///
    /// Not the same question as "what is the web view showing": a same-document
    /// navigation moves that instantly, while the set and the reports still belong
    /// to the route the user just left until a pass has run for the new one.
    private var lensURL: URL?

    /// Which resolution is the current one. Bumped as each starts, checked when it
    /// resumes: an actor hop is not ordered, and the answer to an older question
    /// arriving last is how a tab ends up armed for a page it already left.
    private var lensPlanSequence = 0

    /// What each lens actually did on *this* page load, keyed by lens id.
    ///
    /// Cleared on navigation. Invariant 8 applies: the badge is drawn from these and
    /// nothing else, so a stale report from the previous page would be a fabricated
    /// count of what the current one did.
    private var lensReports: [String: LensReport] = [:]

    /// The most recent textless catalog of the page, for authoring and re-fitting.
    private var catalog: RegionCatalog?
    /// Callers waiting on a fresh catalog. Drained on the next `lensRegions` event
    /// or by the timeout, whichever comes first.
    private var catalogWaiters: [CheckedContinuation<RegionCatalog?, Never>] = []
    /// Which catalog request the pending timeout belongs to. See ``freshCatalog()``.
    private var catalogRequest = 0

    /// The last refresh asked for, so the next one can queue behind it rather than
    /// race it. See ``refreshLenses()``.
    private var lensRefresh: Task<Void, Never>?

    private(set) var isLensEditing = false

    /// Which ⌥⌘L we are waiting on an answer to, and what to say if none comes.
    ///
    /// ``ReaderBridge/send(_:to:)`` cannot report an unreachable page: the injected
    /// call is optional-chained, so a document with no bundle in it — a PDF, an error
    /// page, a `view-source:` — accepts the command and does nothing, and the send
    /// succeeds. The only evidence the editor opened is the `lensModeChanged` the
    /// overlay posts back, so silence is the signal, and this is what turns silence
    /// into a sentence.
    private var lensModeRequest = 0
    private var lensModeUnavailable: (@MainActor () -> Void)?

    /// Everything the chrome needs to draw the lens button and popover.
    ///
    /// The presentation is this tab's own fact, and it is the half of the answer the
    /// page cannot supply: a lens acts on the site's document, and while the reader
    /// is rendering its own view of it, none of what the lens did is on screen —
    /// whatever a report that arrived before the switch happens to say.
    var lensState: LensState {
        LensState.make(
            lenses: appliedLenses,
            reports: lensReports,
            siteLensCount: max(siteLensCount, appliedLenses.count),
            enabledLensCount: max(enabledLensCount, appliedLenses.count),
            isReaderRendered: isTransformed
        )
    }

    /// Fires on SPA navigation, where there is no new document and therefore no new
    /// bootstrap — the lens set for `/watch` has to reach a page that is still the
    /// one loaded at `/`.
    private var urlObservation: NSKeyValueObservation?

    /// Samples the scroll offset while resident.
    ///
    /// Polling rather than a JS scroll listener: the offset is only ever needed at
    /// suspension time, so a 2s sample costs nothing, whereas bridging every scroll
    /// frame is a measurable tax on every page.
    private var scrollPoll: Task<Void, Never>?

    init(record: Tab, faviconService: FaviconService) {
        self.id = record.id
        self.record = record
        self.faviconService = faviconService
        super.init()
    }

    deinit {
        // `Task` is Sendable, so a nonisolated deinit may cancel it — which a
        // `Timer` would not have allowed.
        scrollPoll?.cancel()
    }

    var isResident: Bool { webView != nil }
    var title: String { record.displayTitle }
    var url: URL? { webView?.url ?? record.url }
    var isLoading: Bool { webView?.isLoading ?? false }
    var canGoBack: Bool { webView?.canGoBack ?? record.canGoBack }
    var canGoForward: Bool { webView?.canGoForward ?? record.canGoForward }
    var favicon: NSImage? {
        record.faviconData.flatMap(NSImage.init(data:))
    }

    /// The snapshot taken when this tab was suspended, shown while it reloads.
    var snapshot: NSImage? { record.snapshotData.flatMap(NSImage.init(data:)) }

    // MARK: - Residency

    /// Create the web view and bridge, restoring session state.
    @discardableResult
    func realize() -> WKWebView {
        if let webView { return webView }

        let configuration = WKWebViewConfiguration()
        // Shared data store: cookies and logins must survive suspension, and a
        // per-tab store would sign the user out every time a tab was evicted.
        configuration.websiteDataStore = .default()
        // WKWebView's default user agent omits the `Version/… Safari/…` tail, and a
        // surprising number of sites serve a degraded page or an upgrade nag
        // without it. Appended, not replaced — the platform part stays accurate.
        configuration.applicationNameForUserAgent = "Version/18.5 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isSiteSpecificQuirksModeEnabled = true

        // One bridge per tab, on this tab's own configuration. Reader state rides
        // on WKUserScript, which belongs to the configuration's content
        // controller, so a shared configuration would mean shared reader state.
        do {
            let bridge = try ReaderBridge(
                contentController: configuration.userContentController,
                configuration: ReaderConfiguration(
                    mode: readerMode,
                    lenses: appliedLenses,
                    debugLogging: true
                )
            )
            bridge.delegate = self
            self.bridge = bridge
        } catch {
            // A missing bundle must not cost the user a browser. Browsing works
            // without the reader; the reader does not work without browsing.
            trace("bridge", "tab \(shortID) bridge unavailable: \(error)")
        }

        // Ads, trackers and cookie walls. Attached per tab because the shield is
        // per origin — one site being allowed through must not lift blocking
        // everywhere.
        Blocking.attach(to: configuration.userContentController, origin: record.url?.host())

        let webView = TrackedWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        // Let the card's glass show through wherever the page does not paint.
        //
        // A `WKWebView` fills its bounds with an opaque ground before the page
        // draws, so without this the card's translucency is covered by the web view
        // and the window reads as a white rectangle in a tinted frame no matter what
        // alpha the card uses. `underPageBackgroundColor` is the public half and
        // governs over-scroll and the area beyond the page; `drawsBackground` is the
        // half that actually stops the fill, and it has **no public spelling** — it
        // is KVC against an undeclared property. That is a real liability and worth
        // naming rather than burying: if a future WebKit stops honouring the key,
        // `setValue(_:forKey:)` raises an `NSException`, which Swift cannot catch,
        // and every tab creation would trap. The `responds(to:)` guard is what makes
        // that a lost visual effect instead of a browser that will not open a tab.
        webView.underPageBackgroundColor = .clear
        if webView.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        // Lets Safari's Web Inspector attach, which is how the in-page bundle is
        // debugged. Debug builds only — this is a remote-control surface.
        #if DEBUG
        webView.isInspectable = true
        #endif
        self.webView = webView

        // `url` is KVO-compliant and fires for `pushState`, which is the only signal
        // a same-document navigation gives us. Without it a lens scoped to `/watch`
        // would never arrive on a site the user got to by clicking, rather than by
        // typing the address.
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.lensesFollowedTheURL() }
        }

        restoreSession(into: webView)
        startScrollPolling()
        trace("tabs", "realize \(shortID) \(record.urlString)")
        return webView
    }

    private func restoreSession(into webView: WKWebView) {
        if let state = record.interactionState {
            // Restores the whole back/forward list and scroll position in one go.
            // WebKit rejects state from an incompatible build by leaving `url` nil,
            // which the fallback below catches.
            webView.interactionState = state
        }

        if webView.url == nil {
            guard let url = record.url else { return }
            pendingScrollY = record.scrollY > 0 ? record.scrollY : nil
            webView.load(URLRequest(url: url))
        }
    }

    /// Tear down the web view without touching the record.
    ///
    /// For a tab being closed. Suspending one would capture state into a record the
    /// store is about to delete — which is a trap in SwiftData, not a no-op.
    func discard() {
        isDiscarded = true
        stopScrollPolling()
        teardownWebView()
        trace("tabs", "discard \(shortID)")
    }

    private func teardownWebView() {
        urlObservation?.invalidate()
        urlObservation = nil
        // Nothing is going to answer a catalog request from a web view that is being
        // dismantled, and a continuation that is never resumed is a leaked task.
        drainCatalogWaiters(with: nil)
        guard let webView else { return }
        // Stop loading before dropping delegates, or an in-flight navigation can
        // call back into a half-dismantled controller.
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
        // Releasing the bridge releases its user scripts with it; the content
        // controller only ever held a weak proxy back to it.
        self.bridge = nil
    }

    /// Capture restorable state, then tear the web view down.
    ///
    /// Async because the snapshot is: taking it after teardown is impossible and
    /// skipping it means switching to a suspended tab flashes an empty rectangle.
    func suspend() async {
        guard let webView, !isDiscarded else { return }
        stopScrollPolling()

        var state = SuspendedTabState(
            urlString: webView.url?.absoluteString ?? record.urlString,
            title: record.title,
            scrollY: await currentScrollY() ?? record.scrollY,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            interactionState: webView.interactionState as? Data
        )
        state.snapshotData = await captureSnapshot(of: webView)
        // The await above yields, and the tab may have been closed meanwhile.
        guard !isDiscarded else { return }
        record.apply(state)
        teardownWebView()
        trace("tabs", "suspend \(shortID) snapshot=\(record.snapshotData?.count ?? 0)B")
    }

    /// Snapshot this tab while its web view is still in a window.
    ///
    /// Called when the tab loses selection, not when it is suspended: by suspension
    /// time the web view has usually been detached, and `takeSnapshot` on a
    /// windowless web view returns nothing. ``Tab/apply(_:)`` keeps an existing
    /// snapshot when a later capture yields nil, so this is the one that counts.
    func captureSnapshotForSuspension() async {
        guard let webView, !isDiscarded, let data = await captureSnapshot(of: webView) else {
            return
        }
        guard !isDiscarded else { return }
        record.snapshotData = data
    }

    private func captureSnapshot(of webView: WKWebView) async -> Data? {
        // A web view that has never been in a window has no drawable content, and
        // asking anyway logs a WebKit error for no benefit.
        guard webView.window != nil, webView.bounds.width > 1 else { return nil }

        let configuration = WKSnapshotConfiguration()
        // Downscaled: this is a placeholder shown for a few hundred milliseconds,
        // and thirty full-resolution page images is real disk.
        configuration.snapshotWidth = NSNumber(value: 640)
        configuration.afterScreenUpdates = false

        do {
            return try await webView.takeSnapshot(configuration: configuration)
                .jpegData(quality: 0.55)
        } catch {
            trace("tabs", "snapshot \(shortID) failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func currentScrollY() async -> Double? {
        guard let webView else { return nil }
        // Read in Zentic's content world: in the page world a site could shadow
        // `scrollY`, and this value decides where the user lands on restore.
        let value = try? await webView.callAsyncJavaScript(
            "return window.scrollY;",
            contentWorld: ReaderBridge.contentWorld
        )
        return value as? Double
    }

    private func startScrollPolling() {
        scrollPoll?.cancel()
        scrollPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.isResident, !self.isDiscarded else { return }
                if let offset = await self.currentScrollY() {
                    self.record.scrollY = offset
                }
            }
        }
    }

    private func stopScrollPolling() {
        scrollPoll?.cancel()
        scrollPoll = nil
    }

    // MARK: - Navigation

    func load(_ url: URL) {
        guard !isDiscarded else { return }
        record.urlString = url.absoluteString
        if let webView {
            webView.load(URLRequest(url: url))
        } else {
            // Not resident: the record is enough, realize() will pick it up.
            record.interactionState = nil
        }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    func reload() {
        guard let webView else { return }
        if webView.url == nil, let url = record.url {
            webView.load(URLRequest(url: url))
        } else {
            webView.reload()
        }
    }

    func stopLoading() { webView?.stopLoading() }

    /// ⌘\ — swap between Zentic's rendering and the site's own.
    ///
    /// Sent as a command rather than a reload: the original DOM is only ever
    /// hidden, never destroyed, so the toggle is instant. The bridge configuration
    /// is updated too, so the choice survives the next navigation.
    func toggleReaderMode() {
        setReaderMode(readerMode == .restructured ? .original : .restructured)
    }

    /// Switch to a specific mode.
    ///
    /// The segmented control asks for a *state*, not a flip. Routing it through a
    /// toggle meant that any disagreement between the control and the tab — a ⌘\
    /// while the toolbar was stale, a tab switched underneath — sent the page the
    /// opposite way from the segment the user pressed.
    func setReaderMode(_ mode: ReaderMode) {
        guard mode != readerMode else { return }
        readerMode = mode
        guard let bridge, let webView else { return }

        var configuration = bridge.currentConfiguration
        configuration.mode = readerMode
        bridge.updateConfiguration(configuration)

        Task {
            do {
                try await bridge.send(.setMode(readerMode), to: webView)
                trace("bridge", "tab \(shortID) setMode \(readerMode.rawValue)")
            } catch {
                // Expected on a PDF, an error page, or anything with no bundle.
                trace("bridge", "tab \(shortID) setMode failed: \(error)")
            }
        }
    }

    // MARK: - Design

    /// Push a design to the page. Presentation only: no re-extraction, no reload.
    func applyDesign(_ theme: ReaderTheme) {
        guard let bridge, let webView else { return }
        Task {
            try? await bridge.send(.applyTheme(theme), to: webView)
            trace("redesign", "tab \(shortID) applied \(theme.name)")
        }
    }

    /// Replace the reading view with a model-authored layout of this page.
    ///
    /// Not persisted the way a theme is: a generated document is this page's
    /// markup, and the next article on the same site has different content, so
    /// there is nothing to reuse. The prompt is what gets saved.
    func applyGeneratedDocument(_ document: GeneratedDocument) {
        guard let bridge, let webView else { return }
        Task {
            try? await bridge.send(.applyDocument(document), to: webView)
            trace("redesign", "tab \(shortID) applied generated document")
        }
    }

    /// The page as extracted, for handing to a model that will lay it out.
    var currentExtraction: ExtractionResult? { extraction }

    /// Reapply this origin's saved design once the page is rendered.
    ///
    /// Runs on every reveal rather than once per tab, because an SPA navigation
    /// re-renders without a new web view and would otherwise drop back to the
    /// default design mid-session.
    private func applySavedDesign() {
        guard didRestructure else { return }
        let origin = url?.host()
        Task { @MainActor in
            guard let theme = await RedesignController.shared.savedDesign(for: origin) else {
                return
            }
            applyDesign(theme)
        }
    }

    // MARK: - Blocking

    /// Swap this tab's rule lists to match the origin's shield, then reload.
    ///
    /// The reload is not optional: `WKContentRuleList`s are applied at request
    /// time, so a page that already loaded its trackers keeps them until it is
    /// fetched again — and a shield toggle that appears to do nothing is worse
    /// than no toggle.
    func applyShield() {
        guard let webView else { return }
        Blocking.reapply(to: webView.configuration.userContentController, origin: url?.host())
        reload()
    }

    // MARK: - Lenses

    /// Resolve this tab's lens set for a URL it is about to load.
    ///
    /// Called from the navigation policy decision, which is `async` and therefore the
    /// last point at which the bootstrap script can still be changed before the new
    /// document exists. One actor hop per navigation buys a page whose lenses are
    /// live at `document-start`; delivering them as a command instead would cost a
    /// visible reflow on every visit.
    func prepareLenses(for url: URL) async {
        lensPlanSequence += 1
        let sequence = lensPlanSequence

        let all = await LensController.shared.allLenses(for: url)
        let plan = LensPlan(
            url: url,
            lenses: await LensController.shared.lenses(for: url),
            siteLensCount: all.count,
            enabledLensCount: all.count { $0.isEnabled }
        )
        // Two awaits, and the user can have clicked something else across either of
        // them. A policy decision for a URL this tab has since abandoned must not
        // rewrite the bootstrap the live navigation is about to boot from, so the
        // last decision to *start* is the one that gets to arm the page.
        guard sequence == lensPlanSequence else { return }
        stagedPlan = plan

        guard let bridge else { return }
        var configuration = bridge.currentConfiguration
        configuration.lenses = plan.lenses
        bridge.updateConfiguration(configuration)
        if !plan.lenses.isEmpty {
            trace("lens", "tab \(shortID) armed \(plan.lenses.count) lenses for \(url.host() ?? "?")")
        }
    }

    /// Adopt the staged set now that a document has actually committed.
    ///
    /// This is where the chrome starts describing the new page: not before, because
    /// a navigation that never commits leaves the previous page on screen, and a
    /// badge counting a lens set that page never ran is a fabricated number.
    private func commitStagedLenses(for url: URL) {
        let plan = stagedPlan
        stagedPlan = nil
        guard let plan, plan.describes(url) else {
            // Committed somewhere the staged set was not resolved for — a redirect,
            // or a policy decision that lost a race. The set the page actually
            // booted with is unknown, so it is re-resolved rather than assumed.
            Task { await refreshLenses() }
            return
        }
        appliedLenses = plan.lenses
        siteLensCount = plan.siteLensCount
        enabledLensCount = plan.enabledLensCount
        lensURL = url
        // The reports belong to the document being replaced.
        lensReports = [:]
        catalog = nil
    }

    /// Re-resolve and push the set to the page that is already loaded.
    ///
    /// The live half of the same job: a lens toggled in the popover, a draft just
    /// saved, or a same-document navigation to a path a different lens covers. The
    /// bootstrap is updated too, so the next load starts from the same set rather
    /// than briefly reverting to the one this document booted with.
    /// One at a time, in the order they were asked for.
    ///
    /// Every save fans out through `observeChanges` into a refresh for each resident
    /// tab, and the call site that made the change usually awaits one of its own on
    /// top. Both ran at once, both read `appliedLenses` before either had written
    /// it, both decided the set had changed, and both sent `applyLenses` — so a
    /// single Save cost the page two full undo-and-re-run passes and posted two
    /// reports. Chaining onto the previous run makes a second request a no-op by
    /// construction: by the time it resolves, the first has already written what it
    /// would have found.
    func refreshLenses() async {
        let previous = lensRefresh
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.runRefreshLenses()
        }
        lensRefresh = task
        await task.value
    }

    private func runRefreshLenses() async {
        guard let url else { return }
        let all = await LensController.shared.allLenses(for: url)
        let plan = LensPlan(
            url: url,
            lenses: await LensController.shared.lenses(for: url),
            siteLensCount: all.count,
            enabledLensCount: all.count { $0.isEnabled }
        )
        // The page can have moved across either await — a router does it in a
        // frame. Resuming anyway overwrote the applied set with one resolved for a
        // URL nobody is on and sent `applyLenses` for the wrong page, which is a
        // real effect, not just a wrong number.
        guard plan.describes(self.url) else { return }

        if let bridge {
            var configuration = bridge.currentConfiguration
            configuration.lenses = plan.lenses
            bridge.updateConfiguration(configuration)
        }

        // Reports are dropped whenever the *page* moved, not only when the set
        // changed. A same-document navigation to a route the same lenses cover used
        // to leave them in place, and the engine's coalesced report for the route
        // the user just left then landed and was counted against the new one.
        if lensURL != url { lensReports = [:] }
        lensURL = url
        siteLensCount = plan.siteLensCount
        enabledLensCount = plan.enabledLensCount

        guard plan.lenses != appliedLenses else {
            delegate?.tabControllerDidChangeChrome(self)
            return
        }
        appliedLenses = plan.lenses
        // Every stored result described the previous set. Dropping them means the
        // badge shows nothing until the page reports again, which is the honest
        // state — a count for ops that are no longer applied is a fabrication.
        lensReports = [:]
        delegate?.tabControllerDidChangeChrome(self)

        guard let bridge, let webView else { return }
        do {
            try await bridge.send(.applyLenses(plan.lenses), to: webView)
            trace("lens", "tab \(shortID) applied \(plan.lenses.count) lenses")
        } catch {
            // Expected on a PDF, an error page, or anything with no bundle.
            trace("lens", "tab \(shortID) applyLenses failed: \(error)")
        }
    }

    /// A same-document navigation moved the page under the lens set.
    private func lensesFollowedTheURL() {
        guard let url = webView?.url, url != lensURL else { return }
        // Dropped here rather than waiting for the refresh to resume: the reports
        // stop describing what is on screen the moment the route changes, and the
        // refresh is two actor hops away.
        lensReports = [:]
        delegate?.tabControllerDidChangeChrome(self)
        Task { await refreshLenses() }
    }

    /// ⌥⌘L — show or hide the in-page editor.
    ///
    /// The editor is in the page rather than in the chrome because picking a region
    /// means pointing at it, and the only surface that knows where anything is is
    /// the page itself. It runs in the `zentic` content world, so page script can
    /// neither see it nor patch it.
    ///
    /// Opening and closing are asymmetric, which is why there is no `toggle` here:
    /// closing is unconditional, and opening has to be refused or renegotiated when
    /// the page on screen is the reader's own render. That decision needs an alert,
    /// so it belongs to the view controller.
    ///
    /// - Parameter onUnavailable: Run when the page could not be reached at all — a
    ///   PDF, an error page, anything with no bundle in it. Without it the user
    ///   presses ⌥⌘L and nothing whatsoever happens, which is indistinguishable from
    ///   a broken shortcut. A throw from the bridge is not the only way to get there
    ///   — see ``lensModeUnavailable`` — so opening also waits to be told it worked.
    func setLensMode(
        _ editing: Bool,
        lensID: String? = nil,
        onUnavailable: (@MainActor () -> Void)? = nil
    ) {
        guard let bridge, let webView else {
            onUnavailable?()
            return
        }
        lensModeRequest += 1
        let request = lensModeRequest
        lensModeUnavailable = editing ? onUnavailable : nil
        Task {
            // The editor is not in the document-start bundle — it is a third of a
            // megabyte that cannot run until this keystroke, so every page that
            // never sees one is spared parsing it. It goes in now, into the same
            // isolated world, and the `await` is the ordering: the command below
            // cannot reach a page that has not finished evaluating it.
            if editing {
                do {
                    try await bridge.deliverLensEditor(to: webView)
                } catch {
                    trace("lens", "tab \(shortID) editor delivery failed: \(error)")
                    answerLensMode(request, with: "the editor could not be sent to the page")
                    return
                }
            }
            do {
                let command: ReaderCommand =
                    editing
                    ? .enterLensMode(lensID.map { LensEditRequest(editing: $0) })
                    : .exitLensMode
                try await bridge.send(command, to: webView)
            } catch {
                trace("lens", "tab \(shortID) lens mode failed: \(error)")
                answerLensMode(request, with: "the page could not be reached")
                return
            }
            guard editing else { return }
            // Long enough for a page that has a bundle to have mounted the overlay
            // and posted back. A page that has not answered by the time we would
            // have given up waiting for it to settle has nothing in it to answer.
            try? await Task.sleep(for: Budget.settleCeiling)
            answerLensMode(request, with: "the editor never opened")
        }
    }

    /// Give up on one ⌥⌘L and tell the user, once.
    ///
    /// Keyed on the request so a second press, or an editor the user has already
    /// opened and closed, cannot be reported as a failure of this one.
    private func answerLensMode(_ request: Int, with reason: String) {
        guard request == lensModeRequest, let answer = lensModeUnavailable else { return }
        lensModeUnavailable = nil
        trace("lens", "tab \(shortID) lens mode unavailable: \(reason)")
        answer()
    }

    /// Open the editor on an existing lens.
    ///
    /// Its **identity**, not its ops. Sending the ops as a proposal as well meant the
    /// editor received the same lens twice — once adopted as chips by entering lens
    /// mode, once again to confirm — so Apply re-minted the colliding op ids, every
    /// op appeared in the draft twice, and Save then wrote a duplicate lens beside
    /// the one being edited with both copies enabled. The editor already has the
    /// applied set; all it was missing was which one of them the user pressed Edit
    /// on, and which id the draft has to carry back so the save replaces rather than
    /// inserts.
    func edit(lens: Lens, onUnavailable: (@MainActor () -> Void)? = nil) {
        setLensMode(true, lensID: lens.id, onUnavailable: onUnavailable)
    }

    /// Ask the page for a fresh region catalog and wait for it.
    ///
    /// Re-fitting needs the page *as it is now*, not as it was when the lens was
    /// written — that difference is the whole point. Returns the last catalog we
    /// were sent if the page does not answer, and nil if there has never been one.
    ///
    /// The wait is ``Budget/settleCeiling``: the catalog is built synchronously from
    /// the live DOM, so a page that has not answered within the time we would have
    /// waited for it to settle has no bundle in it — a PDF, an error page — and
    /// waiting longer only delays telling the user so.
    func freshCatalog() async -> RegionCatalog? {
        guard let bridge, let webView else { return catalog }
        do {
            try await bridge.send(.requestRegions, to: webView)
        } catch {
            trace("lens", "tab \(shortID) requestRegions failed: \(error)")
            return catalog
        }
        return await withCheckedContinuation { continuation in
            let request = catalogRequest + 1
            catalogRequest = request
            catalogWaiters.append(continuation)
            Task { @MainActor in
                try? await Task.sleep(for: Budget.settleCeiling)
                // Only this request's own timeout may give up on it. Draining
                // unconditionally meant a second call inside the first's window was
                // resumed early by the *first* timeout, handing back the catalog
                // from before the page it was asked about — a re-fit against a
                // stale view of the page is exactly the failure re-fit exists to
                // repair.
                guard catalogRequest == request else { return }
                drainCatalogWaiters(with: catalog)
            }
        }
    }

    /// Resume every pending catalog request exactly once.
    private func drainCatalogWaiters(with catalog: RegionCatalog?) {
        let waiters = catalogWaiters
        catalogWaiters = []
        for waiter in waiters { waiter.resume(returning: catalog) }
    }

    // MARK: - Rewrite

    /// Whether this page is one where rewriting needs an explicit confirm.
    ///
    /// News, medical, legal and financial pages are where a re-voiced sentence
    /// stops being a style change and becomes a claim about what someone said.
    var needsFidelityConfirmation: Bool { extraction?.isFidelitySensitive ?? false }

    var canRewrite: Bool {
        guard let extraction, didRestructure else { return false }
        return readerMode == .restructured && !extraction.rewritableSections.isEmpty
    }

    /// Re-voice the page's prose. Layer 3, and the only layer that calls a model.
    ///
    /// Never automatic: this runs on an explicit press, per invariant 6. The
    /// original DOM is untouched throughout — ``discardRewrite()`` and ⌘\ both
    /// remain instant — and only sections whose kind is rewritable are ever sent,
    /// which the provider re-checks rather than trusting us.
    func rewrite(tone: Tone, length: LengthPreference, readingLevel: ReadingLevel?) {
        guard let extraction, let bridge, let webView else { return }
        let sections = extraction.rewritableSections
        guard !sections.isEmpty else { return }

        rewriteTask?.cancel()
        rewriteState = .running(done: 0, total: sections.count)
        delegate?.tabControllerDidChangeChrome(self)

        let request = RewriteRequest(
            sections: sections,
            tone: tone,
            length: length,
            readingLevel: readingLevel,
            context: RewriteContext(
                title: extraction.title,
                siteName: extraction.siteName,
                lang: extraction.lang
            )
        )

        rewriteTask = Task { [weak self] in
            guard let self else { return }
            let provider = FoundationModelsProvider()

            switch await provider.availability() {
            case .available:
                break
            case .unavailable(let reason), .ineligible(let reason):
                rewriteState = .failed(reason)
                delegate?.tabControllerDidChangeChrome(self)
                trace("rewrite", "tab \(shortID) unavailable: \(reason)")
                return
            }

            var done = 0
            do {
                for try await event in provider.rewrite(request) {
                    try Task.checkCancellation()
                    switch event {
                    case .patch(let patch):
                        try? await bridge.send(.applyRewrite(patch), to: webView)
                        done += 1
                        rewriteState = .running(done: done, total: sections.count)
                        delegate?.tabControllerDidChangeChrome(self)
                    case .skipped(let sectionID, let reason):
                        done += 1
                        trace("rewrite", "tab \(shortID) skipped \(sectionID): \(reason)")
                    case .finished:
                        break
                    }
                }
                rewriteState = done > 0 ? .shown : .failed("Nothing was rewritten.")
            } catch is CancellationError {
                return
            } catch {
                // Partial output stays on screen rather than snapping back: the
                // user asked for this and half of it is still useful, and the
                // badge tells them what they are looking at.
                rewriteState = done > 0 ? .shown : .failed("\(error)")
            }
            delegate?.tabControllerDidChangeChrome(self)
            trace("rewrite", "tab \(shortID) \(rewriteState)")
        }
    }

    /// Put the extracted text back. Instant — the rewrite only ever replaced nodes
    /// in our shadow DOM, and the renderer kept what it replaced.
    func discardRewrite() {
        rewriteTask?.cancel()
        rewriteTask = nil
        guard rewriteState != .none else { return }
        rewriteState = .none
        delegate?.tabControllerDidChangeChrome(self)
        guard let bridge, let webView else { return }
        Task {
            try? await bridge.send(.discardRewrite, to: webView)
        }
    }

    /// Navigation invalidates everything the rewrite layer knows.
    private func resetReaderStateForNavigation() {
        rewriteTask?.cancel()
        rewriteTask = nil
        rewriteState = .none
        extraction = nil
        didRestructure = false
        // Reports and the catalog describe the document being replaced. The lens
        // *set* is not cleared: it was resolved for the URL being navigated to, and
        // is already in the bootstrap script for the page now loading.
        lensReports = [:]
        catalog = nil
        isLensEditing = false
        // A ⌥⌘L outstanding against the document being replaced has no answer worth
        // waiting for: whatever the new page does, it is not that press.
        lensModeRequest += 1
        lensModeUnavailable = nil
    }

    // MARK: - Find in page

    @discardableResult
    func find(_ query: String, forwards: Bool) async -> Bool {
        guard let webView, !query.isEmpty else { return false }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forwards
        configuration.wraps = true
        configuration.caseSensitive = false
        // `find` is throwing only because it can be cancelled; a failed search is
        // reported as `matchFound == false`, not as an error.
        return (try? await webView.find(query, configuration: configuration))?.matchFound ?? false
    }

    // MARK: - Chrome updates

    private var shortID: String { String(id.uuidString.prefix(4)) }

    private func recordNavigation() {
        guard let webView, let url = webView.url, !isDiscarded else { return }
        record.urlString = url.absoluteString
        record.canGoBack = webView.canGoBack
        record.canGoForward = webView.canGoForward
        if let title = webView.title, !title.isEmpty {
            record.title = title
        }
        delegate?.tabControllerDidChangeChrome(self)

        guard url != lastCommittedURL else { return }
        lastCommittedURL = url
        delegate?.tabController(self, didCommit: url, title: record.title)
        Task { await loadFavicon(for: url) }
    }

    private func loadFavicon(for pageURL: URL) async {
        guard let webView, !isDiscarded else { return }
        // Ask the page for its declared icon before falling back to /favicon.ico:
        // plenty of sites have no root icon at all and would otherwise show blank.
        let declared = try? await webView.callAsyncJavaScript(
            """
            const link = document.querySelector(
                "link[rel~='icon'], link[rel='shortcut icon'], link[rel='apple-touch-icon']"
            );
            return link ? link.href : null;
            """,
            contentWorld: ReaderBridge.contentWorld
        ) as? String

        guard
            let data = await faviconService.iconData(
                pageURL: pageURL,
                declared: declared.flatMap(URL.init(string:))
            ),
            !isDiscarded
        else { return }

        record.faviconData = data
        delegate?.tabControllerDidChangeChrome(self)
    }
}

// MARK: - Navigation delegate

extension TabController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        // ⌘-click opens a new tab, matching every other browser. Checked here
        // rather than in a click handler so it works for any link-activated
        // navigation, including ones synthesised by the page.
        if navigationAction.navigationType == .linkActivated,
            navigationAction.modifierFlags.contains(.command),
            let url = navigationAction.request.url
        {
            delegate?.tabController(self, wantsNewTabFor: url)
            return (.cancel, preferences)
        }

        if navigationAction.shouldPerformDownload {
            return (.download, preferences)
        }

        // Last chance to change the bootstrap script before the new document exists.
        // Main frame only: a lens describes the page, and an iframe is somebody
        // else's page inside it.
        if navigationAction.targetFrame?.isMainFrame ?? false,
            let url = navigationAction.request.url
        {
            await prepareLenses(for: url)
        }
        return (.allow, preferences)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // A new page means the extraction and any rewrite belong to a document that
        // is no longer on screen.
        resetReaderStateForNavigation()
        delegate?.tabControllerDidChangeChrome(self)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A document exists now, which is the first moment the lens set resolved at
        // policy time is true of anything on screen.
        if let url = webView.url { commitStagedLenses(for: url) }
        recordNavigation()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        recordNavigation()
        delegate?.tabControllerDidFinishLoad(self)

        if let offset = pendingScrollY {
            pendingScrollY = nil
            Task {
                _ = try? await webView.callAsyncJavaScript(
                    "window.scrollTo(0, offset);",
                    arguments: ["offset": offset],
                    contentWorld: ReaderBridge.contentWorld
                )
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        trace("nav", "tab \(shortID) failed: \(error.localizedDescription)")
        stagedPlan = nil
        delegate?.tabControllerDidChangeChrome(self)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        let code = (error as NSError).code
        // -999 is "cancelled", which every ⌘-click and redirect produces. Not a
        // failure worth surfacing.
        if code != NSURLErrorCancelled {
            trace("nav", "tab \(shortID) load failed: \(error.localizedDescription)")
        }
        // The page that never arrived does not get to describe the one still on
        // screen. Its set was armed in the bootstrap, which costs nothing — the
        // bootstrap only runs for a document that loads.
        stagedPlan = nil
        delegate?.tabControllerDidChangeChrome(self)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The web content process died — usually the OS reclaiming memory. Reload
        // rather than leaving a permanently blank tab.
        trace("tabs", "tab \(shortID) content process terminated; reloading")
        reload()
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        // A download is not a page, so nothing about it describes what is on screen.
        stagedPlan = nil
        delegate?.tabController(self, didStart: download)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        stagedPlan = nil
        delegate?.tabController(self, didStart: download)
    }
}

// MARK: - UI delegate

extension TabController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Returning nil and opening our own tab, rather than adopting the supplied
        // configuration: that configuration's content controller already carries the
        // opener's scripts, and adding a second `zentic` message handler to it
        // raises. A tab must own its bridge, so it must own its configuration.
        //
        // The cost is that a `window.open()` with no URL — a popup the page intends
        // to write into via `document.write` — is dropped rather than shown.
        if let url = navigationAction.request.url {
            delegate?.tabController(self, wantsNewTabFor: url)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        return await panel.begin() == .OK ? panel.urls : nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "Page"
        alert.informativeText = message
        alert.runModal()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "Page"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Reader bridge delegate

extension TabController: ReaderBridgeDelegate {
    func readerBridge(_ bridge: ReaderBridge, didReceive event: ReaderEvent) {
        switch event {
        case .ready(let payload):
            trace("bridge", "\(shortID) ready · bundle \(payload.bundleVersion)")
        case .revealed(let payload):
            // `.userRequested` is this tab's own ⌘\ echoing back, not a verdict on
            // whether the page can be transformed. Treating it as one meant the
            // first switch to Original set `didRestructure = false`, which disabled
            // the control that had just been used — one click and the toggle was
            // dead. Only a page-load outcome may change this.
            if payload.reason != .userRequested {
                didRestructure = payload.reason == .rendered
                applySavedDesign()
            }
            trace("bridge", "\(shortID) revealed · \(payload.reason.rawValue) · \(payload.elapsedMs)ms")
            delegate?.tabControllerDidChangeChrome(self)
        case .extracted(let result):
            extraction = result
            trace("bridge", "\(shortID) extracted · \(result.archetype.rawValue) · \(result.wordCount)w")
            delegate?.tabControllerDidChangeChrome(self)
        case .needsRecipe(let skeleton):
            trace("bridge", "\(shortID) needsRecipe · \(skeleton.nodes.count) nodes")
        case .failed(let failure):
            trace("bridge", "\(shortID) FAILED at \(failure.stage): \(failure.message)")
            // A mount that threw is the one failure a user is standing over waiting
            // for. It is answered now rather than at the end of the timeout, and it
            // is the only stage that answers: `lens.pass` and the rest are about the
            // page, not about the shortcut somebody just pressed.
            if failure.stage == "lens.enterMode" {
                answerLensMode(lensModeRequest, with: failure.message)
            }
        case .lensReport(let reports):
            // The only source of the numbers on the lens button. Stored per tab so
            // switching tabs shows each page's own result, and persisted so a lens
            // that drifted is explicable on the next launch before the page it
            // drifted on has loaded.
            //
            // Reports for another page are dropped. They are real — the engine
            // coalesces observer results and re-posts a full report on a timer, so
            // on a single-page app one for the route the user just left routinely
            // arrives after the router has moved — and counting one is inventing a
            // number about the page on screen, which invariant 8 forbids as
            // squarely as making one up.
            let describing = reports.filter { $0.describes(webView?.url) }
            for report in describing { lensReports[report.lensID] = report }
            let missed = describing.reduce(0) { $0 + $1.missedCount }
            let stale = reports.count - describing.count
            trace(
                "bridge",
                "\(shortID) lensReport · \(describing.count) lenses · \(missed) missed"
                    + (stale > 0 ? " · \(stale) for another page, dropped" : "")
            )
            delegate?.tabControllerDidChangeChrome(self)
            // Persisted even when it does not describe the page in front of the
            // user: it describes the page the lens *ran* on, which is exactly what
            // `lastReport` is for.
            Task {
                for report in reports { await LensController.shared.record(report) }
            }
        case .lensRegions(let catalog):
            self.catalog = catalog
            drainCatalogWaiters(with: catalog)
            trace("bridge", "\(shortID) lensRegions · \(catalog.candidates.count) candidates")
        case .lensPrompt(let request):
            // Never prompt-straight-to-effect: the answer goes back as a *proposal*,
            // which the editor highlights for confirmation before anything moves.
            trace("bridge", "\(shortID) lensPrompt · \(request.selectedRegionIDs.count) selected")
            catalog = request.catalog
            Task { await authorLens(for: request) }
        case .lensDraft(let lens):
            trace("bridge", "\(shortID) lensDraft · \(lens.name) · \(lens.ops.count) ops")
            Task { await saveLensDraft(lens) }
        case .lensModeChanged(let isEditing):
            isLensEditing = isEditing
            // The page answered, so there is nothing to apologise for — including
            // when it answers `false`, which is the editor closing itself.
            lensModeUnavailable = nil
            trace("bridge", "\(shortID) lensMode · \(isEditing ? "on" : "off")")
            delegate?.tabControllerDidChangeChrome(self)
        }
    }

    /// Hand a prompt to the model and send the ops back to the editor.
    ///
    /// The answer goes back on every path, including failure — a proposal with no
    /// ops, carrying the reason. The editor has disabled Ask and put the prompt
    /// behind an "asking…" state, and nothing else on the wire would ever let it out
    /// of that: a failed model call used to leave the overlay stuck there for the
    /// life of the page.
    private func authorLens(for request: LensPromptRequest) async {
        let proposal = await LensController.shared.generate(
            prompt: request.text,
            selectedRegionIDs: request.selectedRegionIDs,
            catalog: request.catalog,
            origin: url?.host(),
            over: webView?.window
        )
        guard let bridge, let webView else { return }
        do {
            try await bridge.send(.proposeOps(proposal), to: webView)
        } catch {
            trace("lens", "tab \(shortID) proposeOps failed: \(error)")
        }
    }

    /// Persist what the editor saved, then put it on the page.
    ///
    /// Re-applying rather than trusting the editor's own preview: the stored lens is
    /// what every future visit replays, so the page the user is looking at after
    /// pressing Save should be the page the lens actually produces.
    /// Every selector in the draft is measured against a catalog asked of this
    /// page, because with the CSS subject parser gone that catalog is the whole
    /// breadth defence on this path — see ``LensController/save(draft:for:against:over:)``.
    /// Asked fresh rather than reusing whatever the last `lensPrompt` carried: a
    /// draft may be authored entirely by pointing, in which case the app has never
    /// been shown one, and `freshCatalog()` falls back to the last one anyway.
    private func saveLensDraft(_ draft: Lens) async {
        guard let url else { return }
        let catalog = await freshCatalog()
        // Saving posts `didChangeLenses`, which refreshes every resident tab
        // including this one. A second await here was a second concurrent pass over
        // the same page for one Save.
        await LensController.shared.save(
            draft: draft,
            for: url,
            against: catalog,
            over: webView?.window
        )
    }

    func readerBridge(_ bridge: ReaderBridge, didFailWith error: any Error) {
        trace("bridge", "\(shortID) error: \(error)")
    }
}


/// A `WKWebView` that counts itself.
///
/// Suspension's whole claim is that a web view goes away when its tab is evicted.
/// "The reference was set to nil" is not that claim — an object with another owner
/// stays alive and keeps its memory. This makes deallocation observable.
final class TrackedWebView: WKWebView {
    nonisolated(unsafe) static var alive = 0
    nonisolated(unsafe) static var created = 0

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        Self.alive += 1
        Self.created += 1
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { Self.alive -= 1 }
}
