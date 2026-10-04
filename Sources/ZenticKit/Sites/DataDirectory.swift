import CryptoKit
import Foundation

/// Where Zentic keeps everything it writes.
///
/// Normally `~/Library/Application Support/Zentic`. Setting `ZENTIC_DATA_DIR`
/// moves all of it — files, preferences, cookies, the blocker's compiled lists and
/// downloads — somewhere else, so a test run or a second copy of the app can
/// never read or overwrite the data of the copy someone is actually browsing with.
public enum DataDirectory {
    public static let environmentKey = "ZENTIC_DATA_DIR"

    /// Resolved once: every store must agree on it for the life of the process.
    public static let root: URL = resolve(ProcessInfo.processInfo.environment)

    /// Whether `ZENTIC_DATA_DIR` redirected the data.
    public static let isIsolated = override(in: ProcessInfo.processInfo.environment) != nil

    /// Preferences. `UserDefaults.standard` would write to the user's real
    /// domain even when isolated, so code reads and writes this instead. An
    /// absolute suite name is a plist at that path (without its extension).
    /// `UserDefaults` is documented as thread-safe; it is just not `Sendable`.
    nonisolated(unsafe) public static let defaults: UserDefaults =
        isIsolated
        ? UserDefaults(suiteName: root.appending(path: "Preferences").path) ?? .standard
        : .standard

    /// Where downloads land: the user's Downloads folder, unless isolated.
    public static var downloads: URL {
        isIsolated
            ? root.appending(path: "Downloads", directoryHint: .isDirectory)
            : URL.downloadsDirectory
    }

    /// The identifier of the isolated `WKWebsiteDataStore`, so cookies and site
    /// storage are kept apart too. WebKit decides where that store lives on
    /// disk, so the best we can do is a store of our own: derived from the path,
    /// relaunching on the same directory finds the same cookies.
    public static var websiteDataStoreID: UUID { storeID(for: root) }

    static func resolve(_ environment: [String: String]) -> URL {
        if let path = override(in: environment) {
            return URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        }
        return URL.applicationSupportDirectory.appending(path: "Zentic", directoryHint: .isDirectory)
    }

    static func override(in environment: [String: String]) -> String? {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return nil }
        return (raw as NSString).expandingTildeInPath
    }

    static func storeID(for directory: URL) -> UUID {
        let digest = Array(SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }
}
