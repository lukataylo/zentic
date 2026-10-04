import Foundation
import Observation
import WebKit
import ZenticKit

/// Warns before a page from a known phishing or malware host loads, using
/// lists kept on this Mac. No address is ever sent anywhere to be checked.
///
/// The check sits on the navigation hot path, so everything slow happens
/// elsewhere: lists are read and hashed off the main thread at launch,
/// refreshed daily by the system's background scheduler, and the main thread
/// only ever does a few binary searches over an in-memory ``ThreatSet``.
@MainActor
@Observable
final class SafeBrowsing {
    static let shared = SafeBrowsing()

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            DataDirectory.defaults.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { start() } else { stop() }
        }
    }

    /// When the lists were last confirmed current with upstream.
    private(set) var checkedAt: Date?
    private(set) var hostCount = 0
    private(set) var isUpdating = false
    private(set) var lastError: String?

    /// Third-party loads from listed hosts, blocked inside WebKit. Attached to
    /// every tab by ``Blocking`` alongside the content blockers.
    @ObservationIgnored private(set) var ruleList: WKContentRuleList?

    /// Hosts the user chose to visit anyway. In memory only, so the choice
    /// lasts until Zentic quits and is never written down.
    private(set) var bypassed: Set<String> = []

    @ObservationIgnored private var set = ThreatSet()
    @ObservationIgnored private let lists = ThreatLists()
    @ObservationIgnored private var scheduler: NSBackgroundActivityScheduler?
    @ObservationIgnored private var started = false
    /// Reading the lists at launch. The first navigations wait for it — a few
    /// milliseconds — so a restored tab or a link opened at launch is checked
    /// like any other, rather than slipping through before the lists arrive.
    @ObservationIgnored private var loading: Task<Void, Never>?

    private static let enabledKey = "safeBrowsing"

    private init() {
        isEnabled = DataDirectory.defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    // MARK: - The check

    /// The warning to show instead of loading `url`, if it is listed and the
    /// user has not already chosen to go there.
    func warning(for url: URL?) async -> ThreatWarning? {
        if let loading { await loading.value }
        guard isEnabled, let url, let host = url.host(), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", !bypassed.contains(host.lowercased()),
            let match = set.match(host: host)
        else { return nil }
        return ThreatWarning(url: url, match: match, listUpdated: checkedAt)
    }

    func visitAnyway(_ warning: ThreatWarning) {
        bypassed.insert(warning.host.lowercased())
    }

    func forgetBypasses() { bypassed = [] }

    // MARK: - Lists

    /// Read what is on disk and schedule refreshes. Called at launch; does
    /// nothing on the main thread but start a task.
    func start() {
        guard isEnabled, !started else { return }
        started = true
        let lists = lists
        loading = Task {
            if let snapshot = await lists.snapshot() { install(snapshot) }
            loading = nil
        }
        Task {
            await loading?.value
            // The first launch has nothing to protect with until a download;
            // later launches refresh well after launch, never on its path.
            let stale = await lists.isStale()
            if stale {
                try? await Task.sleep(for: checkedAt == nil ? .seconds(3) : .seconds(30))
                await update(force: false)
            }
            scheduleDailyRefresh()
        }
    }

    private func stop() {
        started = false
        scheduler?.invalidate()
        scheduler = nil
        set = ThreatSet()
        hostCount = 0
        ruleList = nil
        // Detach the rule list from every open tab now, not at its next load.
        Blocking.reattachAll()
    }

    /// Ask upstream now. `force` skips the ETag, for "Update Now".
    func update(force: Bool) async {
        guard isEnabled, !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            if let snapshot = try await lists.refresh(force: force) {
                install(snapshot)
            } else {
                checkedAt = await lists.checkedAt()
            }
            lastError = nil
        } catch {
            trace("safety", "list update failed: \(error)")
            lastError = "Couldn’t reach the list servers"
        }
    }

    private func install(_ snapshot: ThreatLists.Snapshot) {
        // Turned off while the lists were being read.
        guard isEnabled else { return }
        set = snapshot.set
        hostCount = snapshot.set.count
        checkedAt = snapshot.checkedAt
        trace("safety", "\(hostCount) hosts installed")
        Task { await installRuleList(id: snapshot.contentID) }
    }

    /// The compiled list is named by its content, so a relaunch finds it with
    /// one lookup and only a changed list is ever compiled again.
    private func installRuleList(id contentID: String) async {
        let identifier = "zentic.safety.\(contentID)"
        guard ruleList?.identifier != identifier else { return }
        let store = Self.ruleStore
        var list = try? await store.contentRuleList(forIdentifier: identifier)
        if list == nil {
            let hosts = await lists.allHosts()
            let json = await Task.detached(priority: .utility) { ThreatRules.json(hosts: hosts) }.value
            let started = ContinuousClock.now
            list = try? await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
            trace("safety", "compiled \(hosts.count) rules in \(started.duration(to: .now))")
        }
        guard let list, isEnabled else { return }
        ruleList = list
        Blocking.reattachAll()
        // Lists compiled for an older version of the hosts.
        for old in await store.availableIdentifiers() ?? [] where old != identifier {
            try? await store.removeContentRuleList(forIdentifier: old)
        }
    }

    /// Under `DataDirectory`, like the blockers' store, so an isolated run
    /// never collects the compiled list of the copy someone is browsing with.
    private static let ruleStore: WKContentRuleListStore = {
        let url = DataDirectory.root.appending(path: "SafeBrowsing/RuleLists", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return WKContentRuleListStore(url: url)
    }()

    /// Daily, when the system judges it cheap — on power, not under load —
    /// rather than a timer that would wake the Mac on its own schedule.
    private func scheduleDailyRefresh() {
        guard scheduler == nil, isEnabled else { return }
        let scheduler = NSBackgroundActivityScheduler(identifier: "com.lukadadiani.Zentic.safe-browsing")
        scheduler.repeats = true
        scheduler.interval = BlockerLimits.listMaxAge
        scheduler.tolerance = 60 * 60
        scheduler.qualityOfService = .utility
        scheduler.schedule { completion in
            Task { @MainActor in
                await SafeBrowsing.shared.update(force: false)
                completion(.finished)
            }
        }
        self.scheduler = scheduler
    }
}

/// A navigation stopped because its host is on a threat list.
struct ThreatWarning: Equatable {
    var url: URL
    var match: ThreatMatch
    var listUpdated: Date?

    var host: String { url.host() ?? match.listedHost }
}
