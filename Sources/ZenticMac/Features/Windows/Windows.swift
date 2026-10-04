import AppKit
import SwiftUI
import ZenticKit

/// Every browser window, and what spans them: the saved session, crash
/// recovery, and the app-wide limit on live pages.
///
/// SwiftUI owns the windows; this owns what is in them. A window is opened
/// with its browser's id, and its root view claims the browser by that id.
@MainActor
@Observable
final class Windows {
    static let shared = Windows()

    /// Each tab's back/forward list and scroll position, on disk.
    static let tabStates = TabStateStore(
        directory: JSONFile<Int>.defaultDirectory.appendingPathComponent("Tabs", isDirectory: true))

    /// Browsers whose window is open, oldest first.
    @ObservationIgnored private(set) var open: [Browser] = []
    /// Restored or newly made, waiting for their window to appear.
    @ObservationIgnored private var pending: [Browser] = []
    /// The last ordinary window, kept after it was closed so that reopening
    /// from the Dock, or ⌘N, brings the same spaces and tabs back.
    @ObservationIgnored private var parked: Browser?
    /// The ordinary window closed most recently while others stayed open —
    /// its spaces and pinned tabs belong to it alone, so closing it by
    /// mistake must not lose them. Kept asleep, in memory only. The one
    /// observed property: the menu's Reopen Closed Window follows it.
    private var recentlyClosed: Browser?
    /// Restored from the session; their selected tab is held back after
    /// repeated crashes on launch.
    @ObservationIgnored private var restoredIDs: Set<UUID> = []
    @ObservationIgnored private var openWindowAction: OpenWindowAction?
    @ObservationIgnored private var openedRestoredWindows = false
    @ObservationIgnored private var terminating = false

    private let sessionFile = JSONFile<SessionSnapshot>(name: "session.json")
    private let launchGuard = LaunchGuard(directory: JSONFile<Int>.defaultDirectory)
    /// Session and marker writes, in order, off the main thread. Quitting
    /// writes through it synchronously, so an older session still queued can
    /// never land on top of the final one.
    private let io = DispatchQueue(label: "Zentic.session", qos: .utility)
    let launch: LaunchGuard.Outcome

