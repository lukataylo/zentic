import AppKit
import Observation
import WebKit
import ZenticKit

/// Saves downloads to ~/Downloads (or the isolated data directory), the way
/// Safari does, and says so.
@MainActor
@Observable
final class Downloads {
    static let shared = Downloads()

    struct Item: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var url: URL
        var finished = false
        var failed: String?
    }

    /// The most recent download, for the toast.
    private(set) var latest: Item?
    @ObservationIgnored private var destinations: [ObjectIdentifier: Item] = [:]
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func destination(for suggested: String, download: WKDownload) -> URL {
        let folder = DataDirectory.downloads
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = suggested.isEmpty ? "download" : suggested
        var url = folder.appendingPathComponent(name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        let item = Item(name: url.lastPathComponent, url: url)
        destinations[ObjectIdentifier(download)] = item
        show(item)
        return url
    }

    func finished(_ download: WKDownload) {
        guard var item = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        item.finished = true
        show(item)
        // Bounces the Downloads stack in the Dock, as Safari's downloads do.
        DistributedNotificationCenter.default().post(
            name: .init("com.apple.DownloadFileFinished"), object: item.url.path)
    }

    func failed(_ download: WKDownload, error: Error) {
        guard var item = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        item.failed = error.localizedDescription
        show(item)
    }

    func reveal(_ item: Item) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
        dismiss()
    }

    func dismiss() {
        latest = nil
    }

    private func show(_ item: Item) {
        latest = item
        dismissTask?.cancel()
        guard item.finished || item.failed != nil else { return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.latest = nil
        }
    }
}
