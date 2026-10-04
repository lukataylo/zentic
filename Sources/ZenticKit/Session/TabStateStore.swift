import Foundation

/// Each tab's back/forward list, scroll position and form state
/// (`WKWebView.interactionState`), one small file per tab, so a relaunch puts
/// pages back where they were rather than just at the right address.
///
/// An actor so every read and write happens off the main thread. Files are
/// named by tab id and removed when the tab closes; anything left over (a
/// crash between a close and its removal) is pruned against the session at
/// launch.
public actor TabStateStore {
    public nonisolated let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func write(_ state: Data, for id: UUID) {
        Self.write(state, to: url(for: id), directory: directory)
    }

    /// For app termination, when there is no later to defer to.
    public nonisolated func writeNow(_ state: Data, for id: UUID) {
        Self.write(state, to: url(for: id), directory: directory)
    }

    public func read(_ id: UUID) -> Data? {
        try? Data(contentsOf: url(for: id))
    }

    public func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Delete the state of every tab not in `ids`.
    public func prune(keeping ids: Set<UUID>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == Self.fileExtension {
            let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
            if id == nil || !ids.contains(id!) { try? FileManager.default.removeItem(at: file) }
        }
    }

    private static let fileExtension = "state"

    private nonisolated func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(Self.fileExtension)
    }

    private static func write(_ state: Data, to url: URL, directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? state.write(to: url, options: .atomic)
    }
}
