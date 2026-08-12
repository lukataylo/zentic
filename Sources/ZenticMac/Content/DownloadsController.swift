import AppKit
import WebKit

/// Downloads: destination choice, progress, and a popover listing them.
///
/// Files land in `~/Downloads` under the server's suggested name, uniquified rather
/// than overwritten. No download manager, no resume, no queue — M1 needs a browser
/// that can save a file, not a download product.
@MainActor
final class DownloadsController: NSObject {
    struct Item: Identifiable {
        let id = UUID()
        var filename: String
        var destination: URL?
        var progress: Double
        var isFinished: Bool
        var error: String?
    }

    private(set) var items: [Item] = []
    /// Fired whenever `items` changes, so the toolbar can reveal its button.
    var onChange: (() -> Void)?

    private var indexByDownload: [ObjectIdentifier: UUID] = [:]
    private var observations: [ObjectIdentifier: NSKeyValueObservation] = [:]

    func attach(_ download: WKDownload) {
        download.delegate = self
        let item = Item(
            filename: download.originalRequest?.url?.lastPathComponent ?? "download",
            destination: nil,
            progress: 0,
            isFinished: false
        )
        items.append(item)
        indexByDownload[ObjectIdentifier(download)] = item.id
        observe(download, id: item.id)
        onChange?()
        trace("downloads", "started \(item.filename)")
    }

    private func observe(_ download: WKDownload, id: UUID) {
        // `WKDownload.progress` is a plain Foundation Progress with no delegate
        // callbacks, so KVO is the only way to drive a progress bar.
        let observation = download.progress.observe(\.fractionCompleted, options: [.new]) {
            [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                self?.update(id: id) { $0.progress = fraction }
            }
        }
        observations[ObjectIdentifier(download)] = observation
    }

    private func update(id: UUID, _ mutate: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[index])
        onChange?()
    }

    private func finish(_ download: WKDownload, error: String?) {
        let key = ObjectIdentifier(download)
        observations[key]?.invalidate()
        observations[key] = nil
        guard let id = indexByDownload.removeValue(forKey: key) else { return }
        update(id: id) {
            $0.isFinished = true
            $0.error = error
            if error == nil { $0.progress = 1 }
        }
        trace("downloads", "finished \(id) error=\(error ?? "none")")
    }

    /// A non-colliding path in `~/Downloads`.
    private static func destination(for suggested: String) -> URL {
        let directory = URL.downloadsDirectory
        var candidate = directory.appending(path: suggested)
        var counter = 2
        let stem = candidate.deletingPathExtension().lastPathComponent
        let extensionName = candidate.pathExtension

        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            let name = extensionName.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(extensionName)"
            candidate = directory.appending(path: name)
            counter += 1
        }
        return candidate
    }

    // MARK: - Popover

    private var popover: NSPopover?

    func showPopover(relativeTo view: NSView) {
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = DownloadsListViewController(items: items)
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        self.popover = popover
    }
}

extension DownloadsController: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        let destination = Self.destination(for: suggestedFilename)
        if let id = indexByDownload[ObjectIdentifier(download)] {
            update(id: id) {
                $0.filename = destination.lastPathComponent
                $0.destination = destination
            }
        }
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        finish(download, error: nil)
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        finish(download, error: error.localizedDescription)
    }
}

/// Popover contents: one row per download.
private final class DownloadsListViewController: NSViewController {
    private let items: [DownloadsController.Item]

    init(items: [DownloadsController.Item]) {
        self.items = items
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        if items.isEmpty {
            let label = NSTextField(labelWithString: "No downloads")
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12)
            stack.addView(label, in: .top)
        }

        for item in items.reversed() {
            let title = NSTextField(labelWithString: item.filename)
            title.font = .systemFont(ofSize: 12, weight: .medium)
            title.lineBreakMode = .byTruncatingMiddle

            let detail: String =
                if let error = item.error {
                    "Failed — \(error)"
                } else if item.isFinished {
                    item.destination?.deletingLastPathComponent().lastPathComponent ?? "Done"
                } else {
                    "\(Int(item.progress * 100))%"
                }
            let subtitle = NSTextField(labelWithString: detail)
            subtitle.font = .systemFont(ofSize: 10.5)
            subtitle.textColor = item.error == nil ? .secondaryLabelColor : .systemRed

            let row = NSStackView(views: [title, subtitle])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 1
            stack.addView(row, in: .top)
        }

        stack.widthAnchor.constraint(equalToConstant: 280).isActive = true
        view = stack
    }
}
