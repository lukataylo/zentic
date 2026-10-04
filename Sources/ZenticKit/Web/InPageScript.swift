import Foundation
import WebKit

/// The JavaScript Zentic injects, and the world it runs in.
public enum InPageScript {
    /// Everything of ours runs here. Page script shares the DOM with us but
    /// cannot see or patch our globals.
    @MainActor public static let world = WKContentWorld.world(name: "zentic")

    /// Message handler name the bundle posts to.
    public static let handlerName = "zentic"

    /// The built bundle (`web/` → `Resources/zentic.js`).
    public static let bundle: String = {
        guard let url = Bundle.module.url(forResource: "zentic", withExtension: "js"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            assertionFailure("zentic.js missing from the bundle — run `npm run build` in web/")
            return ""
        }
        return source
    }()

    /// The bootstrap that runs before the bundle: picks this document's config
    /// out of the site table by hostname and leaves it on `window.__zenticConfig`.
    ///
    /// Resolved in the page rather than in Swift because a redirect can land a
    /// tab on a different host than the one it navigated to, and only the
    /// document itself knows for certain where it ended up.
    public static func bootstrap(_ config: InPageConfig) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = (try? encoder.encode(config)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // `</script>` cannot appear — this is a user script, not markup — but
        // U+2028/9 are line terminators in older JS parsers. Escape them anyway.
        let safe = json
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return """
            (() => {
              const table = \(safe);
              const web = location.protocol === "http:" || location.protocol === "https:";
              const key = location.hostname.toLowerCase().replace(/^www\\./, "");
              const entry = web ? table.sites[key] : null;
              const mode = web ? (entry ? entry.mode : table.defaultMode) : "original";
              const custom = mode === "custom" && entry && entry.custom
                ? { base: entry.custom.base, css: entry.custom.css, hide: entry.custom.hide }
                : null;
              window.__zenticConfig = { mode: custom || mode !== "custom" ? mode : "clean", custom };
            })();
            """
    }

    /// Both scripts, in injection order.
    @MainActor public static func userScripts(_ config: InPageConfig) -> [WKUserScript] {
        [
            WKUserScript(
                source: bootstrap(config), injectionTime: .atDocumentStart,
                forMainFrameOnly: true, in: world),
            WKUserScript(
                source: bundle, injectionTime: .atDocumentStart,
                forMainFrameOnly: true, in: world),
        ]
    }
}
