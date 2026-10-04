import AppKit
import Observation
import WebKit
import ZenticKit

/// One tab: a web view, what it is showing, and what Zentic is doing to it.
///
/// The web view is created lazily. A tab restored at launch is a title, a URL
/// and an icon until it is first shown, so a session of forty tabs opens as fast
/// as a session of one.
@MainActor
@Observable
final class Tab: Identifiable {
    let id: UUID
    private(set) var url: URL?
    private(set) var title: String
    private(set) var icon: NSImage?
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// The page's own background, sampled by WebKit — the toolbar's band is
    /// painted in it so the band reads as the top of the site.
    private(set) var pageColor: NSColor?

    /// Whether the page is dark, judged from its own background — the toolbar
    /// floats on the page, so it takes the page's scheme, not the system's.
    var pageIsDark: Bool? {
        guard let color = pageColor?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else { return nil }
        let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        return luminance < 0.45
    }
    /// A load that failed before anything committed, shown as a native page.
    private(set) var failure: LoadFailure?
    /// A page stopped before it loaded: a listed host, or a certificate that
    /// could not be verified. See `Features/Safety`.
    var securityWarning: SecurityWarning?
    /// An `http:` page asking for a password or card number.
    var hasInsecureForm = false
    /// Working out why a certificate failed; dropped if the tab moves on first.
    @ObservationIgnored private var certificateDiagnosis: Task<Void, Never>?

    /// The mode the document on screen is in — what the toolbar should show.
    private(set) var mode: SiteMode = .clean
    /// A custom version being previewed but not yet kept.
    private(set) var previewing: CustomVersion?

    /// Scrolled down past the top: the toolbar folds into a pill.
    var chromeCollapsed = false
    var zoom: Double = 1 {
        didSet { webView?.pageZoom = zoom }
    }

    let design = DesignSession()
    /// The save prompt and AutoFill menu for this tab's sign-ins.
    @ObservationIgnored private(set) lazy var passwords = TabPasswords(tab: self)
    /// Camera, location and the rest: what this page asked and may do.
    let permissions = TabPermissions()

    /// Set by the browser so the tab can open new tabs and report changes.
    /// The tab's window decides its sites' modes (a private window keeps its
    /// own), so the mode shown before the page loads is re-read on arrival.
    @ObservationIgnored weak var browser: Browser? {
        didSet { if !isRealized { mode = siteMode(for: url ?? pendingURL) } }
    }
    /// Where a pinned tab goes back to when closed; nil for an ordinary tab.
    var pinnedURL: URL?
    var isPinned: Bool { pinnedURL != nil }
    /// Restored from a session: its back/forward list may be on disk.
    @ObservationIgnored var hasStateOnDisk = false
    private var isPrivate: Bool { browser?.isPrivate == true }
    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var delegate: TabDelegate?
    @ObservationIgnored private var blockingAttached: Bool?
    @ObservationIgnored private var blockingChange: Task<Void, Never>?
    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var declaredIcon: URL?
    /// A configuration handed to us by WebKit for a `window.open` — it must be
    /// the one the new web view is created with.
    @ObservationIgnored private var openerConfiguration: WKWebViewConfiguration?

    /// Whether the tab has a live web view. Observable (unlike `webView`) so
    /// the page card follows a tab being suspended or restored.
    private(set) var isRealized = false
    /// When the tab was last shown — the browser suspends the least recent.
    var lastShown = Date()
    /// Back/forward list and scroll position, kept across a suspension.
    @ObservationIgnored private var savedState: Any?
    var displayHost: String {
        // A warning page stands in for whatever the tab showed before, extension page or not.
        if securityWarning == nil, let name = Extensions.shared.name(ofPage: url) { return name }
        return URLGuess.displayHost(securityWarning?.url ?? url ?? pendingURL)
    }
    var siteKey: String? { SiteKey.for(url ?? pendingURL) }

    init(id: UUID = UUID(), url: URL?, title: String = "", pinnedURL: URL? = nil) {
        self.id = id
        defer { (design.tab, permissions.tab) = (self, self) }
        self.pendingURL = url
        self.url = url
        self.title = title
        self.pinnedURL = pinnedURL
        self.icon = Favicons.shared.cached(for: url)
        self.mode = AppModel.shared.mode(for: url)
    }

