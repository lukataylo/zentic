import Network
import WebKit
import ZenticKit

/// The engine-level half of the app sandbox: what a generated app's web view is
/// built with, before any page exists.
///
/// CSP and the navigation policy govern what a page *asks* for. These govern what
/// the engine will do whatever the page asks, for the channels CSP does not
/// cover:
///
/// - **A dead proxy.** App tabs get their own website data store whose every
///   HTTP(S) connection goes through a proxy at `127.0.0.1:9`, where nothing
///   listens. A preconnect, a DNS prefetch, a ping — anything WebKit would have
///   resolved or opened for the page — fails at the socket. `zentic://` is served
///   in-process and never touches it.
/// - **No peer connections.** WebRTC's ICE gathering sends UDP to STUN servers
///   (verified: a `srflx` candidate came back from an app page), and neither CSP
///   nor a proxy stops UDP. WebKit's `PeerConnectionEnabled` feature, switched
///   off, removes `RTCPeerConnection` from the page and from any `about:blank`
///   iframe it makes.
@MainActor
enum AppEnvironment {
    /// Persistent, shared by every app — each app is its own origin, so none sees
    /// another's storage — and kept with the rest of Zentic's data, so an isolated
    /// run gets its own.
    static let dataStore: WKWebsiteDataStore = sealed(
        WKWebsiteDataStore(forIdentifier: DataDirectory.storeID(named: "apps")))

    /// For an app opened in a private window: nothing written, still sealed.
    static func privateStore() -> WKWebsiteDataStore { sealed(.nonPersistent()) }

    private static func sealed(_ store: WKWebsiteDataStore) -> WKWebsiteDataStore {
        store.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: 9))]
        return store
    }

    /// Apply both to a configuration about to host an app. Returns whether peer
    /// connections are confirmed off; if this WebKit lacks the switch, the
    /// runtime's own fallback removes the constructors.
    @discardableResult
    static func seal(_ configuration: WKWebViewConfiguration, isPrivate: Bool) -> Bool {
        configuration.websiteDataStore = isPrivate ? privateStore() : dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Apps get no extensions: an extension's content script is code the app
        // sandbox never vetted, running in the app's page.
        configuration.webExtensionController = nil
        return disablePeerConnections(in: configuration.preferences)
    }

    /// `WKPreferences._setEnabled:forFeature:` on `PeerConnectionEnabled`. SPI, so
    /// every step is checked rather than assumed.
    private static func disablePeerConnections(in preferences: WKPreferences) -> Bool {
        let featuresSelector = NSSelectorFromString("_features")
        let setSelector = NSSelectorFromString("_setEnabled:forFeature:")
        guard (WKPreferences.self as AnyObject).responds(to: featuresSelector),
            preferences.responds(to: setSelector),
            let features = (WKPreferences.self as AnyObject).perform(featuresSelector)?
                .takeUnretainedValue() as? [NSObject],
            let feature = features.first(where: { ($0.value(forKey: "key") as? String) == "PeerConnectionEnabled" })
        else { return false }
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        let implementation = unsafeBitCast(preferences.method(for: setSelector), to: SetEnabled.self)
        implementation(preferences, setSelector, false, feature)
        return true
    }
}
