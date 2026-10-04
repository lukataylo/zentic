import Foundation

/// Notices when the last run ended without quitting, and when runs keep
/// ending that way right after launch.
///
/// A marker file exists for exactly as long as the app is running: written at
/// launch, removed on a clean quit. Finding one at launch means the previous
/// run crashed or was killed. The marker also records whether that run lived
/// past `startupWindow`; two runs in a row that did not are probably being
/// killed by something restored at launch, so the next launch restores the
/// tabs without loading the selected page.
///
/// While running, the marker also carries the latest `Breadcrumb`, so after an
/// unexpected quit the next launch knows what the app was doing.
public struct LaunchGuard: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The previous run quit normally, or this is the first.
        case clean
        /// The previous run ended unexpectedly.
        case recovered
        /// The last two runs each ended within `startupWindow` of launching.
        case recoveredRepeatedly
    }

    /// A run that lasts this long counts as having started successfully.
    public static let startupWindow: Duration = .seconds(30)

    struct Record: Codable, Equatable {
        /// Set once the run outlives `startupWindow`.
        var survivedStartup: Bool
        /// Consecutive runs, up to and including the previous one, that ended
        /// inside the startup window.
        var startupCrashes: Int
        /// Absent in markers from before breadcrumbs, and until the first is recorded.
        var breadcrumb: Breadcrumb?
    }

    private let file: JSONFile<Record>

    public init(directory: URL) {
        file = JSONFile(name: "running.marker", directory: directory)
    }

    /// Call once, first thing at launch. Synchronous on purpose: the marker
    /// must be on disk before anything that could crash runs. After an
    /// unexpected quit, also returns the last breadcrumb that run recorded.
    public func begin() -> (outcome: Outcome, breadcrumb: Breadcrumb?) {
        let previous = file.load()
        var crashes = 0
        let outcome: Outcome
        if let previous {
            crashes = previous.survivedStartup ? 0 : previous.startupCrashes + 1
            outcome = crashes >= 2 ? .recoveredRepeatedly : .recovered
        } else {
            outcome = .clean
        }
        file.save(Record(survivedStartup: false, startupCrashes: crashes))
        return (outcome, previous?.breadcrumb)
    }

    /// Keep the latest breadcrumb with the marker. Never recreates a marker
    /// that `end()` removed: a write that lands after a clean quit would
    /// report that quit as a crash.
    public func record(_ breadcrumb: Breadcrumb) {
        guard var record = file.load() else { return }
        record.breadcrumb = breadcrumb
        file.save(record)
    }

    /// This run has lasted `startupWindow`: whatever happens later, it was not
    /// a crash on launch.
    public func markStartupSurvived() {
        guard var record = file.load() else { return }
        record.survivedStartup = true
        file.save(record)
    }

    /// A clean quit.
    public func end() {
        try? FileManager.default.removeItem(at: file.url)
    }
}