    init(openerConfiguration: WKWebViewConfiguration) {
        self.id = UUID()
        defer { (design.tab, permissions.tab) = (self, self) }
        self.title = ""
        self.openerConfiguration = openerConfiguration
    }

    // MARK: - Web view

    /// The web view, created on first use.
    @discardableResult
    func realize() -> WKWebView {
        if let webView { return webView }

        // A pop-up's configuration is WebKit's to give, autoplay included,
        // and it is never re-made: that would cut it off from its opener.
        autoplay = openerConfiguration == nil ? autoplayDecision(for: loadAfterRestore ?? pendingURL) : nil
        let configuration =
            openerConfiguration
            ?? Self.makeConfiguration(dataStore: browser?.dataStore ?? .zentic, autoplay: autoplay ?? .ask)
        if openerConfiguration != nil {
            // A popup's configuration arrives carrying its opener's content
            // controller. Shared, the two tabs would steal each other's message
            // handler and flip each other's content blockers; each tab gets its
            // own. (The opener relationship lives elsewhere in the configuration.)
            configuration.userContentController = WKUserContentController()
        }
        openerConfiguration = nil
        let delegate = TabDelegate(tab: self)
        self.delegate = delegate
        let controller = configuration.userContentController
        controller.add(delegate, contentWorld: InPageScript.world, name: InPageScript.handlerName)
        installScripts(on: controller)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.pageZoom = zoom
        // The page lays out below the toolbar, so nothing at its very top is
        // unreachable under the glass (a site's header has nowhere to scroll
        // to at offset zero). WebKit fills the band with the page's own colour
        // and content scrolls up beneath it.
        webView.obscuredContentInsets = NSEdgeInsets(top: Metrics.toolbarInset, left: 0, bottom: 0, right: 0)
        self.webView = webView

        observe(webView)
        permissions.attach(webView)
        isRealized = true
        if let target = pendingURL {
            pendingURL = nil
            let state = savedState
            savedState = nil
            let readsDisk = state == nil && hasStateOnDisk
            hasStateOnDisk = false
            let next = loadAfterRestore
            loadAfterRestore = nil
            // Load only once the blockers are attached; otherwise the first
            // page of a new tab would go out unblocked.
            prepareBlocking(for: next ?? target) { [id] in
                guard readsDisk else {
                    Self.restore(state, or: target, in: webView)
                    if let next { webView.load(URLRequest(url: next)) }
                    return
                }
                Task {
                    let saved = await Windows.tabStates.read(id)
                    // The user may have gone somewhere else while it was read.
                    guard webView.url == nil, !webView.isLoading else { return }
                    Self.restore(saved, or: target, in: webView)
                }
            }
        }
        return webView
    }

    /// Back where the user left it — history, scroll position, form state —
    /// or, with nothing saved, a fresh load.
    private static func restore(_ state: Any?, or url: URL, in webView: WKWebView) {
        if let state {
            webView.interactionState = state
        } else {
            webView.load(address: url)
        }
    }

    // MARK: - Saved state

    /// Write the page's back/forward list and scroll position to disk, so a
    /// relaunch — even after a crash — comes back to the same place. Never for
    /// a private window.
    func persistState() {
        guard !isPrivate, let state = webView?.interactionState as? Data else { return }
        Windows.tabStates.write(state, for: id)
    }

    /// Synchronous, for app termination.
    func persistStateNow() {
        guard !isPrivate, let state = (webView?.interactionState ?? savedState) as? Data else { return }
        Windows.tabStates.writeNow(state, for: id)
    }

    func forgetSavedState() {
        hasStateOnDisk = false
        guard !isPrivate else { return }
        Windows.tabStates.remove(id)
    }

    /// Another tab took the window: remember where this one was scrolled to.
    func didHide() {
        lastShown = .now
        persistState()
    }

