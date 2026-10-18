import Foundation

/// The box a generated app runs in.
///
/// ## Why a box, and why this one
///
/// Invariant 5 says a model emits validated tokens, never CSS — because free-form
/// CSS can carry `url()`, and `url()` beacons. A generated app *is* free-form
/// HTML, CSS and JavaScript, so that rule cannot hold for it. What can hold is
/// the rule's purpose: **an app can make no request the user did not click.**
///
/// Enforced in four places, none of which the app's code can reach:
///
/// 1. **Content-Security-Policy**, sent as a response header *and* as the first
///    element of the document, ahead of any byte the model wrote. Nothing loads
///    from anywhere but the app's own origin — no scripts, styles, fonts, frames,
///    workers, beacons or `fetch` to the network. Images come only from the
///    library's media cache. A second policy the model writes can only narrow
///    this one; CSP policies intersect.
/// 2. **Navigation policy** (``decide(target:appID:isLinkActivation:allowance:)``).
///    CSP cannot stop `location = "https://…?data"`. Every navigation away from
///    the app is cancelled unless it is a link; a link opens only if it points at
///    something the app was given, and otherwise asks the user first.
/// 3. **Data scope.** The app reads the library only through its own origin, and
///    the scheme handler answers only for the sources the app was created with.
/// 4. **No peer connections.** WebRTC's ICE gathering reaches STUN servers
///    outside CSP's reach, so app tabs run with the engine feature switched off.
public enum AppSandbox {
    public static let scheme = "zentic"

    /// The policy for one app. `'self'` *and* the explicit origin, because
    /// WebKit's treatment of `'self'` for custom schemes is the kind of detail
    /// that changes between releases — and a policy that silently stopped
    /// matching would fail closed (broken images), not open.
    ///
    /// Scripts need the per-response `nonce`, which ``document(html:appID:nonce:configJSON:)``
    /// stamps onto the model's own `<script>` tags before any record exists. Text
    /// captured from a site arrives later, through `zentic.query`, so markup
    /// hidden in a post — `<img src=x onerror=…>` — finds no `'unsafe-inline'` to
    /// run under. That is what makes rendering untrusted text survivable even when
    /// a model forgets to escape it.
    public static func contentSecurityPolicy(appID: String, nonce: String) -> String {
        let me = "\(scheme)://\(appID)"
        return [
            "default-src 'none'",
            "script-src 'self' \(me) 'nonce-\(nonce)'",
            "style-src 'unsafe-inline'",
            "img-src 'self' \(me) data: blob:",
            "connect-src 'self' \(me)",
            "font-src 'none'",
            "media-src 'none'",
            "object-src 'none'",
            "frame-src 'none'",
            "child-src 'none'",
            "worker-src 'none'",
            "manifest-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
            // Not enforced by WebKit today; peer connections are switched off for
            // app tabs at the engine level instead (see TabController). Stated so
            // the policy reads as the whole intent.
            "webrtc 'block'",
        ].joined(separator: "; ")
    }

    /// Where the runtime is served from, inside the app's own origin.
    public static let runtimePath = "/_zentic/runtime.js"

    /// `window.zentic` for apps (`web/src/app-runtime.ts`), built to
    /// `zentic-app.js`. Served from each app's own origin by the shell.
    public static let runtimeSource: Data = {
        guard let url = Bundle.module.url(forResource: "zentic-app", withExtension: "js"),
            let data = try? Data(contentsOf: url)
        else {
            assertionFailure("zentic-app.js missing from the bundle — run `npm run build` in web/")
            return Data()
        }
        return data
    }()

    /// The served document: our policy and runtime first, then the model's HTML.
    ///
    /// The runtime is a classic, synchronous `<script src>`, so `window.zentic`
    /// exists before any script the model wrote runs.
    ///
    /// The model's doctype is dropped and ours leads, so the policy `<meta>` is
    /// the first element parsed. The HTML parser then folds the model's own
    /// `<html>` and `<head>` into the ones it has already opened, which is
    /// standard behaviour and needs no parsing on our side.
    public static func document(html: String, appID: String, nonce: String, configJSON: String) -> String {
        let csp = contentSecurityPolicy(appID: appID, nonce: nonce)
        return """
            <!doctype html><meta charset="utf-8">\
            <meta http-equiv="Content-Security-Policy" content="\(csp)">\
            <meta http-equiv="x-dns-prefetch-control" content="off">\
            <meta name="referrer" content="no-referrer">\
            <script nonce="\(nonce)">window.__zenticAppConfig = \(scriptSafe(configJSON));</script>\
            <script src="\(runtimePath)"></script>
            """ + stampingNonce(nonce, on: strippingDoctype(html))
    }

