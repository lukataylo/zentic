import Foundation

/// A Codable value persisted as one JSON file in Application Support.
///
/// Writes are atomic (`.atomic` writes to a temporary file and renames), so a
/// crash mid-save leaves the previous file intact rather than half of a new one.
public struct JSONFile<Value: Codable & Sendable>: Sendable {
    public let url: URL

    public init(name: String, directory: URL = JSONFile.defaultDirectory) {
        self.url = directory.appendingPathComponent(name)
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Zentic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    public func save(_ value: Value) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
