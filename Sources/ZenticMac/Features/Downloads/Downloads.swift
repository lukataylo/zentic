import AppKit
import Observation
import Synchronization
import WebKit
import ZenticKit

/// Every download, current and past. Files land in ~/Downloads (or the
/// isolated data directory), the way Safari's do.
///
/// Past downloads are kept in `downloads.json` — except a private window's,
/// which are listed only in private windows and forgotten at quit.
@MainActor
@Observable
final class Downloads {
    static let shared = Downloads()

    /// Newest first.
    private(set) var items: [Download] = []
    /// The window whose toolbar is showing the downloads popover.
    var presentedIn: UUID?

    @ObservationIgnored private var byTask: [ObjectIdentifier: Download] = [:]
    @ObservationIgnored private let delegate = DownloadDelegate()
    @ObservationIgnored private let file = JSONFile<[Download.Record]>(name: "downloads.json")
    @ObservationIgnored private let io = DispatchQueue(label: "Zentic.downloads", qos: .utility)
    @ObservationIgnored private var loaded = false

    static let keptLimit = 100

    private init() {
        let file = self.file
        Task {
            let records = await Task.detached(priority: .utility) { file.load() ?? [] }.value
            // Anything that started before the list was read stays on top.
            let known = Set(items.map(\.id))
            items += records.filter { !known.contains($0.id) }.map(Download.init(record:))
            loaded = true
        }
    }

    /// Items a window lists: a private window's own, or everyone else's.
    func items(private isPrivate: Bool) -> [Download] {
        items.filter { $0.isPrivate == isPrivate }
    }

    /// Whether a window's toolbar shows the downloads button: while something
    /// is downloading, or once something has finished this session, until the
    /// list is cleared.
    func showsButton(private isPrivate: Bool) -> Bool {
        items.contains { $0.isPrivate == isPrivate && ($0.isRecent || $0.state.isUnderway) }
    }

    // MARK: - From WebKit

    /// A navigation became a download.
    func adopt(_ task: WKDownload, isPrivate: Bool) {
        task.delegate = delegate
        let item = Download(
            name: "", file: nil, source: task.originalRequest?.url, isPrivate: isPrivate)
        item.attach(task)
        byTask[ObjectIdentifier(task)] = item
        items.insert(item, at: 0)
        // The ring appears as the download starts, with no popover in the way.
    }

    fileprivate func destination(for task: WKDownload, suggested: String) -> URL? {
        guard let item = byTask[ObjectIdentifier(task)] else { return nil }
        // A retry goes back to the file it was always going to be. Starting
        // over replaces the partial file; carrying on must leave it alone.
        // But only our own partial: whatever else is at that name now is the
        // user's, and the restart gets a name of its own instead.
        if let file = item.file {
            if item.isResuming { return file }
            if holdsOwnPartial(item) {
                try? FileManager.default.removeItem(at: file)
                return file
            }
            if !FileManager.default.fileExists(atPath: file.path) { return file }
            item.file = nil
        }
        let folder = DataDirectory.downloads
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Another download may have claimed a name without having written
        // its file yet; two that share one would collide.
        let claimed = Set(items.compactMap(\.file))
        let url = DownloadName.unused(for: suggested, in: folder) {
            claimed.contains($0) || FileManager.default.fileExists(atPath: $0.path)
        }
        item.file = url
        item.name = url.lastPathComponent
        item.wroteFile = true
        // Saved now, as interrupted until it ends: quitting mid-download
        // must still leave it in the list, ready to try again.
        save()
        return url
    }