    /// ⌘W on a pinned tab: unload it and put it back on its pinned page.
    func resetToPin() {
        guard let pinnedURL else { return }
        design.reset()
        suspend(persisting: false)
        savedState = nil
        forgetSavedState()
        failure = nil
        if url != pinnedURL {
            if SiteKey.for(url) != SiteKey.for(pinnedURL) { icon = Favicons.shared.cached(for: pinnedURL) }
            url = pinnedURL
            // The page's own title arrives when it next loads.
            title = ""
        }
        pendingURL = pinnedURL
        mode = siteMode(for: pinnedURL)
    }

    /// Drop the web view, keeping the URL and title. Used when a tab is closed
    /// (closing keeps the record for Reopen Closed Tab).
    ///
    /// `persisting` also writes where the page was to disk — the suspended
    /// tab's freshest state, which a crash would otherwise lose. Not for a tab
    /// whose state is about to be deleted.
    func suspend(persisting: Bool = true) {
        guard let webView else { return }
        pendingURL = webView.url ?? url
        savedState = webView.interactionState
        if persisting, !isPrivate, let state = savedState as? Data { Windows.tabStates.write(state, for: id) }
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        observations.removeAll()
        permissions.detach()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
        isRealized = false
        delegate = nil
        isLoading = false
        // The next web view gets a fresh controller with nothing attached.
        blockingAttached = nil
        blockingChange = nil
    }

    /// Whether suspending would interrupt something the user would notice:
    /// sound or video playing, the camera or microphone in use, or a custom
    /// version being designed.
    func isBusy() async -> Bool {
        guard let webView else { return false }
        // An unkept custom version lives only on the live page.
        if design.isPresented || previewing != nil { return true }
        // A question on screen would be answered into a page that is gone.
        if permissions.current != nil { return true }
        if webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none { return true }
        return await webView.requestMediaPlaybackState() == .playing
    }

    private static func makeConfiguration(dataStore: WKWebsiteDataStore, autoplay: PermissionDecision)
        -> WKWebViewConfiguration
    {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isTextInteractionEnabled = true
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        // Safari's rule by default: muted video may autoplay, sound waits for
        // the user. Per site, from the Auto-Play permission.
        configuration.mediaTypesRequiringUserActionForPlayback =
            switch autoplay {
            case .allow: []
            case .ask: .audio
            case .deny: .all
            }
        // Without a Safari token many sites serve a degraded page to WKWebView.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        // One controller for every tab; WebKit keeps each extension to the
        // windows it is allowed in (see `Extensions.controller`).
        configuration.webExtensionController = Extensions.shared.controller
        return configuration
    }

    /// The mode `url` opens in, as this tab's window sees it.
    private func siteMode(for url: URL?) -> SiteMode {
        browser?.mode(for: url) ?? AppModel.shared.mode(for: url)
    }

    private func siteCustom(for url: URL?) -> CustomVersion? {
        browser.map { $0.custom(for: url) } ?? AppModel.shared.custom(for: url)
    }

    /// Re-install the document-start scripts with the current site table. Takes
    /// effect from the next document; the live one is updated by ``applyMode()``.
    func installScripts(on controller: WKUserContentController? = nil) {
        guard let controller = controller ?? webView?.configuration.userContentController else { return }
        controller.removeAllUserScripts()
        let consent = blockingAttached ?? siteMode(for: url ?? pendingURL).blocks
        for script in InPageScript.userScripts((browser?.book ?? AppModel.shared.book).inPageConfig(), consent: consent) {
            controller.addUserScript(script)
        }
        controller.addUserScript(InPageScript.passwordScript(saving: !isPrivate))
    }