    /// A fresh nonce per response. 128 bits, hex, so it needs no escaping in an
    /// attribute or a header.
    public static func makeNonce() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Add the nonce to every `<script` start tag the model wrote. A tag that
    /// already has a `nonce` attribute gets a second one, which the parser
    /// ignores — the first wins — so a model cannot pick its own.
    static func stampingNonce(_ nonce: String, on html: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: "<script(?=[\\s>/])", options: [.caseInsensitive])
        else { return html }
        let range = NSRange(html.startIndex..., in: html)
        return pattern.stringByReplacingMatches(
            in: html,
            range: range,
            withTemplate: "<script nonce=\"\(nonce)\""
        )
    }

    /// JSON that cannot close the `<script>` element it sits in. `\u003c` is the
    /// same character to a JSON parser and is not `<` to an HTML one.
    static func scriptSafe(_ json: String) -> String {
        json.replacingOccurrences(of: "<", with: "\\u003c")
    }

    static func strippingDoctype(_ html: String) -> String {
        var rest = Substring(html)
        while let first = rest.first, first.isWhitespace || first == "\u{FEFF}" { rest = rest.dropFirst() }
        if rest.prefix(9).lowercased() == "<!doctype", let end = rest.firstIndex(of: ">") {
            rest = rest[rest.index(after: end)...]
        }
        return String(rest)
    }

    // MARK: - Navigation

    public enum Navigation: Equatable, Sendable {
        case allow
        /// A link to something the app was given: open it beside the app.
        case openInNewTab(URL)
        /// A link the app made up. Shown to the user, in full, before it opens.
        case confirm(URL)
        case cancel
    }

    /// Whether a top-level navigation from an app may happen.
    ///
    /// A click is *not* proof of a user: WebKit reports a script's `a.click()` as
    /// `.linkActivated` (verified on macOS 26), so an app could build
    /// `https://evil/?d=<library>` and "click" it. What an app cannot fake is
    /// which URLs it was handed. So a link opens only if it is one of them
    /// (``LinkAllowance``) — a record's own page, one of its links, or the site's
    /// own engage-with-this-record page. Anything else the app constructed is put
    /// in front of the user to approve, with the whole URL visible.
    ///
    /// - Parameter isLinkActivation: `navigationType == .linkActivated`. Without
    ///   it — `location = …`, a meta refresh, `window.open` — nothing opens at all.
    public static func decide(
        target: URL,
        appID: String,
        isLinkActivation: Bool,
        allowance: LinkAllowance
    ) -> Navigation {
        let scheme = target.scheme?.lowercased()
        if scheme == Self.scheme {
            return target.host() == appID ? .allow : .cancel
        }
        guard scheme == "https" || scheme == "http", isLinkActivation else {
            // `about:blank`, `data:`, `blob:`, `javascript:`, and every navigation
            // that was not a link: none is a place an app has reason to go.
            return .cancel
        }
        return allowance.allows(target) ? .openInNewTab(target) : .confirm(target)
    }

    /// The URLs an app has been given, and so may open without asking.
    public struct LinkAllowance: Sendable, Equatable {
        private(set) var urls: Set<String> = []
        /// `origin id` of every record served, for the site's own intent pages.
        private(set) var records: Set<String> = []

        public init() {}

        /// Remember what a query returned.
        public mutating func note(_ served: [SourceRecord]) {
            for record in served {
                if let url = record.url { urls.insert(Self.normalised(url)) }
                for link in record.links { urls.insert(Self.normalised(link)) }
                records.insert("\(record.source) \(record.id)")
            }
        }

        public func allows(_ url: URL) -> Bool {
            urls.contains(Self.normalised(url.absoluteString)) || isIntent(url)
        }

        /// X's own reply / like / repost pages, for a record this app was given.
        /// The query may carry only the record's id — `text=` would let an app
        /// pre-fill a public post with whatever it liked.
        func isIntent(_ url: URL) -> Bool {
            guard let host = url.host()?.lowercased(), host == "x.com" || host == "twitter.com",
                ["/intent/post", "/intent/tweet", "/intent/like", "/intent/retweet"].contains(url.path()),
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                items.count == 1, let item = items.first,
                item.name == "in_reply_to" || item.name == "tweet_id", let id = item.value
            else { return false }
            return records.contains("https://x.com \(id)") || records.contains("https://twitter.com \(id)")
        }

        static func normalised(_ string: String) -> String {
            guard var components = URLComponents(string: string) else { return string }
            components.fragment = nil
            components.host = components.host?.lowercased()
            return components.string ?? string
        }
    }

    // MARK: - Records as an app sees them

    /// Records with every remote URL an app could load replaced by its cached
    /// copy, or removed. ``SourceRecord/url`` stays: it is a link, and links only go
    /// anywhere when clicked.
    public static func exposed(_ records: [SourceRecord], cachedKeys: [String: String], appID: String) -> [SourceRecord] {
        func local(_ remote: String) -> String? {
            cachedKeys[remote].map { "\(scheme)://\(appID)/media/\($0)" }
        }
        return records.map { record in
            var copy = record
            copy.authorAvatar = record.authorAvatar.flatMap(local)
            copy.media = record.media.compactMap(local)
            return copy
        }
    }
}
