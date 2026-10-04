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

    private static func resource(_ name: String) -> String {
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
    public static func bootstrap(_ config: InPageConfig) -> String {
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
        let safe = table
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
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
              window.__zenticConfig = { mode, custom };
            })();
            """
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
    @MainActor public static func userScripts(_ config: InPageConfig, consent: Bool) -> [WKUserScript] {
        let bootstrap = WKUserScript(
            source: bootstrap(config), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)
        return [bootstrap, bundleScript] + (consent ? [consentScript] : [])
    }

    // Made once and shared by every tab: the sources are hundreds of
    // kilobytes, and a script object per tab would be a copy per tab.
    @MainActor private static let bundleScript = WKUserScript(
        source: bundle, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)
    @MainActor private static let consentScript = WKUserScript(
        source: consentBundle, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world)
}
