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

    /// Set by the browser so the tab can open new tabs and report changes.
    @ObservationIgnored weak var browser: Browser?
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
    var displayHost: String { URLGuess.displayHost(url ?? pendingURL) }
    var siteKey: String? { SiteKey.for(url ?? pendingURL) }

    init(id: UUID = UUID(), url: URL?, title: String = "") {
        self.id = id
        defer { design.tab = self }
        self.pendingURL = url
        self.url = url
        self.title = title
        self.icon = Favicons.shared.cached(for: url)
        self.mode = AppModel.shared.mode(for: url)
    }

    init(openerConfiguration: WKWebViewConfiguration) {
        self.id = UUID()
        defer { design.tab = self }
        self.title = ""
        self.openerConfiguration = openerConfiguration
    }

    // MARK: - Web view

    /// The web view, created on first use.
    @discardableResult
    func realize() -> WKWebView {
        if let webView { return webView }

        let configuration = openerConfiguration ?? Self.makeConfiguration()
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
        isRealized = true
        if let target = pendingURL {
            pendingURL = nil
            let state = savedState
            savedState = nil
            // Load only once the blockers are attached; otherwise the first
            // page of a new tab would go out unblocked.
            prepareBlocking(for: target) {
                if let state {
                    // Back where the user left it: history, scroll position, form state.
                    webView.interactionState = state
                } else {
                    webView.load(URLRequest(url: target))
                }
            }
        }
        return webView
    }

    /// Drop the web view, keeping the URL and title. Used when a tab is closed
    /// (closing keeps the record for Reopen Closed Tab).
    func suspend() {
        guard let webView else { return }
        pendingURL = webView.url ?? url
        savedState = webView.interactionState
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        observations.removeAll()
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
        if webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none { return true }
        return await webView.requestMediaPlaybackState() == .playing
    }

    private static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .zentic
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isTextInteractionEnabled = true
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        // Safari's rule: muted video may autoplay, sound waits for the user.
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        // Without a Safari token many sites serve a degraded page to WKWebView.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        return configuration
    }

    /// Re-install the document-start scripts with the current site table. Takes
    /// effect from the next document; the live one is updated by ``applyMode()``.
    func installScripts(on controller: WKUserContentController? = nil) {
        guard let controller = controller ?? webView?.configuration.userContentController else { return }
        controller.removeAllUserScripts()
        let consent = blockingAttached ?? AppModel.shared.mode(for: url ?? pendingURL).blocks
        for script in InPageScript.userScripts(AppModel.shared.book.inPageConfig(), consent: consent) {
            controller.addUserScript(script)
        }
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
        chromeCollapsed = false
        if let webView {
            prepareBlocking(for: url) { webView.load(URLRequest(url: url)) }
        } else {
            pendingURL = url
            self.url = url
            mode = AppModel.shared.mode(for: url)
            icon = Favicons.shared.cached(for: url)
            if browser?.selectedTab === self { realize() }
        }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    func reload() {
        failure = nil
        guard let webView else {
            realize()
            return
        }
        if webView.url == nil, let url { webView.load(URLRequest(url: url)) } else { webView.reload() }
    }

    func stop() { webView?.stopLoading() }

    // MARK: - Modes

    /// Bring the document on screen in line with what the user chose for its
    /// site. Live where possible; a reload only when blocking has to change.
    func applyMode() {
        let target = AppModel.shared.mode(for: url)
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
        apply(InPageConfig.pageConfig(mode: target, custom: AppModel.shared.custom(for: url)))
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

    private func callJS(_ body: String, arguments: [String: Any]) async -> Any? {
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
        let blocks = AppModel.shared.mode(for: url).blocks
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

    // MARK: - Events from the delegate

    fileprivate func didStartNavigation() {
        failure = nil
        chromeCollapsed = false
    }

    fileprivate func didCommit() {
        failure = nil
        mode = AppModel.shared.mode(for: webView?.url)
        if previewing != nil {
            // A new document: the preview lived on the old one.
            previewing = nil
            design.previewDropped()
        }
        declaredIcon = nil
        chromeCollapsed = false
    }

    fileprivate func didFinish() {
        guard let url = webView?.url else { return }
        // A page restored from the back/forward cache was styled when it was
        // cached, perhaps under a mode the user has since changed. `apply` is
        // idempotent and leaves the DOM alone when nothing changed.
        if SiteKey.isWeb(url), previewing == nil {
            apply(InPageConfig.pageConfig(mode: mode, custom: AppModel.shared.custom(for: url)))
        }
        AppModel.shared.recordVisit(url: url, title: title)
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
        failure = LoadFailure(
            url: url ?? (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? self.url,
            message: ns.localizedDescription, code: ns.code)
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
            if let image = await Favicons.shared.icon(for: url, declared: declared),
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

    var snapshotSource: Saved { Saved(id: id, url: url ?? pendingURL, title: title) }
    typealias Saved = SavedSession.SavedTab
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
private final class TabDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler,
    WKDownloadDelegate
{
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
            let url
        {
            tab?.browser?.openTab(url, after: tab, select: navigationAction.modifierFlags.contains(.shift))
            return (.cancel, preferences)
        }
        if let url, let scheme = url.scheme?.lowercased(),
            !["http", "https", "about", "data", "blob", "file", "javascript"].contains(scheme)
        {
            // mailto:, facetime:, app links — hand to the system.
            NSWorkspace.shared.open(url)
            return (.cancel, preferences)
        }
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
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
        if !navigationResponse.canShowMIMEType { return .download }
        if navigationResponse.isForMainFrame, let tab {
            // A redirect may have landed us on a host with a different mode.
            await withCheckedContinuation { continuation in
                tab.prepareBlocking(for: navigationResponse.response.url) { continuation.resume() }
            }
        }
        return .allow
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

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        tab?.contentProcessTerminated()
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // Downloads

    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String
    ) async -> URL? {
        Downloads.shared.destination(for: suggestedFilename, download: download)
    }

    func downloadDidFinish(_ download: WKDownload) { Downloads.shared.finished(download) }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        Downloads.shared.failed(download, error: error)
    }

    // UI

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let tab, let browser = tab.browser else { return nil }
        let child = Tab(openerConfiguration: configuration)
        browser.insert(child, after: tab, select: true)
        return child.realize()
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
        tab?.receive(body)
    }
}
