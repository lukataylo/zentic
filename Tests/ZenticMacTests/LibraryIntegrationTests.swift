import Foundation
import Testing
import WebKit

@testable import ZenticKit
@testable import ZenticMac

extension AppIntegration {
    /// Capture and the app sandbox in WebKit itself: real page worlds, real
    /// CSP, real navigation policy — the places where jsdom and reasoning about
    /// WebKit have both been wrong before.
    @MainActor
    @Suite struct Library {
        /// Collects what the bundle posts to the `zentic` handler, with the
        /// sending frame's origin as WebKit reports it.
        final class Collector: NSObject, WKScriptMessageHandler {
            var captures: [(body: [String: Any], host: String)] = []
            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
                guard let body = message.body as? [String: Any], body["type"] as? String == "capture" else { return }
                captures.append((body, message.frameInfo.securityOrigin.host))
            }
        }

        func page(capturing sites: Set<String>) async throws -> (WKWebView, Collector) {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let collector = Collector()
            configuration.userContentController.add(collector, contentWorld: InPageScript.world, name: InPageScript.handlerName)
            let capture = sites.isEmpty ? nil : InPageScript.Capture(sites: sites)
            for script in InPageScript.userScripts(SiteBook(defaultMode: .original).inPageConfig(), consent: false, capture: capture) {
                configuration.userContentController.addUserScript(script)
            }
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: configuration)
            try await webView.loadAndWait(try await AppIntegration.server().url("feed.html"))
            return (webView, collector)
        }

        /// A source's own fetch and XHR responses, and its embedded JSON, reach
        /// Swift — and the page still gets every response, untouched.
        @Test func aSourcesOwnResponsesAreRecordedAndThePageStillGetsThem() async throws {
            let (webView, collector) = try await page(capturing: ["127.0.0.1"])
            try await eventually("the page's own requests to complete") {
                try await webView.page("return document.getElementById('fetched').textContent + '|' + document.getElementById('xhr').textContent")
                    as? String == "First item from the feed|Second item from the feed"
            }
            try await eventually("both responses and the embedded JSON") { collector.captures.count >= 3 }
            let vias = Set(collector.captures.compactMap { $0.body["via"] as? String })
            #expect(vias == ["fetch", "xhr", "embedded"])
            #expect(collector.captures.allSatisfy { $0.host == "127.0.0.1" }, "filed by WebKit's origin, not the page's word")
            let fetched = try #require(collector.captures.first { $0.body["via"] as? String == "fetch" })
            #expect((fetched.body["body"] as? String)?.contains("First item from the feed") == true)
        }

        /// On a site that is not a source nothing is patched and nothing is sent.
        @Test func aSiteThatIsNotASourceIsLeftAlone() async throws {
            let (webView, collector) = try await page(capturing: ["somewhere.else"])
            try await eventually("the page's own requests to complete") {
                try await webView.page("return document.getElementById('xhr').textContent") as? String == "Second item from the feed"
            }
            try await Task.sleep(for: .milliseconds(300))
            #expect(collector.captures.isEmpty)
            #expect(try await webView.page("return Function.prototype.toString.call(fetch)") as? String == "function fetch() {\n    [native code]\n}")
        }

        /// The page's own scripts cannot see the recorder's channel: a listener
        /// for the obvious names hears nothing.
        @Test func thePageCannotHearTheChannel() async throws {
            let (webView, collector) = try await page(capturing: ["127.0.0.1"])
            try await eventually("captures") { !collector.captures.isEmpty }
            #expect(try await webView.page("return typeof window.__zenticCapture") as? String == "undefined")
        }

        /// A signed-in refresh scrolls the way a reader does, so an endless feed
        /// asks its server for more — and each page it fetches is recorded.
        @Test func scrollingGentlyLoadsAndRecordsMorePages() async throws {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let collector = Collector()
            configuration.userContentController.add(collector, contentWorld: InPageScript.world, name: InPageScript.handlerName)
            for script in InPageScript.userScripts(
                SiteBook(defaultMode: .original).inPageConfig(), consent: false, capture: .init(sites: ["127.0.0.1"]))
            {
                configuration.userContentController.addUserScript(script)
            }
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: configuration)
            try await webView.loadAndWait(try await AppIntegration.server().url("endless.html"))
            try await eventually("the first page") { collector.captures.count >= 1 }
            let before = collector.captures.count

            await SourceRefresher.scrollGently(webView, steps: 6, pause: 0.25...0.35)
            try await eventually("more pages, recorded") { collector.captures.count >= before + 2 }
            let pages = collector.captures.compactMap { ($0.body["url"] as? String).flatMap { URLComponents(string: $0)?.queryItems?.first?.value } }
            #expect(Set(pages).count >= 3, "\(pages)")
        }

        // MARK: - The app sandbox

        func installApp(_ html: String) async throws -> GeneratedApp {
            let app = try await Apps.shared.store.save(
                GeneratedApp(name: "Probe", symbol: "sparkles", sources: [], prompts: []),
                draft: AppDraft(name: "Probe", symbol: "sparkles", html: html), prompt: "probe")
            await Apps.shared.reloadApps()
            return app
        }

        func openApp(_ app: GeneratedApp, in browser: Browser) async throws -> Tab {
            let tab = browser.openTab(app.url)
            tab.webView?.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
            try await eventually("the app's web view") { tab.webView != nil }
            try await tab.webView!.waitForLoad(of: app.url)
            return tab
        }

        static let probe = """
            <!doctype html><html><head><title>Probe</title></head><body>
            <p id="out">waiting</p>
            <script>
              window.results = {};
              results.zentic = typeof zentic === "object" && typeof zentic.query === "function";
              results.rtc = typeof RTCPeerConnection;
              const frame = document.createElement("iframe"); document.body.append(frame);
              try { results.frameRTC = typeof frame.contentWindow.RTCPeerConnection; } catch (e) { results.frameRTC = "blocked"; }
              fetch("https://example.com/").then(() => results.network = "reached", () => results.network = "blocked");
              zentic.query({}).then((r) => results.query = Array.isArray(r) ? "ok" : "bad", (e) => results.query = "error " + e);
              zentic.query({kinds: ["posts"]}).then(() => results.bad = "accepted", () => results.bad = "rejected");
            </script></body></html>
            """

        /// What an app can reach, checked in the engine: its runtime and its own
        /// data, and nothing else — no network, no WebRTC (in the page or a frame).
        @Test func anAppReachesItsRuntimeAndNothingElse() async throws {
            let browser = Browser(isPrivate: false, dataStore: .nonPersistent())
            let app = try await installApp(Self.probe)
            let tab = try await openApp(app, in: browser)
            let webView = try #require(tab.webView)
            try await eventually("the probe's checks to finish") {
                (try await webView.page("return Object.keys(results).length") as? Int ?? 0) >= 6
            }
            let results = try #require(try await webView.page("return results") as? [String: Any])
            #expect(results["zentic"] as? Bool == true)
            #expect(results["query"] as? String == "ok")
            #expect(results["network"] as? String == "blocked")
            #expect(results["rtc"] as? String == "undefined")
            #expect(results["frameRTC"] as? String != "function")
            #expect(results["bad"] as? String == "rejected", "a malformed query fails loudly, never as 'no filter'")
            #expect(tab.mode == .original)
        }

        /// An app's own stylesheet applies: the sandbox allows inline styles, and
        /// nothing of Zentic's in-page code may touch an app's page.
        @Test func anAppsOwnStylesApply() async throws {
            let browser = Browser(isPrivate: false, dataStore: .nonPersistent())
            let app = try await installApp(
                "<!doctype html><html><head><style>p { color: rgb(1, 2, 3); }</style></head><body><p id='x'>styled</p></body></html>")
            let tab = try await openApp(app, in: browser)
            let color = try await tab.webView!.page("return getComputedStyle(document.getElementById('x')).color") as? String
            let sheets = try await tab.webView!.page("return [...document.styleSheets].map(s => String(s.disabled) + ':' + (s.ownerNode && s.ownerNode.outerHTML.slice(0, 60))).join(' | ')") as? String
            #expect(color == "rgb(1, 2, 3)", "\(sheets ?? "")")
        }

        /// CSP cannot stop script navigation; the navigation policy does.
        @Test func anAppCannotNavigateItselfOrClickItsWayOut() async throws {
            let browser = Browser(isPrivate: false, dataStore: .nonPersistent())
            let app = try await installApp("<!doctype html><title>Away</title><p>here</p>")
            let tab = try await openApp(app, in: browser)
            let webView = try #require(tab.webView)
            let outside = try await AppIntegration.server().url("second.html?from=app")
            let tabs = browser.tabs.count

            _ = try await webView.page("location.href = '\(outside.absoluteString)'; return true")
            // A link the app built and "clicked" — reported by WebKit as a link
            // activation, so only the allowance stops it.
            _ = try await webView.page(
                "const a = document.createElement('a'); a.href = '\(outside.absoluteString)&click=1'; document.body.append(a); a.click(); return true")
            _ = try await webView.page("window.open('\(outside.absoluteString)&open=1'); return true")
            try await Task.sleep(for: .milliseconds(500))
            #expect(webView.url == app.url)
            #expect(browser.tabs.count == tabs, "nothing opened without the user")
        }

        /// The web does not open apps: a page that knows an app's id still cannot
        /// navigate a tab to it.
        @Test func aWebPageCannotNavigateIntoAnApp() async throws {
            let browser = Browser(isPrivate: false, dataStore: .nonPersistent())
            let app = try await installApp("<!doctype html><title>Target</title>")
            let page = try await AppIntegration.server().url("second.html")
            let tab = browser.openTab(page)
            try await eventually("the page's web view") { tab.webView != nil }
            try await tab.webView!.waitForLoad(of: page)
            _ = try await tab.webView!.page("location.href = '\(app.url.absoluteString)'; return true")
            try await Task.sleep(for: .milliseconds(400))
            #expect(tab.webView?.url == page)
        }
    }
}
