import Foundation
import WebKit

/// The JavaScript Zentic injects, and the world it runs in.
public enum InPageScript {
    /// Everything of ours runs here. Page script shares the DOM with us but
    /// cannot see or patch our globals.
    @MainActor public static let world = WKContentWorld.world(name: "zentic")

    /// Message handler name the bundle posts to.
    public static let handlerName = "zentic"

    /// The core bundle (`web/src/main.ts`): modes, Minimal, custom versions,
    /// scroll and page metadata. Small, because it runs before first paint.
    public static let bundle = resource("zentic")

    /// Cookie-wall dismissal (`web/src/consent-entry.ts`). Most of the in-page
    /// code by weight, so it runs at document-end, off the path to first paint.
    public static let consentBundle = resource("zentic-consent")

    /// The page-world recorder (`web/src/recorder-entry.ts`), with its site list
    /// and channel still as placeholders. See ``recorderScript(_:)``.
    public static let recorderBundle = resource("zentic-recorder")

    /// What a tab needs to record a library source: which sites are sources, and
    /// the name of the DOM event the recorder and the bundle talk over — random
    /// per web view, so page script cannot listen for an event it cannot name.
    public struct Capture: Sendable, Hashable {
        public var sites: Set<String>
        public var channel: String

        public init(sites: Set<String>, channel: String = Capture.newChannel()) {
            self.sites = sites
            self.channel = channel
        }

        public static func newChannel() -> String {
            "zc" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
    }

    static func resource(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            assertionFailure("\(name).js missing from the bundle — run `npm run build` in web/")
            return ""
        }
        return source
    }

    /// The bootstrap that runs before the bundle: picks this document's config
    /// out of the site table by hostname and leaves it on `window.__zenticConfig`.
    ///
    /// Resolved in the page rather than in Swift because a redirect can land a
    /// tab on a different host than the one it navigated to, and only the
    /// document itself knows for certain where it ended up.
    public static func bootstrap(_ config: InPageConfig, capture: Capture? = nil) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Each site's entry stays a string until its own page asks for it: a
        // string literal is a scan, an object literal is a compile, and with a
        // few custom versions kept the table is tens of kilobytes, on every
        // navigation in every tab.
        var sites: [String: String] = [:]
        for (key, entry) in config.sites {
            // Only what the page reads — not the summary or prompt history.
            let page = PageEntry(
                mode: entry.mode,
                custom: entry.custom.map { .init(base: $0.base, css: $0.css, hide: $0.hide) })
            if let data = try? encoder.encode(page), let json = String(data: data, encoding: .utf8) {
                sites[key] = json
            }
        }
        let table = (try? encoder.encode(sites)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // U+2028/9 are line terminators to older JS parsers; escape them anyway.
        let safe = escapeLineTerminators(table)
        let sources = escapeLineTerminators(json(capture.map { $0.sites.sorted() } ?? []))
        let channel = json(capture?.channel ?? "")
        return """
            (() => {
              const web = location.protocol === "http:" || location.protocol === "https:";
              const key = location.hostname.toLowerCase().replace(/^www\\./, "");
              const raw = web ? \(safe)[key] : undefined;
              const entry = raw ? JSON.parse(raw) : null;
              const mode = web ? (entry ? entry.mode : "\(config.defaultMode.rawValue)") : "original";
              const custom = mode === "custom" && entry && entry.custom
                ? { base: entry.custom.base, css: entry.custom.css, hide: entry.custom.hide }
                : null;
              const capture = web && \(sources).includes(key) ? \(channel) : null;
              window.__zenticConfig = { mode, custom, capture };
            })();
            """
    }

    private static func escapeLineTerminators(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private static func json(_ value: some Encodable) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    /// The recorder with its sites and channel baked in, so it can decline to
    /// patch anything on a page that is not a source before the page's own
    /// scripts run.
    public static func recorderScript(_ capture: Capture) -> String {
        recorderBundle
            .replacingOccurrences(of: "\"__ZENTIC_CAPTURE_SITES__\"", with: escapeLineTerminators(json(capture.sites.sorted())))
            .replacingOccurrences(of: "__ZENTIC_CAPTURE_CHANNEL__", with: capture.channel)
    }

    private struct PageEntry: Encodable {
        struct Custom: Encodable {
            var base: CustomBase
            var css: String
            var hide: [String]
        }
        var mode: SiteMode
        var custom: Custom?
    }

    /// Every script, in injection order.
    ///
    /// - Parameter consent: whether to include cookie-wall dismissal. It goes
    ///   with content blocking — both are off exactly on Original pages — so
    ///   an Original page never pays to parse it.
    ///
    /// - Parameter capture: the library's sources, for a tab that may record
    ///   them. Nil in a private window, which writes nothing to disk.
    @MainActor public static func userScripts(_ config: InPageConfig, consent: Bool, capture: Capture? = nil)
        -> [WKUserScript]
    {
        let bootstrap = WKUserScript(
            source: bootstrap(config, capture: capture), injectionTime: .atDocumentStart, forMainFrameOnly: true,
            in: world)
        var scripts = [bootstrap, bundleScript] + (consent ? [consentScript] : [])
        // The one script Zentic runs in the *page's* world. Deliberately: the
        // page's `fetch` and `XMLHttpRequest` are only reachable from there, and
        // observing the site's own responses — rather than calling its API — is
        // what keeps capture working when the site rotates its request signing.
        // It forwards and never decides; see `recorder-entry.ts`. Installed only
        // when there is a source, so most people run nothing in any page world.
        if let capture, !capture.sites.isEmpty {
            scripts.append(
                WKUserScript(
                    source: recorderScript(capture), injectionTime: .atDocumentStart, forMainFrameOnly: true,
                    in: .page))
        }
        return scripts
    }

    // Made once and shared by every tab: the sources are hundreds of
    // kilobytes, and a script object per tab would be a copy per tab.
    @MainActor private static let bundleScript = WKUserScript(
        source: bundle, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)
    @MainActor private static let consentScript = WKUserScript(
        source: consentBundle, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world)
}
