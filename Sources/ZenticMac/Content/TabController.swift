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
    /// Extraction reached a verdict on a page. Drives the per-origin memory of
    /// whether pages here are worth hiding on arrival.
    func tabController(
        _ controller: TabController,
        didExtract result: ExtractionResult,
        from url: URL
    )
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

    /// Title and URL are observed rather than sampled.
    ///
    /// `didCommit` and `didFinish` are the wrong moments to read `title`: WebKit
    /// parses `<title>` on its own schedule, and a single-page app rewrites
    /// `document.title` well after the navigation that triggered it — often after
    /// the load has finished, sometimes without a load at all. Sampling at those
    /// two points leaves the previous page's title in the sidebar, which is why
    /// the favicon could refresh while the title did not: the favicon already had
    /// an async path of its own.
    private var titleObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?

    /// Set once the tab is closed. Every write to ``record`` is gated on it: the
    /// store deletes the record synchronously while snapshot capture and suspension
    /// are in flight, and SwiftData traps on any access to a deleted object.
    private var isDiscarded = false

    /// Samples the scroll offset while resident.
    ///
    /// Polling rather than a JS scroll listener: the offset is only ever needed at
    /// suspension time, so a 2s sample costs nothing, whereas bridging every scroll
    /// frame is a measurable tax on every page.
    private var scrollPoll: Task<Void, Never>?

    /// Origins whose pages this tab should leave visible on arrival.
    ///
    /// A closure rather than a stored set, because the answer changes as the user
    /// browses and a tab outlives many navigations. It is read at ``realize()`` and
    /// baked into the bootstrap script, which belongs to the web view's
    /// configuration and cannot be changed afterwards — so reading it late is the
    /// only way a tab suspended before an origin was learned picks the answer up
    /// when it comes back.
    private let instantOrigins: () -> Set<String>

    /// The level a page from a given origin should load at.
    ///
    /// A closure for the same reason as ``instantOrigins`` — it is resolved at
    /// ``realize()`` and baked into the bootstrap, so it has to be read late — and
    /// it takes the origin because a tab outlives navigations between sites.
    private let resolveLevel: (String?) -> LevelResolution

    /// The level this tab's current document was loaded under, which is what a
    /// change has to be compared against to know whether a reload is owed.
    private(set) var level: PageLevel = .reader
    /// Where this page would sit with no override. Cached rather than derived on
    /// demand: the toolbar reads it on every title change, favicon and reveal, and
    /// resolving it touches the store.
    private(set) var automaticLevel: PageLevel = .reader
    /// The origin the current level and rule lists were resolved for, so a
    /// same-site navigation costs nothing and a cross-site one is noticed.
    private var attachedOrigin: String?

    init(
        record: Tab,
        faviconService: FaviconService,
        instantOrigins: @escaping () -> Set<String> = { [] },
        resolveLevel: @escaping (String?) -> LevelResolution = {
            _ in LevelResolution(level: .reader, automatic: .reader)
        }
    ) {
        self.id = record.id
        self.record = record
        self.faviconService = faviconService
        self.instantOrigins = instantOrigins
        self.resolveLevel = resolveLevel
        super.init()
    }

    /// Re-read this origin's level from the store.
    ///
    /// Called when the memory behind it actually changes — a new extraction verdict,
    /// a preference edit — rather than on every chrome update.
    func refreshLevelResolution() {
        let resolved = resolveLevel(record.url?.zenticOrigin)
        automaticLevel = resolved.automatic
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

        // Resolved before anything is built, because it decides both which rule
        // lists attach and what the bootstrap script says — and the bootstrap
        // belongs to the configuration, which cannot be changed once the web view
        // exists.
        attachedOrigin = record.url?.zenticOrigin
        let resolved = resolveLevel(attachedOrigin)
        level = resolved.level
        automaticLevel = resolved.automatic

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
                    level: level,
                    mode: readerMode,
                    instantOrigins: instantOrigins(),
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
        //
        // The shield is a projection of the level, not a second setting looked up
        // separately — two controls that can disagree are two controls that will.
        Blocking.attach(to: configuration.userContentController, shield: level.shield)

        let webView = TrackedWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        // Lets Safari's Web Inspector attach, which is how the in-page bundle is
        // debugged. Debug builds only — this is a remote-control surface.
        #if DEBUG
        webView.isInspectable = true
        #endif
        self.webView = webView

        // Both fire on the main thread: WebKit updates these properties from the
        // main run loop, which is the same isolation this class already lives on.
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.recordTitle() }
        }
        // Covers the navigation a `pushState` route change makes without ever
        // reaching `didCommit`.
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.recordNavigation() }
        }

        restoreSession(into: webView)
        startScrollPolling()
        trace("tabs", "realize \(shortID) \(level.rawValue) \(record.urlString)")
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
        guard let webView else { return }
        // Alongside the delegates, and for the same reason: an observation that
        // outlived the web view would report the teardown itself as a navigation.
        titleObservation?.invalidate()
        titleObservation = nil
        urlObservation?.invalidate()
        urlObservation = nil
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

    /// Move this tab to a level.
    ///
    /// Split by axis, because the two halves are genuinely different operations.
    /// Everything above the strip layer is a message to a page that is already
    /// loaded. The strip layer is not: WebKit compiles `css-display-none` into a
    /// document when it loads and never revisits it, and a request already on the
    /// wire cannot be recalled — so a blocking change describes the *next*
    /// document, and the only honest way to apply it now is to fetch one.
    func setLevel(_ level: PageLevel) {
        let previous = self.level
        guard level != previous else { return }
        self.level = level

        // The bootstrap script belongs to the configuration, so this governs the
        // next navigation whether or not we reload for it now.
        if let bridge {
            // Mutated, not rebuilt. Reconstructing dropped every budget back to its
            // default — harmless only for as long as nothing ever carries a
            // non-default one, which is not a property worth relying on.
            var configuration = bridge.currentConfiguration
            configuration.level = level
            configuration.mode = level.readerMode
            bridge.updateConfiguration(configuration)
        }

        if PageLevel.requiresReload(from: previous, to: level) {
            // Re-attach before reloading, or the new document loads under the old
            // lists and the change appears not to have worked.
            if let controller = webView?.configuration.userContentController {
                Task {
                    await Blocking.reattach(to: controller, shield: level.shield)
                    reload()
                }
            }
            return
        }

        readerMode = level.readerMode
        guard let bridge, let webView else { return }
        // `setLevel`, not `setMode`: the bundle caches what it is permitted to do
        // when the page loads, so a mode change alone would be obeyed by a page
        // that had already decided it may not render.
        Task {
            do {
                try await bridge.send(.setLevel(level), to: webView)
                trace("bridge", "tab \(shortID) setLevel \(level.rawValue)")
            } catch {
                trace("bridge", "tab \(shortID) setLevel failed: \(error)")
            }
        }
    }

    /// ⌘\ — swap between Zentic's rendering and the site's own.
    ///
    /// Sent as a command rather than a reload: the original DOM is only ever
    /// hidden, never destroyed, so the toggle is instant. The bridge configuration
    /// is updated too, so the choice survives the next navigation.
    func toggleReaderMode() {
        // Nothing to peek at below Reader: the site's own page is already what is on
        // screen. Without this guard ⌘\ would write `.restructured` into a
        // configuration whose level forbids it — the clamp catches that now, but a
        // keystroke that silently does nothing is better than one that half-works.
        guard level >= .reader else { return }
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

    /// A new title arrived for the page already on screen.
    private func recordTitle() {
        guard
            let webView, !isDiscarded,
            let title = webView.title, !title.isEmpty,
            title != record.title
        else { return }
        record.title = title
        delegate?.tabControllerDidChangeChrome(self)
    }

    private func recordNavigation() {
        guard let webView, let url = webView.url, !isDiscarded else { return }
        let isNewPage = url != lastCommittedURL
        record.urlString = url.absoluteString
        record.canGoBack = webView.canGoBack
        record.canGoForward = webView.canGoForward

        if let title = webView.title, !title.isEmpty {
            record.title = title
        } else if isNewPage {
            // Nothing to show yet, and the field still holds the *previous* page's
            // title. Keeping it would caption the new page with the old one's name
            // until a title happens to arrive; clearing falls back to
            // `displayTitle`, which shows the host — wrong in no case.
            record.title = ""
        }

        delegate?.tabControllerDidChangeChrome(self)

        guard isNewPage else { return }
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

        await adoptLevel(for: navigationAction)
        return (.allow, preferences)
    }

    /// Re-resolve the level when a tab crosses to a different site.
    ///
    /// The level is per *origin*, but it was only ever read when the tab was built —
    /// so following a link from a docs site to a shop carried the docs site's level
    /// and its rule lists along with it. This is the one hook that runs after the
    /// destination is known and before its document exists, which is what both the
    /// bootstrap script and the rule lists need.
    ///
    /// Both writes are guarded on actually differing. `updateConfiguration` re-adds
    /// the whole bundle source, and `reattach` awaits the blocker actor; doing
    /// either on every same-site navigation would be a tax paid on every click.
    private func adoptLevel(for navigationAction: WKNavigationAction) async {
        guard
            navigationAction.targetFrame?.isMainFrame ?? false,
            let incoming = navigationAction.request.url?.zenticOrigin,
            incoming != attachedOrigin,
            !isDiscarded
        else { return }

        attachedOrigin = incoming
        let resolved = resolveLevel(incoming)
        guard resolved.level != level || resolved.automatic != automaticLevel else { return }

        let previous = level
        level = resolved.level
        automaticLevel = resolved.automatic

        if previous.shield != resolved.level.shield,
            let controller = webView?.configuration.userContentController
        {
            await Blocking.reattach(to: controller, shield: resolved.level.shield)
        }

        if let bridge {
            var configuration = bridge.currentConfiguration
            configuration.level = resolved.level
            configuration.mode = resolved.level.readerMode
            bridge.updateConfiguration(configuration)
        }

        readerMode = resolved.level.readerMode
        trace("level", "tab \(shortID) → \(resolved.level.rawValue) for \(incoming)")
        delegate?.tabControllerDidChangeChrome(self)
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
        delegate?.tabControllerDidChangeChrome(self)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The web content process died — usually the OS reclaiming memory. Reload
        // rather than leaving a permanently blank tab.
        trace("tabs", "tab \(shortID) content process terminated; reloading")
        reload()
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        delegate?.tabController(self, didStart: download)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
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
            if let url = webView?.url ?? record.url {
                delegate?.tabController(self, didExtract: result, from: url)
            }
            delegate?.tabControllerDidChangeChrome(self)
        case .needsRecipe(let skeleton):
            trace("bridge", "\(shortID) needsRecipe · \(skeleton.nodes.count) nodes")
        case .failed(let failure):
            trace("bridge", "\(shortID) FAILED at \(failure.stage): \(failure.message)")
        }
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