    private init() {
        launch = launchGuard.begin()
        let session = sessionFile.load()
        pending = session?.windows.map(Browser.init(restoring:)) ?? []
        restoredIDs = Set(pending.map(\.id))
        if pending.isEmpty {
            // First run. Built directly: `openTab` would reach back into
            // `Windows.shared`, which is what is being made.
            let first = Browser()
            first.adopt(Tab(url: URL(string: "https://en.wikipedia.org/wiki/Special:Random")))
            pending = [first]
        }
        if launch != .clean { pending.first?.recoveryNotice = launch }

        // Only against a session that was actually read: if it was unreadable
        // and set aside, its tabs' states are what would make it recoverable.
        if let ids = session?.tabIDs { Self.tabStates.prune(keeping: ids) }
        let launchGuard = self.launchGuard
        io.asyncAfter(deadline: .now() + .seconds(Int(LaunchGuard.startupWindow.components.seconds))) {
            launchGuard.markStartupSurvived()
        }
        // Leaving the app is the moment to keep each page's scroll position:
        // the page on screen is otherwise only saved when it loads or is hidden.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                for browser in self?.open ?? [] { browser.selectedTab?.persistState() }
            }
        }

        AppModel.shared.onSitesChanged.append { [weak self] old, new in
            self?.everyBrowser.forEach { $0.sharedSitesChanged(from: old, to: new) }
        }
        watchMemory()
    }

    private var everyBrowser: [Browser] { open + pending + (parked.map { [$0] } ?? []) }

    /// The browser window in front, for commands given while another window
    /// (Settings, say) is key.
    var frontmost: Browser? {
        NSApp.orderedWindows.lazy.compactMap { window in self.open.first { $0.window === window } }.first
    }

    // MARK: - Opening and closing

    /// The browser for a window that is appearing. `id` is the value the
    /// window was opened with; nil for the window SwiftUI opens by itself (at
    /// launch, or from the Dock).
    func claim(_ id: UUID?) -> Browser {
        if let id, let browser = open.first(where: { $0.id == id }) { return browser }
        let browser: Browser
        if let index = pending.firstIndex(where: { id == nil || $0.id == id }) {
            browser = pending.remove(at: index)
        } else if let parked, id == nil || parked.id == id {
            browser = parked
            self.parked = nil
        } else if let recentlyClosed, recentlyClosed.id == id {
            browser = recentlyClosed
            self.recentlyClosed = nil
            scheduleSave()
        } else {
            browser = Browser()
        }
        open.append(browser)
        // Held back once, when first restored; a window reopened later loads.
        let holdsBack = launch == .recoveredRepeatedly && restoredIDs.remove(browser.id) != nil
        if !holdsBack { browser.selectedTab?.realize() }
        if browser.allTabs.isEmpty { browser.showCommandBar(newTab: true) }
        return browser
    }

    /// A window appeared. The first time, open the rest of the restored ones.
    func windowAppeared(_ openWindow: OpenWindowAction) {
        openWindowAction = openWindow
        guard !openedRestoredWindows else { return }
        openedRestoredWindows = true
        for browser in pending { openWindow(value: browser.id) }
    }

    func newWindow(private isPrivate: Bool) {
        if !isPrivate, let parked, !open.contains(where: { !$0.isPrivate }) {
            // No ordinary window open: ⌘N brings the last one back.
            return show(parked)
        }
        let browser = Browser(isPrivate: isPrivate)
        pending.append(browser)
        show(browser)
    }

    func openWindow(adopting tab: Tab, from source: Browser) {
        let space = Space(name: source.space.name, icon: source.space.icon, tint: source.space.tint)
        let browser = Browser(isPrivate: source.isPrivate, dataStore: source.dataStore, space: space)
        browser.adopt(tab)
        pending.append(browser)
        show(browser)
        scheduleSave()
    }

    var canReopenWindow: Bool { recentlyClosed != nil }

    func reopenClosedWindow() {
        if let recentlyClosed { show(recentlyClosed) }
    }

    private func show(_ browser: Browser) {
        openWindowAction?(value: browser.id)
    }

    func windowClosed(_ browser: Browser) {
        // Quitting closes windows too; the session saved on the way out must
        // still contain them.
        guard !terminating, let index = open.firstIndex(where: { $0 === browser }) else { return }
        open.remove(at: index)
        if browser.isPrivate {
            // Its pages, cookies and caches go with it.
            browser.closeAllTabs(forgettingState: false)
        } else if open.contains(where: { !$0.isPrivate }) {
            // Out of the session, and its tabs' files go; their state stays
            // in memory for Reopen Closed Window.
            browser.closeAllTabs(forgettingState: true)
            recentlyClosed = browser
        } else {
            // Keep the last one, asleep: no live pages, everything restorable.
            browser.closeAllTabs(forgettingState: false)
            parked = browser
        }
        scheduleSave()
    }

    // MARK: - Session

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    var snapshot: SessionSnapshot {
        SessionSnapshot(windows: everyBrowser.filter { !$0.isPrivate }.map(\.snapshot))
    }

    func scheduleSave() {
        guard !terminating else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            // Encoded and written off the main thread, in order.
            let snapshot = self.snapshot
            let file = self.sessionFile
            self.io.async { file.save(snapshot) }
            TabSync.shared.sessionChanged()
        }
    }

    /// Quitting: save everything now, and record that the quit was clean.
    func saveForTermination() {
        terminating = true
        saveTask?.cancel()
        let snapshot = self.snapshot
        let (file, launchGuard) = (sessionFile, self.launchGuard)
        for tab in everyBrowser.flatMap(\.allTabs) where tab.isRealized { tab.persistStateNow() }
        io.sync {
            file.save(snapshot)
            launchGuard.end()
        }
    }

    // MARK: - Memory

    /// Live web views kept beyond the ones on screen, across every window and
    /// space. Each is a WebKit content process — tens to hundreds of megabytes
    /// — so the rest are suspended: a title, an icon and their saved state,
    /// restored where they left off.
    static let maxLiveTabs = 6
    /// A background tab untouched this long is suspended regardless.
    static let idleLimit: Duration = .seconds(20 * 60)

    @ObservationIgnored private var trimming = false
    @ObservationIgnored private var memorySource: DispatchSourceMemoryPressure?
    @ObservationIgnored private var idleTimer: Timer?

    /// Suspend background tabs over the limit, or idle too long, least
    /// recently shown first — skipping any that are playing or recording.
    func trimLiveTabs(keeping limit: Int = Windows.maxLiveTabs) {
        guard !trimming else { return }
        trimming = true
        let visible = Set(open.compactMap { $0.selectedTab.map(ObjectIdentifier.init) })
        let candidates = open.flatMap(\.allTabs)
            .filter { $0.isRealized && !visible.contains(ObjectIdentifier($0)) }
            .sorted { $0.lastShown > $1.lastShown }
        Task {
            defer { trimming = false }
            var kept = 0
            for tab in candidates {
                let idle = Date.now.timeIntervalSince(tab.lastShown) > Double(Self.idleLimit.components.seconds)
                if kept < limit && !idle {
                    kept += 1
                    continue
                }
                if await tab.isBusy() { continue }
                // Shown while we waited.
                guard !open.contains(where: { $0.selectedTab === tab }) else { continue }
                tab.suspend()
            }
        }
    }

    private func watchMemory() {
        // Under memory pressure keep only the pages on screen.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.trimLiveTabs(keeping: 0) }
        }
        source.resume()
        memorySource = source
        idleTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trimLiveTabs() }
        }
        idleTimer?.tolerance = 60
    }
}
