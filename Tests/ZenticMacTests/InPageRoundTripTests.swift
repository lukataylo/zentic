import Foundation
import Testing
import WebKit

@testable import ZenticKit

extension AppIntegration {
    /// The in-page bundle in WebKit itself, not jsdom: real cascade, real
    /// constructed stylesheets, real document-start timing. Invariant 4 says
    /// `apply()` is fully reversible between any modes; this holds it to that
    /// on a page styled every way a site styles itself.
    @MainActor
    @Suite struct InPageRoundTrip {
        /// A web view with Zentic's scripts, as every tab has them.
        func page(opening mode: SiteMode) async throws -> WKWebView {
            let server = try await AppIntegration.server()
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            for script in InPageScript.userScripts(SiteBook(defaultMode: mode).inPageConfig(), consent: false) {
                configuration.userContentController.addUserScript(script)
            }
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: configuration)
            try await webView.loadAndWait(server.url("styled.html"))
            // The linked sheet is in once its rule applies.
            try await eventually("the site's stylesheet") { try await style("h1", "fontSize", in: webView) == "40px" || mode == .minimal }
            return webView
        }

        func apply(_ mode: SiteMode, custom: CustomVersion? = nil, on webView: WKWebView) async throws {
            _ = try await webView.zentic("return zentic.apply(config)", ["config": InPageConfig.pageConfig(mode: mode, custom: custom)])
            // WebKit unloads a linked sheet while Minimal has it off, and loads
            // it again when it comes back on — asynchronously, with the page
            // unrendered until it arrives. Wait for that, not a fixed time.
            try await eventually("the site's linked stylesheets") {
                try await webView.page(
                    """
                    const loaded = [...document.styleSheets];
                    return [...document.querySelectorAll("link[rel=stylesheet]")]
                      .every((link) => link.media === "not all" || loaded.includes(link.sheet));
                    """
                ) as? Bool == true
            }
        }

        /// Everything a mode could leave behind: the markup (attributes,
        /// stashed styles, our own elements), each sheet's state, and what the
        /// cascade makes of the elements that matter.
        func fingerprint(_ webView: WKWebView) async throws -> String {
            try await webView.page("""
                const probe = (selector) => {
                  const s = getComputedStyle(document.querySelector(selector));
                  return [s.color, s.fontSize, s.fontFamily, s.display, s.cssFloat, s.width, s.backgroundColor, s.borderLeftColor];
                };
                return JSON.stringify({
                  html: document.documentElement.outerHTML,
                  sheets: [...document.styleSheets].map((s) => [s.href, s.disabled, s.media.mediaText]),
                  adopted: document.adoptedStyleSheets.map((s) => s.disabled),
                  styles: ["html", "body", "h1", "nav a", ".sidebar", ".lede", ".site-only", "img", "footer"].map(probe),
                });
                """) as? String ?? ""
        }

        func style(_ selector: String, _ property: String, in webView: WKWebView) async throws -> String? {
            try await webView.page("return getComputedStyle(document.querySelector('\(selector)'))['\(property)']") as? String
        }

        @Test func minimalAndBackLeavesThePageExactlyAsItWas() async throws {
            let webView = try await page(opening: .original)
            let before = try await fingerprint(webView)

            try await apply(.minimal, on: webView)
            #expect(try await fingerprint(webView) != before)
            #expect(try await style("h1", "fontSize", in: webView) != "40px")
            #expect(try await style("footer", "fontWeight", in: webView) != "700", "the constructed sheet is off too")
            #expect(try await style(".site-only", "display", in: webView) == "none", "what the site hid stays hidden")

            try await apply(.original, on: webView)
            #expect(try await fingerprint(webView) == before)
        }

        @Test func everyModeReturnsToTheOriginal() async throws {
            let webView = try await page(opening: .original)
            let before = try await fingerprint(webView)
            let version = CustomVersion(
                base: .minimal, css: "h1 { color: rgb(1, 2, 3) !important; }", hide: [".sidebar"],
                summary: "Test", prompts: ["Test"])

            // A path through every mode, each step from a different one.
            try await apply(.custom, custom: version, on: webView)
            #expect(try await style(".sidebar", "display", in: webView) == "none")
            #expect(try await style("h1", "color", in: webView) == "rgb(1, 2, 3)")
            try await apply(.clean, on: webView)
            #expect(try await style(".sidebar", "display", in: webView) != "none", "a version's hides go with it")
            try await apply(.minimal, on: webView)
            try await apply(.custom, custom: CustomVersion(base: .clean, css: "", hide: ["nav"], summary: "", prompts: []), on: webView)
            try await apply(.minimal, on: webView)
            #expect(try await style("nav", "display", in: webView) != "none")
            try await apply(.original, on: webView)

            #expect(try await fingerprint(webView) == before)
        }

        /// Opened in Minimal, the page is hidden at document-start until the
        /// site's sheets are switched off. It must come back visible.
        @Test func minimalFromTheFirstPaintShowsThePageAndCanBeUndone() async throws {
            let webView = try await page(opening: .minimal)
            try await eventually("the page to be revealed") {
                try await style("html", "opacity", in: webView) == "1"
            }
            #expect(try await style("h1", "fontSize", in: webView) != "40px")
            #expect(try await style(".site-only", "display", in: webView) == "none")

            try await apply(.original, on: webView)
            #expect(try await style("h1", "fontSize", in: webView) == "40px")
            #expect(try await style(".sidebar", "cssFloat", in: webView) == "right")
            #expect(try await style("footer", "fontWeight", in: webView) == "700")
        }
    }
}
