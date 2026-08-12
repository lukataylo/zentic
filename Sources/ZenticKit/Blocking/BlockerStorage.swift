import CryptoKit
import Foundation

/// What the blocker remembers between launches.
///
/// Three kinds of state, all derived and all disposable: a manifest naming the
/// compiled lists WebKit is holding for us, the filter-list text those lists were
/// built from, and the user's per-origin shields. Only the shields matter — losing
/// them loses a decision the user made, so they are written on every change; the
/// rest can be thrown away and rebuilt.
struct BlockerStorage: Sendable {
    let directory: URL

    /// Default location. `nil` from the caller means "the real one"; tests pass a
    /// temporary directory so runs cannot see each other's caches.
    static func applicationSupport() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
        return base.appending(path: "Zentic/Blocking", directoryHint: .isDirectory)
    }

    var manifestURL: URL { directory.appending(path: "manifest.json") }
    var shieldsURL: URL { directory.appending(path: "shields.json") }
    var snapshotsDirectory: URL {
        directory.appending(path: "snapshots", directoryHint: .isDirectory)
    }

    /// Directory backing the `WKContentRuleListStore`, kept next to the manifest so
    /// the two can never be wiped independently and disagree.
    var ruleListStoreURL: URL {
        directory.appending(path: "compiled", directoryHint: .isDirectory)
    }

    func snapshotURL(for listID: String) -> URL {
        // List ids come from our own catalog, but a user-added list could contain a
        // slash and escape the directory.
        let safe = listID.replacingOccurrences(
            of: "/",
            with: "_"
        ).replacingOccurrences(of: "..", with: "_")
        return snapshotsDirectory.appending(path: "\(safe).txt")
    }

    func createDirectories() throws {
        for url in [directory, snapshotsDirectory, ruleListStoreURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - Manifest

    func readManifest() -> BlockerManifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        guard
            let manifest = try? JSONDecoder.zenticBlocking.decode(BlockerManifest.self, from: data)
        else { return nil }
        // A schema bump discards rather than migrates: everything here is derived
        // from filter-list text we still have, and a misread manifest would point at
        // compiled lists whose contents we can no longer describe.
        guard manifest.schemaVersion == BlockerLimits.cacheSchemaVersion else { return nil }
        return manifest
    }

    func write(_ manifest: BlockerManifest) throws {
        try createDirectories()
        try writeAtomically(try JSONEncoder.zenticBlocking.encode(manifest), to: manifestURL)
    }

    // MARK: - Snapshots

    func readSnapshot(for listID: String) -> String? {
        try? String(contentsOf: snapshotURL(for: listID), encoding: .utf8)
    }

    func writeSnapshot(_ text: String, for listID: String) throws {
        try createDirectories()
        try writeAtomically(Data(text.utf8), to: snapshotURL(for: listID))
    }

    // MARK: - Shields

    func readShields() -> [String: ShieldState] {
        guard let data = try? Data(contentsOf: shieldsURL),
            let shields = try? JSONDecoder.zenticBlocking.decode(
                [String: ShieldState].self,
                from: data
            )
        else { return [:] }
        return shields
    }

    func write(shields: [String: ShieldState]) throws {
        try createDirectories()
        try writeAtomically(try JSONEncoder.zenticBlocking.encode(shields), to: shieldsURL)
    }

    /// Write to a sibling then rename, so a crash mid-write cannot leave a
    /// half-written manifest that reads as "no cache" on the next launch.
    private func writeAtomically(_ data: Data, to url: URL) throws {
        let temporary = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: temporary)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}

/// Names the compiled lists WebKit is holding for us, and what they were built from.
struct BlockerManifest: Codable, Sendable, Hashable {
    var schemaVersion: Int = BlockerLimits.cacheSchemaVersion
    var lists: [Entry] = []

    struct Entry: Codable, Sendable, Hashable {
        var id: String
        var title: String
        /// Nil for the bundled seed, which is never fetched.
        var sourceURL: URL?
        var etag: String?
        /// SHA-256 of the filter-list text. The gate on reconverting: an ETag can
        /// change when the content did not, and conversion is the slow half.
        var contentHash: String
        var fetchedAt: Date
        var sourceRuleCount: Int
        var safariRuleCount: Int
        var droppedRuleCount: Int
        var ruleLists: [CompiledRef]
    }

    struct CompiledRef: Codable, Sendable, Hashable {
        var identifier: String
        var ruleClass: RuleClass
        var entryCount: Int
    }

    func entry(id: String) -> Entry? { lists.first { $0.id == id } }

    var identifiers: Set<String> {
        Set(lists.flatMap { $0.ruleLists.map(\.identifier) })
    }
}

enum ContentHash {
    static func of(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension JSONEncoder {
    fileprivate static var zenticBlocking: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var zenticBlocking: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