    fileprivate func finished(_ task: WKDownload) {
        guard let item = byTask.removeValue(forKey: ObjectIdentifier(task)) else { return }
        item.finish()
        forgetPrivateIfClosed(item)
        // Bounces the Downloads stack in the Dock, as Safari's downloads do.
        if let path = item.file?.path {
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: path)
        }
        save()
    }

    fileprivate func failed(_ task: WKDownload, error: Error, resumeData: Data?) {
        guard let item = byTask.removeValue(forKey: ObjectIdentifier(task)) else { return }
        item.stopped = .now
        item.fail(error, resumeData: resumeData)
        forgetPrivateIfClosed(item)
        save()
    }

    // MARK: - Actions

    /// Stop, keeping what has arrived so it can carry on later.
    func pause(_ item: Download) {
        guard let task = item.task else { return }
        item.state = .pausing
        task.cancel { [weak self, weak item] data in
            MainActor.assumeIsolated {
                // Cancelled, or finished, while the pause was on its way: that
                // outcome stands.
                guard let self, let item, item.state == .pausing else { return }
                self.byTask[ObjectIdentifier(task)] = nil
                item.stopped = .now
                item.paused(resumeData: data)
                self.save()
            }
        }
    }

    /// Carry on from where it stopped if WebKit can; otherwise start again.
    func resume(_ item: Download) {
        guard !item.state.isUnderway else { return }
        let webView = host(for: item)
        let begin: @MainActor @Sendable (WKDownload) -> Void = { [weak self, weak item] task in
            guard let self, let item else { return task.cancel() }
            task.delegate = self.delegate
            item.attach(task)
            self.byTask[ObjectIdentifier(task)] = item
        }
        item.state = .active
        if let data = item.resumeData {
            item.resumeData = nil
            item.isResuming = true
            webView.resumeDownload(fromResumeData: data, completionHandler: begin)
        } else if let source = item.source {
            item.isResuming = false
            item.restart()
            webView.startDownload(using: URLRequest(url: source), completionHandler: begin)
        } else {
            item.state = .failed("This download can’t be restarted.")
        }
    }

    /// Whether the file at `item.file` is still what this download wrote: it
    /// chose that path this session and the file has not changed since the
    /// download stopped. After a relaunch, or once anything else has written
    /// there (the user saving a file of the same name from Mail), it is not.
    private func holdsOwnPartial(_ item: Download) -> Bool {
        guard item.wroteFile, let file = item.file, let stopped = item.stopped,
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return false }
        return modified <= stopped.addingTimeInterval(2)
    }

    /// Stop for good, and remove what had arrived — if it is still ours.
    func cancel(_ item: Download) {
        let underway = item.task != nil
        let partial = item.state == .finished || !(underway || holdsOwnPartial(item)) ? nil : item.file
        if let task = item.task {
            byTask[ObjectIdentifier(task)] = nil
            task.cancel()
        }
        item.cancelled()
        if let partial { io.async { try? FileManager.default.removeItem(at: partial) } }
        save()
    }

    func remove(_ item: Download) {
        guard !item.state.isUnderway else { return }
        items.removeAll { $0 === item }
        save()
    }

    /// Forget what has ended — finished, failed or cancelled — in this kind
    /// of window. The files stay where they are.
    func clear(private isPrivate: Bool) {
        items.removeAll { $0.isPrivate == isPrivate && !$0.state.isUnderway && $0.state != .paused }
        save()
    }

    /// The last private window closed: what it downloaded is forgotten with
    /// it, as its pages are. Transfers still running carry on and are
    /// forgotten when they end.
    func forgetPrivate() {
        items.removeAll { $0.isPrivate && !$0.state.isUnderway }
    }

    private func forgetPrivateIfClosed(_ item: Download) {
        if item.isPrivate, !Windows.shared.hasPrivateWindow { items.removeAll { $0 === item } }
    }

    func reveal(_ item: Download) {
        guard let file = item.file else { return }
        checkingFile(item) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }

    func open(_ item: Download) {
        guard item.state == .finished, let file = item.file else { return }
        checkingFile(item) { NSWorkspace.shared.open(file) }
    }

    /// Run `action` if the file is still there; otherwise say it was moved.
    /// Checked off the main thread, only when asked — never per row drawn.
    private func checkingFile(_ item: Download, _ action: @escaping @MainActor () -> Void) {
        guard let file = item.file else { return }
        Task {
            let exists = await Task.detached { FileManager.default.fileExists(atPath: file.path) }.value
            item.isMissing = !exists
            if exists { action() } else { NSSound.beep() }
        }
    }

    // MARK: - Hosting

    /// Resuming or restarting needs a web view. The tab that started the
    /// download may be closed by now, so a hidden one is made in the right
    /// website data store: the user's cookies, or the private window's.
    private func host(for item: Download) -> WKWebView {
        if let webView = item.host { return webView }
        let configuration = WKWebViewConfiguration()
        // A private download never goes near the user's own cookies.
        configuration.websiteDataStore = item.dataStore ?? (item.isPrivate ? .nonPersistent() : .zentic)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        item.host = webView
        return webView
    }

    // MARK: - Persistence

    private func save() {
        // Not before the old list is read, which would be overwritten.
        guard loaded else { return }
        let records = items.filter { !$0.isPrivate }.prefix(Self.keptLimit).map(\.record)
        let file = self.file
        io.async { file.save(Array(records)) }
    }
}

/// One download, observed on its own so its progress redraws only its row
/// and the toolbar ring.
@MainActor
@Observable
final class Download: Identifiable {
    enum State: Equatable {
        case active, pausing, paused, finished, cancelled
        case failed(String)

        /// Still has, or may yet have, a transfer of its own.
        var isUnderway: Bool { self == .active || self == .pausing }
    }

    let id: UUID
    var name: String
    var file: URL?
    let source: URL?
    let isPrivate: Bool
    let started: Date
    var state: State = .active
    private(set) var completedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    /// Bytes per second, smoothed — for "2 min left".
    private(set) var rate: Double = 0
    /// Finished this session: what keeps the toolbar button up.
    private(set) var isRecent = false
    /// The file was moved or deleted since it downloaded.
    var isMissing = false

    @ObservationIgnored fileprivate(set) var task: WKDownload?
    @ObservationIgnored fileprivate var resumeData: Data?
    @ObservationIgnored fileprivate var isResuming = false
    /// This session chose `file` for it — see `Downloads.holdsOwnPartial`.
    @ObservationIgnored fileprivate var wroteFile = false
    /// When its transfer last stopped (failed or paused).
    @ObservationIgnored fileprivate var stopped: Date?
    @ObservationIgnored fileprivate var host: WKWebView?
    @ObservationIgnored fileprivate var dataStore: WKWebsiteDataStore?
    @ObservationIgnored private var progressObservation: NSKeyValueObservation?
    @ObservationIgnored private var lastSample: (date: Date, bytes: Int64)?

