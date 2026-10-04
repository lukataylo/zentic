import WebKit
import ZenticKit

extension WKWebsiteDataStore {
    /// Cookies and site storage for every tab. One instance, because two stores
    /// with the same identifier are not guaranteed to share in-memory state.
    /// When `ZENTIC_DATA_DIR` isolates the app, the user's real cookies are left
    /// alone — see ``DataDirectory``.
    @MainActor static let zentic: WKWebsiteDataStore =
        DataDirectory.isIsolated ? WKWebsiteDataStore(forIdentifier: DataDirectory.websiteDataStoreID) : .default()
}
