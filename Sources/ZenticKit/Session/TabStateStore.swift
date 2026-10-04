import Foundation

/// Each tab's back/forward list, scroll position and form state
/// (`WKWebView.interactionState`), one small file per tab, so a relaunch puts
/// pages back where they were rather than just at the right address.
///
/// Every read and write runs off the main thread on one serial queue, so they
/// happen in the order they were asked for: a tab closed right after a page
/// finished loading has its file removed *after* that page's state was
/// written, never before (which would leave the stale file behind). Files are
/// named by tab id; anything left over by a crash is pruned at launch.
public final class TabStateStore: Sendable {
    public let directory: URL
    private let queue = DispatchQueue(label: "Zentic.TabStateStore", qos: .utility)

    public init(directory: URL) {
        self.directory = directory
    }

    public func write(_ state: Data, for id: UUID) {
        queue.async { [self] in store(state, for: id) }
    }

    /// For app termination, when there is no later to defer to. Lands after
    /// anything already queued.
    public func writeNow(_ state: Data, for id: UUID) {
        queue.sync { store(state, for: id) }
    }

    /// Reads after every write and removal asked for before it.
    public func read(_ id: UUID) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: try? Data(contentsOf: url(for: id))) }
        }
    }

    public func remove(_ id: UUID) {
        queue.async { [self] in try? FileManager.default.removeItem(at: url(for: id)) }
    }

    /// Delete the state of every tab not in `ids`.
    public func prune(keeping ids: Set<UUID>) {
        queue.async { [self] in
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == Self.fileExtension {
                let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
                if id.map({ !ids.contains($0) }) ?? true { try? FileManager.default.removeItem(at: file) }
            }
        }
    }

    private static let fileExtension = "state"

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(Self.fileExtension)
    }

    private func store(_ state: Data, for id: UUID) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? state.write(to: url(for: id), options: .atomic)
    }
}
