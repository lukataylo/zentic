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
    private(set) var hasOnlySecureContent = true
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
    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var declaredIcon: URL?
    /// A configuration handed to us by WebKit for a `window.open` — it must be
    /// the one the new web view is created with.
    @ObservationIgnored private var openerConfiguration: WKWebViewConfiguration?

    var isRealized: Bool { webView != nil }
    var displayHost: String { URLGuess.displayHost(url ?? pendingURL) }
    var siteKey: String? { SiteKey.for(url ?? pendingURL) }

    init(id: UUID = UUID(), url: URL?, title: String = "") {
        self.id = id
        self.pendingURL = url
        self.url = url
        self.title = title
        self.icon = Favicons.shared.cached(for: url)
        self.mode = AppModel.shared.mode(for: url)
    }

    init(openerConfiguration: WKWebViewConfiguration) {
        self.id = UUID()
        self.title = ""
        self.openerConfiguration = openerConfiguration
    }

    // MARK: - Web view

    /// The web view, created on first use.
    @discardableResult
    func realize() -> WKWebView {
        if let webView { return webView }

        let configuration = openerConfiguration ?? Self.makeConfiguration()
        openerConfiguration = nil
        let delegate = TabDelegate(tab: self)
        self.delegate = delegate
        let controller = configuration.userContentController
        controller.removeScriptMessageHandler(forName: InPageScript.handlerName, contentWorld: InPageScript.world)
        controller.add(delegate, contentWorld: InPageScript.world, name: InPageScript.handlerName)
        installScripts(on: controller)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.pageZoom = zoom
        self.webView = webView

        let target = pendingURL
        let blocks = AppModel.shared.mode(for: target).blocks
        Blocking.attach(to: controller, shield: blocks ? .standard : .off)
        blockingAttached = blocks

        observe(webView)
        if let target {
            pendingURL = nil
            webView.load(URLRequest(url: target))
        }
        return webView
    }

    /// Drop the web view, keeping the URL and title. Used when a tab is closed
    /// and when memory is reclaimed.
    func suspend() {
        guard let webView else { return }
        pendingURL = webView.url ?? url
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        observations.removeAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
        delegate = nil
        isLoading = false
    }

    private static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isTextInteractionEnabled = true
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Without a Safari token many sites serve a degraded page to WKWebView.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        return configuration
    }

    /// Re-install the document-start scripts with the current site table. Takes
    /// effect from the next document; the live one is updated by ``applyMode()``.
    func installScripts(on controller: WKUserContentController? = nil) {
        guard let controller = controller ?? webView?.configuration.userContentController else { return }
        controller.removeAllUserScripts()
        for script in InPageScript.userScripts(AppModel.shared.book.inPageConfig()) {
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
            webView.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.hasOnlySecureContent = wv.hasOnlySecureContent }
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
        previewing = nil
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
        Task {
            await Blocking.reattach(to: controller, shield: on ? .standard : .off)
            proceed()
        }
    }

    // MARK: - Events from the delegate

    fileprivate func didStartNavigation(to url: URL?) {
        failure = nil
        chromeCollapsed = false
    }

    fileprivate func didCommit() {
        failure = nil
        mode = AppModel.shared.mode(for: webView?.url)
        previewing = nil
        declaredIcon = nil
        chromeCollapsed = false
    }

    fileprivate func didFinish() {
        guard let url = webView?.url else { return }
        AppModel.shared.recordVisit(url: url, title: title)
        if icon == nil || declaredIcon == nil { refreshIcon() }
        browser?.tabDidChange(self)
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
        guard let webView, !text.isEmpty else { return false }
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
    /// The height of the floating toolbar. The page is *not* inset by it: the
    /// page starts at the very top of the card and the toolbar floats over it,
    /// folding away as soon as the page scrolls.
    static let toolbarInset: CGFloat = 52
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
        tab?.didStartNavigation(to: webView.url)
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
        webView.reload()
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