    private func observe(_ webView: WKWebView) {
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self, let title = wv.title, !title.isEmpty else { return }
                    self.title = title
                    self.browser?.tabDidChange(self)
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = wv.url else { return }
                    let siteChanged = SiteKey.for(url) != SiteKey.for(self.url)
                    self.url = url
                    if siteChanged {
                        self.icon = Favicons.shared.cached(for: url)
                        self.design.reset()
                    }
                    self.browser?.tabDidChange(self)
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.isLoading = wv.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.progress = wv.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoForward = wv.canGoForward }
            },
            webView.observe(\.underPageBackgroundColor, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.pageColor = wv.underPageBackgroundColor }
            },
        ]
    }

    // MARK: - Navigation

    func load(_ url: URL) {
        failure = nil
        securityWarning = nil
        chromeCollapsed = false
        if let webView {
            prepareBlocking(for: url) { webView.load(address: url) }
        } else {
            pendingURL = url
            self.url = url
            mode = siteMode(for: url)
            icon = Favicons.shared.cached(for: url)
            if browser?.selectedTab === self { realize() }
        }
    }

    func goBack() {
        // The warned-about load never entered history: Back from its warning
        // is the page underneath, not the one before that.
        if securityWarning != nil { return leaveWarning() }
        webView?.goBack()
    }
    func goForward() { webView?.goForward() }

    func reload() {
        failure = nil
        // Under a warning the web view still holds the previous page;
        // reloading means trying the warned-about address again.
        if let warning = securityWarning { return load(warning.url) }
        guard let webView else {
            realize()
            return
        }
        if webView.url == nil, let url { webView.load(address: url) } else { webView.reload() }
    }

    func stop() { webView?.stopLoading() }

    // MARK: - Modes

    /// Bring the document on screen in line with what the user chose for its
    /// site. Live where possible; a reload only when blocking has to change.
    func applyMode() {
        let target = siteMode(for: url)
        if previewing != nil {
            previewing = nil
            design.previewDropped()
        }
        guard let webView, SiteKey.isWeb(url) else {
            mode = target
            return
        }
        installScripts()
        if blockingAttached != target.blocks {
            mode = target
            setBlocking(target.blocks) { webView.reload() }
            return
        }
        mode = target
        apply(InPageConfig.pageConfig(mode: target, custom: siteCustom(for: url)))
    }

    /// Show a custom version on the live page without keeping it.
    func preview(_ version: CustomVersion) async -> [String] {
        previewing = version
        mode = .custom
        let result = await callJS(
            "return zentic.apply(config)",
            arguments: ["config": InPageConfig.pageConfig(mode: .custom, custom: version)])
        return ((result as? [String: Any])?["rejected"] as? [String]) ?? []
    }

    struct Health {
        var visibleText: Int
        var overflowsX: Bool
    }

    /// How much of the page is readable right now. See `web/src/health.ts`.
    func health() async -> Health? {
        guard let value = await callJS("return zentic.health()", arguments: [:]) as? [String: Any] else { return nil }
        return Health(
            visibleText: (value["visibleText"] as? NSNumber)?.intValue ?? 0,
            overflowsX: value["overflowsX"] as? Bool ?? false)
    }

    /// The visible page as a JPEG data URL, for a model to look at.
    func screenshot() async -> String? {
        guard let webView else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: min(1280, Double(webView.bounds.width)))
        guard let image = try? await webView.takeSnapshot(configuration: configuration),
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
        else { return nil }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }

    /// The structural outline a model writes selectors against.
    func snapshot() async -> String? {
        await callJS("return zentic.snapshot()", arguments: [:]) as? String
    }

    private func apply(_ config: [String: Any]) {
        Task { _ = await callJS("return zentic.apply(config)", arguments: ["config": config]) }
    }

    func callJS(_ body: String, arguments: [String: Any]) async -> Any? {
        guard let webView else { return nil }
        do {
            return try await webView.callAsyncJavaScript(
                "if (typeof zentic === 'undefined') return null; " + body,
                arguments: arguments, in: nil, contentWorld: InPageScript.world)
        } catch {
            trace("tab", "js failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Attach or detach the content blockers before `url` starts loading.
    fileprivate func prepareBlocking(for url: URL?, then proceed: @escaping () -> Void) {
        let blocks = siteMode(for: url).blocks
        guard blocks != blockingAttached else { return proceed() }
        setBlocking(blocks, then: proceed)
    }

    private func setBlocking(_ on: Bool, then proceed: @escaping () -> Void) {
        guard let controller = webView?.configuration.userContentController else { return proceed() }
        blockingAttached = on
        // Strictly in order. Attaching waits on compiled lists and detaching
        // does not, so two quick navigations could otherwise finish backwards
        // and leave the lists attached on a page the user set to Original.
        // Cookie-wall dismissal travels with blocking (both off on Original).
        installScripts(on: controller)
        let previous = blockingChange
        blockingChange = Task {
            await previous?.value
            await Blocking.reattach(to: controller, shield: on ? .standard : .off)
            proceed()
        }
    }

    // MARK: - Autoplay

    /// The Auto-Play decision this web view was made with; nil for a pop-up's,
    /// which WebKit configured.
    @ObservationIgnored private var autoplay: PermissionDecision?
    /// Where to go once a re-made web view has its history back.
    @ObservationIgnored private var loadAfterRestore: URL?
    @ObservationIgnored private var lastRemade: ContinuousClock.Instant?

    private func autoplayDecision(for url: URL?) -> PermissionDecision {
        (browser?.permissions ?? .shared).decision(.autoplay, for: SiteKey.for(url))
    }

    /// Whether going to `url` needs a new web view. Autoplay is part of a web
    /// view's configuration, fixed when it is made, so a site set differently
    /// from the one the web view was made for gets a fresh one — with the
    /// history carried over. Most sites share the default, so this is rare.
    fileprivate func remakesForAutoplay(_ url: URL?) -> Bool {
        guard let autoplay, SiteKey.isWeb(url), autoplayDecision(for: url) != autoplay else { return false }
        // Restoring the history loads the page it was on, which may well be
        // set differently again. Once is enough; that load is superseded.
        if let lastRemade, ContinuousClock.now - lastRemade < .seconds(2) { return false }
        return true
    }

    fileprivate func remake(loading target: URL) {
        guard let webView else { return }
        let current = webView.url
        lastRemade = .now
        suspend(persisting: false)
        if current == nil {
            // Nothing to carry over: just load the page.
            savedState = nil
            pendingURL = target
        } else if current != target {
            loadAfterRestore = target
        }
        realize()
    }

    // MARK: - Events from the delegate

    fileprivate func didStartNavigation() {
        failure = nil
        securityWarning = nil
        certificateDiagnosis?.cancel()
        chromeCollapsed = false
    }

    fileprivate func didCommit() {
        failure = nil
        permissions.documentChanged()
        hasInsecureForm = false
        mode = siteMode(for: webView?.url)
        if previewing != nil {
            // A new document: the preview lived on the old one.
            previewing = nil
            design.previewDropped()
        }
        declaredIcon = nil
        chromeCollapsed = false
        passwords.pageChanged()
    }

    fileprivate func didFinish() {
        guard let url = webView?.url else { return }
        // A page restored from the back/forward cache was styled when it was
        // cached, perhaps under a mode the user has since changed. `apply` is
        // idempotent and leaves the DOM alone when nothing changed.
        if SiteKey.isWeb(url), previewing == nil {
            apply(InPageConfig.pageConfig(mode: mode, custom: siteCustom(for: url)))
            if mode == .custom { Rechecks.shared.pageDidLoad(self) }
        }
        if !isPrivate { AppModel.shared.recordVisit(url: url, title: title) }
        persistState()
        checkForInsecureForm()
        if icon == nil || declaredIcon == nil { refreshIcon() }
        browser?.tabDidChange(self)
    }

    @ObservationIgnored private var recentCrashes: [Date] = []

    /// WebKit's content process went away — a crash, or macOS reclaiming
    /// memory. Only the tab on screen reloads now, and not in a loop; a
    /// background tab is suspended and reloads when next shown.
    fileprivate func contentProcessTerminated() {
        guard browser?.selectedTab === self else { return suspend() }
        recentCrashes = recentCrashes.filter { $0.timeIntervalSinceNow > -10 } + [.now]
        if recentCrashes.count > 2 {
            failure = LoadFailure(url: url, message: "This page keeps crashing.", code: NSURLErrorUnknown)
        } else {
            webView?.reload()
        }
    }

    fileprivate func didFail(_ error: Error, url: URL?) {
        let ns = error as NSError
        // Cancelled (a new navigation replaced this one) and "frame load
        // interrupted" (a download, or a policy change) are not failures.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 204) { return }
        let failure = LoadFailure(
            url: url ?? (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? self.url,
            message: ns.localizedDescription, code: ns.code)
        guard CertificateTrust.isCertificateError(ns) else { return self.failure = failure }
        certificateDiagnosis?.cancel()
        certificateDiagnosis = Task {
            // A certificate failure gets its own page; diagnosing it takes a
            // trust evaluation off the main thread first.
            let warning = await CertificateTrust.warning(for: ns)
            guard !Task.isCancelled else { return }
            if let warning { securityWarning = .certificate(warning) } else { self.failure = failure }
        }
    }

    fileprivate func receive(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "scroll":
            let y = message["y"] as? Double ?? 0
            let down = (message["direction"] as? String) == "down"
            let collapse = y > 32 && down
            if collapse != chromeCollapsed { chromeCollapsed = collapse }
        case "meta":
            if let href = message["icon"] as? String, let iconURL = URL(string: href) {
                declaredIcon = iconURL
                refreshIcon()
            }
        default:
            break
        }
    }

    private func refreshIcon() {
        guard let url = webView?.url, SiteKey.isWeb(url) else { return }
        let declared = declaredIcon
        Task {
            if let image = await Favicons.shared.icon(for: url, declared: declared, persist: !isPrivate),
                SiteKey.for(self.url) == SiteKey.for(url)
            {
                self.icon = image
                self.browser?.tabDidChange(self)
            }
        }
    }

    // MARK: - Find, zoom, print

    func find(_ text: String, backwards: Bool = false) async -> Bool {
        guard let webView else { return false }
        guard !text.isEmpty else {
            // Clear the last match's highlight.
            _ = try? await webView.evaluateJavaScript("getSelection().removeAllRanges()")
            return false
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        let result = try? await webView.find(text, configuration: configuration)
        return result?.matchFound ?? false
    }

    func printPage() {
        guard let webView, let window = webView.window else { return }
        let operation = webView.printOperation(with: .shared)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    var snapshotSource: Saved { Saved(id: id, url: url ?? pendingURL, title: title, pinnedURL: pinnedURL) }
    typealias Saved = SessionSnapshot.Tab
}

struct LoadFailure: Equatable {
    var url: URL?
    var message: String
    var code: Int
}

enum Metrics {
    /// The height of the floating toolbar's band at the top of the page.
    static let toolbarInset: CGFloat = 52
    /// The page card's corner: concentric with the toolbar's 34pt round
    /// buttons, which sit 9pt in from its edge.
    static let cardRadius: CGFloat = 17 + 9
}

// MARK: - Delegate

/// WebKit's delegates, kept off `Tab` so the web view never retains the tab.
@MainActor
private final class TabDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    weak var tab: Tab?
    init(tab: Tab) { self.tab = tab }

    // Navigation

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let url = navigationAction.request.url
        // ⌘-click and middle-click open in a new tab, as everywhere on the Mac.
        if navigationAction.navigationType == .linkActivated,
            navigationAction.modifierFlags.contains(.command) || navigationAction.buttonNumber == 2,
            let url,
            // A web page may not reach the disk by being ⌘-clicked: a new tab
            // would load the file with its folder readable. WebKit refuses
            // the plain click below.
            !url.isFileURL || webView.url?.isFileURL == true
        {
            tab?.browser?.openTab(url, after: tab, select: navigationAction.modifierFlags.contains(.shift))
            return (.cancel, preferences)
        }
        if let url, let scheme = url.scheme?.lowercased(),
            !["http", "https", "about", "data", "blob", "file", "javascript", "webkit-extension"].contains(scheme)
        {
            // mailto:, facetime:, app links — hand to the system.
            NSWorkspace.shared.open(url)
            return (.cancel, preferences)
        }
        // Downloads too: a file from a malware host is the very thing to stop.
        if navigationAction.targetFrame?.isMainFrame == true || navigationAction.shouldPerformDownload, let tab,
            let threat = await SafeBrowsing.shared.warning(for: url)
        {
            tab.securityWarning = .dangerous(threat)
            return (.cancel, preferences)
        }
        if navigationAction.shouldPerformDownload {
            let allowed = await tab?.permissions.allowsDownload(
                named: Self.fileName(url), site: Self.page(of: webView, else: url))
            return (allowed == true ? .download : .cancel, preferences)
        }
        if navigationAction.targetFrame?.isMainFrame == true, let tab, let url,
            navigationAction.request.httpMethod == "GET", navigationAction.navigationType != .backForward,
            tab.remakesForAutoplay(url)
        {
            // Once WebKit has the cancel.
            Task { tab.remake(loading: url) }
            return (.cancel, preferences)
        }
        if navigationAction.targetFrame?.isMainFrame == true, let tab {
            await withCheckedContinuation { continuation in
                tab.prepareBlocking(for: url) { continuation.resume() }
            }
        }
        return (.allow, preferences)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let tab, let threat = await SafeBrowsing.shared.warning(for: navigationResponse.response.url) {
            // Redirected onto a listed host.
            tab.securityWarning = .dangerous(threat)
            return .cancel
        }
        if !navigationResponse.canShowMIMEType {
            let response = navigationResponse.response
            let allowed = await tab?.permissions.allowsDownload(
                named: response.suggestedFilename ?? "", site: Self.page(of: webView, else: response.url))
            return allowed == true ? .download : .cancel
        }
        if navigationResponse.isForMainFrame, let tab {
            // A redirect may have landed us on a host with a different mode.
            await withCheckedContinuation { continuation in
                tab.prepareBlocking(for: navigationResponse.response.url) { continuation.resume() }
            }
        }
        return .allow
    }

    /// What a link's file is called, if its URL says; not "/" for a site's root,
    /// nor a blob's UUID.
    private static func fileName(_ url: URL?) -> String {
        guard let url, SiteKey.isWeb(url), url.path != "/" else { return "" }
        return url.lastPathComponent
    }

    /// The site of the page on screen — not the URL being navigated to, which
    /// WebKit reports as soon as a navigation starts.
    private static func page(of webView: WKWebView, else fallback: URL?) -> String? {
        SiteKey.for(webView.backForwardList.currentItem?.url ?? fallback)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab?.didStartNavigation()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { tab?.didCommit() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { tab?.didFinish() }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        tab?.didFail(error, url: webView.url)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tab?.didFail(error, url: webView.url)
    }

    func webView(
        _ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await CertificateTrust.shared.respond(to: challenge)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Breadcrumbs.note("A page's web process ended", in: tab?.browser)
        tab?.contentProcessTerminated()
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        Downloads.shared.adopt(download, isPrivate: !webView.configuration.websiteDataStore.isPersistent)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        Downloads.shared.adopt(download, isPrivate: !webView.configuration.websiteDataStore.isPersistent)
    }

    // UI

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let tab, let browser = tab.browser,
            tab.permissions.allowsPopup(to: navigationAction.request.url, from: webView.url)
        else { return nil }
        let child = Tab(openerConfiguration: configuration)
        browser.insert(child, after: tab, select: true)
        return child.realize()
    }

    func webView(
        _ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        await tab?.permissions.decideCapture(type, origin: origin, frame: frame) ?? .deny
    }

    @available(macOS 27.0, *)
    func webView(
        _ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        guard let tab else { return decisionHandler(.deny) }
        Task { decisionHandler(await tab.permissions.decideLocation(origin: origin, frame: frame)) }
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let tab else { return }
        tab.browser?.close(tab)
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        let alert = NSAlert()
        alert.messageText = Self.origin(frame)
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = await present(alert, in: webView)
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        let alert = NSAlert()
        alert.messageText = Self.origin(frame)
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await present(alert, in: webView) == .alertFirstButtonReturn
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        let alert = NSAlert()
        alert.messageText = Self.origin(frame)
        alert.informativeText = prompt
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return await present(alert, in: webView) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = webView.window else { return nil }
        let response = await panel.beginSheetModal(for: window)
        return response == .OK ? panel.urls : nil
    }

    private func present(_ alert: NSAlert, in webView: WKWebView) async -> NSApplication.ModalResponse {
        guard let window = webView.window else { return alert.runModal() }
        return await alert.beginSheetModal(for: window)
    }

    private static func origin(_ frame: WKFrameInfo) -> String {
        let host = frame.securityOrigin.host
        return host.isEmpty ? "This page says" : "\(host) says"
    }

    // Messages from the in-page script

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        if (body["type"] as? String)?.hasPrefix("login-") == true {
            tab?.passwords.receive(body, from: message.frameInfo.securityOrigin)
            return
        }
        tab?.receive(body)
    }
}
