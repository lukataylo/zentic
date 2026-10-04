import AppKit
import MetricKit
import ZenticKit

/// Problem reports, kept on this Mac: what macOS's MetricKit delivers
/// (crashes, hangs, CPU and disk-write exceptions) and Zentic's own account
/// of a run that quit unexpectedly.
///
/// Nothing here is ever sent anywhere. A report leaves the Mac only when the
/// user copies, saves or emails it, one report at a time.
@MainActor
@Observable
final class Diagnostics {
    static let shared = Diagnostics()

    /// Where "Email to Developer…" addresses its draft.
    static let developerEmail = "luka.dadiani@me.com"

    /// Newest first. Nil until something shows them: there is no reason to
    /// read the folder on a launch where nobody looks.
    private(set) var reports: [ProblemReport]?
    /// The report about the previous run's unexpected quit, once written.
    private(set) var incident: ProblemReport?

    @ObservationIgnored private let store = ProblemReportStore(
        directory: DataDirectory.root.appending(path: "Diagnostics", directoryHint: .isDirectory))
    /// Every read and write of the folder, in order, off the main thread.
    @ObservationIgnored private let io = DispatchQueue(label: "Zentic.diagnostics", qos: .utility)
    @ObservationIgnored private var collector: MetricKitCollector?

    private init() {}

    /// At launch: write up the previous run if it quit unexpectedly, and
    /// listen for the diagnostics macOS collects.
    func start() {
        Breadcrumbs.note("Launched")
        let windows = Windows.shared
        if windows.launch != .clean { writeIncident(previousRun: windows.previousRun, launched: windows.previousLaunch) }
        // Off the launch path. MetricKit delivers when it has something,
        // which is never in the first seconds.
        Task {
            try? await Task.sleep(for: .seconds(10))
            let collector = MetricKitCollector()
            MXMetricManager.shared.add(collector)
            self.collector = collector
        }
    }

    func loadIfNeeded() {
        guard reports == nil else { return }
        let store = self.store
        io.async {
            // Age out what expired since the last report was written.
            store.prune()
            let all = store.all()
            Task { @MainActor in self.reports = all }
        }
    }

    func add(_ new: [ProblemReport]) {
        let store = self.store
        io.async {
            var existing = store.all()
            let added = new.filter { report in
                guard !existing.contains(where: report.isCovered(by:)) else { return false }
                existing.append(report)
                store.save(report)
                return true
            }
            guard !added.isEmpty else { return }
            Task { @MainActor in
                guard let current = self.reports else { return }
                self.reports = (current + added).sorted { $0.date > $1.date }
            }
        }
    }

    func delete(_ report: ProblemReport) {
        reports?.removeAll { $0.id == report.id }
        if incident?.id == report.id { incident = nil }
        let store = self.store
        io.async { store.delete(report.id) }
    }

    private func writeIncident(previousRun: Breadcrumb?, launched: Date?) {
        let process = ProcessInfo.processInfo.processName
        let store = self.store
        io.async {
            // Bounded by when that run launched: an older log is another crash.
            // Not tied to the breadcrumb, which a crash in the first second
            // never got to write.
            let log = launched.flatMap { SystemCrashLog.newest(for: process, since: $0) }
            let report = ProblemReport.unexpectedQuit(previousRun: previousRun, crashLog: log)
            store.save(report)
            Task { @MainActor in
                self.incident = report
                self.reports?.insert(report, at: 0)
            }
        }
    }
}

/// Receives MetricKit's diagnostic payloads — on launch, for problems in
/// earlier runs — and turns them into reports on its own background queue,
/// where symbolication happens too.
private final class MetricKitCollector: NSObject, MXMetricManagerSubscriber, Sendable {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let reports = payloads.flatMap { MetricKitReports.reports(from: $0.jsonRepresentation()) }
        guard !reports.isEmpty else { return }
        Task { @MainActor in Diagnostics.shared.add(reports) }
    }
}

/// The breadcrumb for the run in progress: the last few actions in memory,
/// flushed with the unclean-exit marker a moment after each one. Private
/// windows record nothing (pass the browser and they are skipped).
@MainActor
enum Breadcrumbs {
    private static var current = Breadcrumb(appVersion: Bundle.main.zenticVersion)
    private static var flush: Task<Void, Never>?

    static func note(_ action: String, in browser: Browser? = nil) {
        guard browser?.isPrivate != true else { return }
        current.note(action)
        // Batched: a run of closed tabs is one small write, not one each.
        flush?.cancel()
        flush = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let windows = Windows.shared.open.filter { !$0.isPrivate }
            let tabs = windows.flatMap(\.allTabs)
            current.windows = windows.count
            current.tabs = tabs.count
            current.liveTabs = tabs.count(where: \.isRealized)
            Windows.shared.record(current)
        }
    }
}

extension Bundle {
    /// "0.1.0 (212)", or "development" for `swift run`, which has no Info.plist.
    var zenticVersion: String {
        guard let version = infoDictionary?["CFBundleShortVersionString"] as? String else { return "development" }
        return (infoDictionary?["CFBundleVersion"] as? String).map { "\(version) (\($0))" } ?? version
    }
}
