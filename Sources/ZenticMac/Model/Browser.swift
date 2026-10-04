import AppKit
import Observation
import SwiftUI
import ZenticKit

/// The window's state: its tabs, which one is shown, and the chrome around it.
@MainActor
@Observable
final class Browser {
    private(set) var tabs: [Tab] = []
    private(set) var selectedID: UUID?
    var sidebarVisible = true { didSet { scheduleSave() } }
    var sidebarWidth: Double = 260 { didSet { scheduleSave() } }
    /// The sidebar slid in over the page while it is collapsed.
    var sidebarPeeking = false

    var commandBar = CommandBarState()
    var findBar = FindBarState()
    var modePickerPresented = false

    @ObservationIgnored private var closed: [Tab.Saved] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    var selectedTab: Tab? { tabs.first { $0.id == selectedID } }

    init() {
        restore()
        AppModel.shared.onSitesChanged.append { [weak self] old, new in
            self?.sitesChanged(from: old, to: new)
        }
    }

    // MARK: - Tabs

    func select(_ tab: Tab) {
        guard selectedID != tab.id else { return }
        findBar.isPresented = false
        selectedID = tab.id
        tab.realize()
        scheduleSave()
    }

    @discardableResult
    func openTab(_ url: URL?, after anchor: Tab? = nil, select: Bool = true) -> Tab {
        let tab = Tab(url: url)
        insert(tab, after: anchor, select: select)
        return tab
    }

    func insert(_ tab: Tab, after anchor: Tab?, select: Bool) {
        tab.browser = self
        if let anchor, let index = tabs.firstIndex(where: { $0 === anchor }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.insert(tab, at: 0)
        }
        if select { self.select(tab) }
        scheduleSave()
    }

    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if SiteKey.isWeb(tab.url) { closed.append(tab.snapshotSource) }
        if closed.count > 30 { closed.removeFirst() }
        tab.suspend()
        tabs.remove(at: index)
        if selectedID == tab.id {
            // The tab below, as in every Mac app with a list; else the one above.
            let next = tabs.indices.contains(index) ? tabs[index] : tabs.last
            selectedID = nil
            if let next { select(next) }
        }
        scheduleSave()
    }

    func closeSelected() {
        if let tab = selectedTab { close(tab) }
    }

    func closeOthers(than keep: Tab) {
        for tab in tabs where tab !== keep { close(tab) }
    }

    func closeBelow(_ anchor: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === anchor }) else { return }
        for tab in tabs[(index + 1)...] { close(tab) }
    }

    func reopenClosed() {
        guard let saved = closed.popLast() else { return }
        let tab = Tab(id: UUID(), url: saved.url, title: saved.title)
        insert(tab, after: selectedTab, select: true)
    }

    var canReopen: Bool { !closed.isEmpty }

    func duplicate(_ tab: Tab) {
        openTab(tab.url, after: tab)
    }

    func move(_ id: UUID, before target: UUID?) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        if let target, let to = tabs.firstIndex(where: { $0.id == target }) {
            tabs.insert(tab, at: to)
        } else {
            tabs.append(tab)
        }
        scheduleSave()
    }

    func selectTab(at index: Int) {
        guard !tabs.isEmpty else { return }
        // ⌘9 is always the last tab, as in Safari.
        let i = index == 8 ? tabs.count - 1 : index
        if tabs.indices.contains(i) { select(tabs[i]) }
    }

    func selectNeighbour(_ offset: Int) {
        guard let current = tabs.firstIndex(where: { $0.id == selectedID }), !tabs.isEmpty else { return }
        select(tabs[(current + offset + tabs.count) % tabs.count])
    }

    /// Open a favourite: switch to a tab already on that site, or open one.
    func open(_ favorite: Favorite) {
        let key = SiteKey.for(favorite.url)
        if let existing = tabs.first(where: { $0.siteKey == key }) {
            select(existing)
        } else {
            openTab(favorite.url)
        }
    }

    func tabDidChange(_ tab: Tab) { scheduleSave() }

    // MARK: - Navigation entry

    /// Load what the user typed, in the current tab or a new one.
    func go(_ text: String, newTab: Bool) {
        guard let url = URLGuess.resolve(text, engine: AppModel.shared.searchEngine) else { return }
        if newTab || selectedTab == nil {
            openTab(url, after: selectedTab)
        } else {
            selectedTab?.load(url)
        }
    }

    // MARK: - Modes

    /// The user picked a mode for the current page's site.
    func choose(_ mode: SiteMode) {
        guard let tab = selectedTab, SiteKey.isWeb(tab.url) else { return }
        if mode == .custom && AppModel.shared.custom(for: tab.url) == nil {
            // Nothing to show yet: start one.
            modePickerPresented = false
            tab.design.present()
            return
        }
        tab.design.reset()
        AppModel.shared.setMode(mode, for: tab.url)
        // Also correct when the choice equals what is stored already (e.g. a
        // preview is on screen): put the page back to what the user chose.
        tab.applyMode()
    }

    private func sitesChanged(from old: SiteBook, to new: SiteBook) {
        let oldConfig = old.inPageConfig()
        let newConfig = new.inPageConfig()
        guard oldConfig != newConfig else { return }
        for tab in tabs where tab.isRealized {
            let key = tab.siteKey
            let changed =
                old.mode(for: key) != new.mode(for: key) || old.custom(for: key) != new.custom(for: key)
            if changed { tab.applyMode() } else { tab.installScripts() }
        }
    }

    // MARK: - Persistence

    private func restore() {
        let session = AppModel.shared.sessionFile.load()
        sidebarWidth = session?.sidebarWidth ?? 260
        sidebarVisible = session?.sidebarVisible ?? true
        let saved = session?.tabs ?? []
        if saved.isEmpty {
            let tab = Tab(url: URL(string: "https://en.wikipedia.org/wiki/Special:Random"))
            tab.browser = self
            tabs = [tab]
            selectedID = tab.id
        } else {
            tabs = saved.map { Tab(id: $0.id, url: $0.url, title: $0.title) }
            tabs.forEach { $0.browser = self }
            selectedID = session?.selected.flatMap { id in tabs.first { $0.id == id }?.id } ?? tabs.first?.id
        }
        selectedTab?.realize()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let session = SavedSession(
            tabs: tabs.map(\.snapshotSource), selected: selectedID,
            sidebarWidth: sidebarWidth, sidebarVisible: sidebarVisible)
        AppModel.shared.sessionFile.save(session)
    }
}

/// The ⌘T / ⌘L palette.
struct CommandBarState {
    var isPresented = false
    /// Open the result in a new tab (⌘T) rather than the current one (⌘L).
    var opensNewTab = true
    var text = ""
}

struct FindBarState {
    var isPresented = false
    var text = ""
    var notFound = false
}
