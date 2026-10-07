import CryptoKit
import Foundation

/// Where Zentic keeps everything it writes.
///
/// Normally `~/Library/Application Support/Zentic`. Setting `ZENTIC_DATA_DIR`
/// moves all of it — files, preferences, cookies, API keys, the blocker's compiled
/// lists and downloads — somewhere else, so a test run or a second copy of the app
/// can never read or overwrite the data of the copy someone is actually browsing with.
public enum DataDirectory {
    public static let environmentKey = "ZENTIC_DATA_DIR"

    /// Resolved once: every store must agree on it for the life of the process.
    public static let root: URL = resolve(ProcessInfo.processInfo.environment, testRun: TestRun.isActive)

    /// Whether `ZENTIC_DATA_DIR`, or being a test run, redirected the data.
    public static let isIsolated = override(in: ProcessInfo.processInfo.environment, testRun: TestRun.isActive) != nil

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

    /// Names the stores Zentic cannot place on disk itself: the isolated
    /// `WKWebsiteDataStore` (cookies, site storage) and the Keychain service for
    /// API keys. Derived from the path, so relaunching on the same directory finds
    /// the same cookies and key.
    public static var isolationID: UUID { storeID(for: root) }

    static func resolve(_ environment: [String: String], testRun: Bool = false) -> URL {
        if let path = override(in: environment, testRun: testRun) {
            return URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        }
        return URL.applicationSupportDirectory.appending(path: "Zentic", directoryHint: .isDirectory)
    }

    static func override(in environment: [String: String], testRun: Bool = false) -> String? {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            // A plain `swift test` sets nothing, and must still never read or
            // write the data of the copy someone is browsing with. One
            // directory per process: test runs in other checkouts may be going
            // at the same time.
            return testRun ? FileManager.default.temporaryDirectory.appending(path: "zentic-tests-\(getpid())").path : nil
        }
        return (raw as NSString).expandingTildeInPath
    }

    static func storeID(for directory: URL) -> UUID {
        let digest = Array(SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }
}