    var fraction: Double? {
        totalBytes > 0 ? min(Double(completedBytes) / Double(totalBytes), 1) : nil
    }

    var canResume: Bool { state == .paused || (state.isFailed && (resumeData != nil || source != nil)) }

    fileprivate init(name: String, file: URL?, source: URL?, isPrivate: Bool) {
        id = UUID()
        self.name = name
        self.file = file
        self.source = source
        self.isPrivate = isPrivate
        started = .now
    }

    fileprivate init(record: Record) {
        id = record.id
        name = record.name
        file = record.file
        source = record.source
        isPrivate = false
        started = record.started
        totalBytes = record.bytes
        completedBytes = record.outcome == .finished ? record.bytes : 0
        state =
            switch record.outcome {
            case .finished: .finished
            case .cancelled: .cancelled
            case .failed: .failed("Couldn’t finish")
            // Zentic quit while it was downloading.
            case .interrupted: .failed("Interrupted")
            }
    }

    fileprivate func attach(_ task: WKDownload) {
        self.task = task
        dataStore = task.webView?.configuration.websiteDataStore ?? dataStore
        state = .active
        lastSample = nil
        watch(task.progress)
    }

    /// WebKit reports progress for every chunk — hundreds of times a second
    /// on a fast line. Coalesced to ten updates a second on the main thread.
    private func watch(_ progress: Progress) {
        let pending = Mutex(false)
        progressObservation = progress.observe(\.completedUnitCount, options: [.initial]) { [weak self] _, _ in
            let schedule = pending.withLock { scheduled in
                defer { scheduled = true }
                return !scheduled
            }
            guard schedule else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                pending.withLock { $0 = false }
                MainActor.assumeIsolated {
                    if let progress = self?.task?.progress { self?.sample(progress) }
                }
            }
        }
    }

    private func sample(_ progress: Progress) {
        let now = Date.now
        completedBytes = progress.completedUnitCount
        totalBytes = max(progress.totalUnitCount, 0)
        if let last = lastSample, now.timeIntervalSince(last.date) > 0.05 {
            let instant = Double(completedBytes - last.bytes) / now.timeIntervalSince(last.date)
            rate = rate == 0 ? instant : rate * 0.8 + instant * 0.2
        }
        lastSample = (now, completedBytes)
    }

    fileprivate func finish() {
        stopWatching()
        if totalBytes <= 0 { totalBytes = completedBytes }
        completedBytes = totalBytes
        state = .finished
        isRecent = true
        host = nil
        dataStore = nil
    }

    fileprivate func fail(_ error: Error, resumeData: Data?) {
        // Pausing cancels the transfer, and WebKit reports that as a failure.
        guard state != .pausing, state != .cancelled else { return }
        stopWatching()
        self.resumeData = resumeData
        let ns = error as NSError
        state = .failed(ns.code == NSURLErrorCancelled ? "Stopped" : ns.localizedDescription)
        isRecent = true
    }

    fileprivate func paused(resumeData: Data?) {
        stopWatching()
        self.resumeData = resumeData
        state = .paused
    }

    fileprivate func cancelled() {
        stopWatching()
        resumeData = nil
        host = nil
        // `dataStore` stays: Try Again must start over in the same store.
        state = .cancelled
        isRecent = true
    }

    fileprivate func restart() {
        completedBytes = 0
        rate = 0
    }

    private func stopWatching() {
        progressObservation = nil
        if let task { sample(task.progress) }
        task = nil
        rate = 0
    }

    // MARK: Saved

    struct Record: Codable, Sendable {
        enum Outcome: String, Codable { case finished, failed, cancelled, interrupted }
        var id: UUID
        var name: String
        var file: URL?
        var source: URL?
        var started: Date
        var bytes: Int64
        var outcome: Outcome
    }

    var record: Record {
        let outcome: Record.Outcome =
            switch state {
            case .finished: .finished
            case .cancelled: .cancelled
            case .failed: .failed
            case .active, .pausing, .paused: .interrupted
            }
        return Record(
            id: id, name: name, file: file, source: source, started: started, bytes: totalBytes, outcome: outcome)
    }
}

extension Download.State {
    var isFailed: Bool { if case .failed = self { true } else { false } }
}

/// WebKit's download callbacks, kept off `Downloads` so a `WKDownload` never
/// retains the model.
@MainActor
private final class DownloadDelegate: NSObject, WKDownloadDelegate {
    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String
    ) async -> URL? {
        Downloads.shared.destination(for: download, suggested: suggestedFilename)
    }

    func downloadDidFinish(_ download: WKDownload) { Downloads.shared.finished(download) }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        Downloads.shared.failed(download, error: error, resumeData: resumeData)
    }
}
