import AppKit
import WebKit
import ZenticKit

/// Keeps sources filling while the user is elsewhere — only the ones they asked.
///
/// Two kinds of visit, each a hidden web view that loads the source, lets the
/// recorder see what the site fetches, and goes:
///
/// - **Signed out** (`.background`): a non-persistent data store — no cookies,
///   no session, nobody's account at stake. For public sites.
/// - **Signed in** (`.session`): the user's own data store, so the site shows
///   what it shows them, scrolled a few screens at a reading pace so it loads a
///   little more. A site may treat any automated visit to an account as against
///   its terms, so this is never a default, is switched on per source past a
///   warning, and is paced and capped by ``RefreshSchedule``. It reads; it never
///   clicks, types or posts.
///
/// One visit at a time. Nothing in a test run, in Low Power Mode, or for a
/// source the user already has open — they are refreshing it themselves.
@MainActor
final class SourceRefresher {
    private weak var apps: Apps?
    private var timer: Task<Void, Never>?
    private var visit: Visit?
    /// When each source was visited, kept across launches so the daily cap
    /// holds however often the app is relaunched.
    private var visits: [String: [Date]] {
        get {
            (DataDirectory.defaults.dictionary(forKey: Self.visitsKey) as? [String: [Date]]) ?? [:]
        }
        set {
            let dayAgo = Date.now.addingTimeInterval(-36 * 60 * 60)
            DataDirectory.defaults.set(newValue.mapValues { $0.filter { $0 > dayAgo } }, forKey: Self.visitsKey)
        }
    }
    private static let visitsKey = "sourceVisits"

    init(apps: Apps) {
        self.apps = apps
    }

    func start() {
        guard !TestRun.isActive else { return }
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            // A first look shortly after launch, then every few minutes; each
            // source's own schedule decides whether anything happens.
            try? await Task.sleep(for: .seconds(90))
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(5 * 60))
            }
        }
    }

    private func tick() async {
        guard let apps, visit == nil, !ProcessInfo.processInfo.isLowPowerModeEnabled,
            ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
        else { return }
        let open = Set(Windows.shared.everyTab.filter(\.isRealized).compactMap { Apps.originKey($0.url) })
        for source in apps.sources where source.refresh != .browse && !open.contains(source.origin) {
            let schedule: RefreshSchedule = source.refresh == .session ? .session : .signedOut
            guard schedule.mayVisit(now: .now, previous: visits[source.origin] ?? [], roll: .random(in: 0...1)),
                let url = URL(string: source.homeURL)
            else { continue }
            visits[source.origin, default: []].append(.now)
            let visit = Visit(url: url, origin: source.origin, signedIn: source.refresh == .session, apps: apps)
            self.visit = visit
            await visit.run()
            self.visit = nil
        }
    }

    /// Scroll down a page a few screens, pausing like a reader, so an endless
    /// feed asks its server for the next page. Exposed for the integration tests.
    static func scrollGently(_ webView: WKWebView, steps: Int, pause: ClosedRange<Double>) async {
        for _ in 0..<steps {
            guard !Task.isCancelled else { return }
            _ = try? await webView.callAsyncJavaScript(
                "window.scrollBy({ top: Math.round(innerHeight * 0.85), behavior: 'smooth' }); return true",
                arguments: [:], in: nil, contentWorld: InPageScript.world)
            try? await Task.sleep(for: .seconds(Double.random(in: pause)))
        }
    }
}

/// One page load, recorded and then thrown away.
@MainActor
private final class Visit: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let url: URL
    private let origin: String
    private let signedIn: Bool
    private weak var apps: Apps?
    private var webView: WKWebView?
    private var finished: CheckedContinuation<Void, Never>?
    private var scrolling: Task<Void, Never>?

    init(url: URL, origin: String, signedIn: Bool, apps: Apps) {
        self.url = url
        self.origin = origin
        self.signedIn = signedIn
        self.apps = apps
    }

    func run() async {
        guard let host = URL(string: origin)?.host(percentEncoded: false) else { return }
        let configuration = WKWebViewConfiguration()
        // Signed in means the user's own cookies — the store every tab uses.
        configuration.websiteDataStore = signedIn ? .zentic : .nonPersistent()
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        // Muted: a background visit must never make a sound.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let controller = configuration.userContentController
        controller.add(self, contentWorld: InPageScript.world, name: InPageScript.handlerName)
        // Only this source is recorded: its key alone is the recorder's list.
        let capture = InPageScript.Capture(sites: [SiteKey.for(host: host)])
        for script in InPageScript.userScripts(SiteBook().inPageConfig(), consent: true, capture: capture) {
            controller.addUserScript(script)
        }
        await Blocking.reattach(to: controller, blocking: true)

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        webView.load(URLRequest(url: url))
        trace("apps", "\(signedIn ? "signed-in" : "signed-out") refresh of \(origin)")

        await withCheckedContinuation { continuation in
            finished = continuation
            Task { @MainActor [weak self, signedIn] in
                try? await Task.sleep(for: signedIn ? LibraryBudget.sessionVisitBudget : LibraryBudget.sourceRefreshLoadBudget)
                self?.finish()
            }
        }
    }

    private func finish() {
        guard let finished else { return }
        self.finished = nil
        scrolling?.cancel()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView = nil
        finished.resume()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Sent somewhere else — a sign-in page, another site — is not the page
        // this visit was for. Leave rather than act on it.
        guard Apps.originKey(webView.url) == origin else { return finish() }
        scrolling = Task { @MainActor [weak self, signedIn] in
            // The page's own fetches follow its load; let them land, then read on
            // a little if this is the user's own view of the site.
            try? await Task.sleep(for: .seconds(3))
            if signedIn {
                await SourceRefresher.scrollGently(
                    webView, steps: LibraryBudget.sessionScrollSteps, pause: LibraryBudget.sessionScrollPause)
                try? await Task.sleep(for: .seconds(2))
            }
            self?.finish()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish() }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        finish()
    }

    /// Only this source's own pages are recorded.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let frame = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame,
            Apps.originKey(scheme: frame.protocol, host: frame.host) == origin,
            let body = message.body as? [String: Any], let capture = CapturePayload(message: body)
        else { return }
        apps?.ingest(capture, frameScheme: frame.protocol, frameHost: frame.host, pageURL: webView?.url)
    }
}

extension CapturePayload {
    /// From the in-page bundle's `{type: "capture", url, via, body}` message.
    init?(message: [String: Any]) {
        guard message["type"] as? String == "capture",
            let url = message["url"] as? String, let body = message["body"] as? String,
            let via = (message["via"] as? String).flatMap(Via.init(rawValue:))
        else { return nil }
        self.init(url: url, via: via, body: body)
    }
}
