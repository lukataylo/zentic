import Foundation

/// A front-end the user prompted into existence over their library.
///
/// One HTML file per version, written by a model and run inside ``AppSandbox``.
/// Versions are kept, never overwritten: "make the headlines bigger" that comes
/// back worse must be one click from the version before it.
public struct GeneratedApp: Codable, Sendable, Hashable, Identifiable {
    /// 32 lowercase hex characters. Doubles as the app's URL host —
    /// `zentic://<id>/` — so every app is its own origin, with its own storage,
    /// and one app's page cannot read another's.
    public var id: String
    public var name: String
    /// An SF Symbol for the sidebar tile, chosen by the model and checked by the
    /// shell before use.
    public var symbol: String
    /// Origins the app may read. The scheme handler enforces this; the app's own
    /// queries cannot widen it.
    public var sources: [String]
    /// Every prompt, in order: the original request, then each revision.
    public var prompts: [String]
    /// Versions written so far, numbered from 1.
    public var versionCount: Int
    /// The version being shown.
    public var currentVersion: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = GeneratedApp.newID(),
        name: String,
        symbol: String,
        sources: [String],
        prompts: [String],
        versionCount: Int = 0,
        currentVersion: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.sources = sources
        self.prompts = prompts
        self.versionCount = versionCount
        self.currentVersion = currentVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func newID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public static func isValidID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Where the app lives. A pinned tab holding this URL *is* the app's tile.
    public var url: URL { URL(string: "zentic://\(id)/")! }

    /// The app an app URL names, if it names one.
    public static func id(from url: URL?) -> String? {
        guard let url, url.scheme == AppSandbox.scheme, let host = url.host(), isValidID(host)
        else { return nil }
        return host
    }
}

/// What a model returns when asked for an app.
public struct AppDraft: Codable, Sendable, Hashable {
    public var name: String
    public var symbol: String
    public var html: String

    public init(name: String, symbol: String, html: String) {
        self.name = name
        self.symbol = symbol
        self.html = html
    }
}

/// Generated apps on disk: `Apps/<id>/manifest.json` plus `v<n>.html`.
public actor AppStore {
    private let directory: URL
    private let encoder: JSONEncoder = {
        let encoder = LibraryCoding.encoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()
    private let decoder = LibraryCoding.decoder()

    public static var defaultDirectory: URL {
        DataDirectory.root.appending(path: "Apps", directoryHint: .isDirectory)
    }

    public init(directory: URL = AppStore.defaultDirectory) {
        self.directory = directory
    }

    public func all() -> [GeneratedApp] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return entries.filter(GeneratedApp.isValidID).compactMap(app(id:)).sorted { $0.createdAt < $1.createdAt }
    }

    public func app(id: String) -> GeneratedApp? {
        guard GeneratedApp.isValidID(id),
            let data = try? Data(contentsOf: folder(id).appending(path: "manifest.json"))
        else { return nil }
        return try? decoder.decode(GeneratedApp.self, from: data)
    }

    /// The HTML of the version being shown.
    public func html(id: String) -> String? {
        guard let app = app(id: id), app.currentVersion > 0 else { return nil }
        return try? String(contentsOf: folder(id).appending(path: "v\(app.currentVersion).html"), encoding: .utf8)
    }

    /// The HTML of a specific version, for revising from it.
    public func html(id: String, version: Int) -> String? {
        guard GeneratedApp.isValidID(id), version > 0 else { return nil }
        return try? String(contentsOf: folder(id).appending(path: "v\(version).html"), encoding: .utf8)
    }

    /// Write a new version and make it current.
    @discardableResult
    public func save(_ app: GeneratedApp, draft: AppDraft, prompt: String) throws -> GeneratedApp {
        var app = app
        let folder = folder(app.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        app.versionCount += 1
        app.currentVersion = app.versionCount
        app.name = draft.name
        app.symbol = draft.symbol
        if app.prompts.last != prompt { app.prompts.append(prompt) }
        app.updatedAt = .now
        try Data(draft.html.utf8).write(to: folder.appending(path: "v\(app.versionCount).html"), options: .atomic)
        try write(app)
        return app
    }

    /// Show an earlier version. The later ones stay on disk.
    public func setCurrentVersion(_ version: Int, id: String) throws -> GeneratedApp? {
        guard var app = app(id: id), (1...app.versionCount).contains(version) else { return nil }
        app.currentVersion = version
        app.updatedAt = .now
        try write(app)
        return app
    }

    /// The app's drawn icon, if one was made. A file beside the versions, not a
    /// manifest field, so manifests written before icons existed still read.
    public func icon(id: String) -> Data? {
        guard GeneratedApp.isValidID(id) else { return nil }
        return try? Data(contentsOf: folder(id).appending(path: "icon.png"))
    }

    public func saveIcon(_ png: Data, id: String) throws {
        guard GeneratedApp.isValidID(id) else { return }
        try png.write(to: folder(id).appending(path: "icon.png"), options: .atomic)
    }

    public func delete(id: String) {
        guard GeneratedApp.isValidID(id) else { return }
        try? FileManager.default.removeItem(at: folder(id))
    }

    private func write(_ app: GeneratedApp) throws {
        try encoder.encode(app).write(to: folder(app.id).appending(path: "manifest.json"), options: .atomic)
    }

    private func folder(_ id: String) -> URL {
        directory.appending(path: id, directoryHint: .isDirectory)
    }
}
