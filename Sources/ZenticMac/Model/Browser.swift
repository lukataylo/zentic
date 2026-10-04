import AppKit
import Observation
import SwiftUI
import WebKit
import ZenticKit

/// One window's state: its spaces and their tabs, which tab is shown, and the
/// chrome around it. `Windows` owns the set of them.
@MainActor
@Observable
final class Browser: Identifiable {
    let id: UUID
    /// A private window writes nothing to disk: no session, history, icons or
    /// site choices, and its cookies and caches live in `dataStore` and die
    /// with the window.
    let isPrivate: Bool
    @ObservationIgnored let dataStore: WKWebsiteDataStore
    /// What this window's pages may do; a private window's answers stay in it.
    @ObservationIgnored private(set) lazy var permissions = PermissionScope(isPrivate: isPrivate)

    private(set) var spaces: [Space]
    private(set) var spaceID: UUID

    var sidebarVisible = true { didSet { scheduleSave() } }
    var sidebarWidth: Double = 260 { didSet { scheduleSave() } }
    /// The sidebar slid in over the page while it is collapsed.
    var sidebarPeeking = false

    var commandBar = CommandBarState()
    /// The address being edited in place in the open toolbar.
    var editingAddress = false
    var findBar = FindBarState()
    var modePickerPresented = false
    /// The New Space or Edit Space sheet, while it is up.
    var spaceDraft: SpaceDraft?
    /// Set on the first window after an unexpected quit, until dismissed.
    var recoveryNotice: LaunchGuard.Outcome?
    /// The report about that quit, opened from the notice's Send Report….
    var showsIncidentReport = false

    /// The window's frame, kept for the next launch.
    @ObservationIgnored var frame: NSRect? { didSet { scheduleSave() } }
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var windowObservers: [NSObjectProtocol] = []
    /// Restored from a session written before windows had saved frames.
    @ObservationIgnored var adoptsLegacyFrame = false

    /// Closed tabs, oldest first, for Reopen Closed Tab and History ›
    /// Recently Closed. Observed: the menu follows it.
    private(set) var closed: [Tab.Saved] = []

    var space: Space { spaces.first { $0.id == spaceID } ?? spaces[0] }
    /// The current space's open (unpinned) tabs.
    var tabs: [Tab] { space.tabs }
    var selectedID: UUID? { space.selectedID }
    var selectedTab: Tab? { space.selected }
    /// Every tab in every space of this window.
    var allTabs: [Tab] { spaces.flatMap(\.allTabs) }

    /// A new, empty window.
    init(isPrivate: Bool = false, dataStore: WKWebsiteDataStore? = nil, space: Space? = nil) {
        id = UUID()
        self.isPrivate = isPrivate
        self.dataStore = dataStore ?? (isPrivate ? .nonPersistent() : .zentic)
        let first =
            space
            ?? Space(
                name: isPrivate ? "Private" : SessionSnapshot.defaultSpaceName,
                icon: isPrivate ? "eye.slash" : SessionSnapshot.defaultSpaceIcon, tint: .default)
        spaces = [first]
        spaceID = first.id
    }

    /// A window from the saved session. Its selected tab is realized when the
    /// window appears, not here.
    init(restoring saved: SessionSnapshot.Window) {
        id = saved.id
        isPrivate = false
        dataStore = .zentic
        sidebarWidth = saved.sidebarWidth
        sidebarVisible = saved.sidebarVisible
        frame = saved.frame.map { NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        adoptsLegacyFrame = saved.frame == nil
        var spaces = saved.spaces.map { saved in
            let space = Space(
                id: saved.id, name: saved.name, icon: saved.icon,
                tint: saved.tint.flatMap(SidebarTint.init) ?? .default)
            @MainActor func restore(_ tab: SessionSnapshot.Tab) -> Tab {
                let restored = Tab(id: tab.id, url: tab.url, title: tab.title, pinnedURL: tab.pinnedURL)
                restored.hasStateOnDisk = true
                return restored
            }
            space.pinned = saved.pinned.map(restore)
            space.tabs = saved.tabs.map(restore)
            space.selectedID = saved.selected.flatMap { id in space.allTabs.first { $0.id == id }?.id } ?? space.tabs.first?.id
            return space
        }
        if spaces.isEmpty {
            spaces = [Space(name: SessionSnapshot.defaultSpaceName, icon: SessionSnapshot.defaultSpaceIcon, tint: .default)]
        }
        self.spaces = spaces
        spaceID = saved.selectedSpace.flatMap { id in spaces.first { $0.id == id }?.id } ?? spaces[0].id
        allTabs.forEach { $0.browser = self }
    }

    var snapshot: SessionSnapshot.Window {
        // The live frame if there is a window: one never moved or resized has
        // sent no notification to remember it by.
        let frame = window.flatMap { $0.styleMask.contains(.fullScreen) ? nil : $0.frame } ?? self.frame
        return SessionSnapshot.Window(
            id: id,
            frame: frame.map { .init(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) },
            sidebarWidth: sidebarWidth, sidebarVisible: sidebarVisible,
            spaces: spaces.map { space in
                SessionSnapshot.Space(
                    id: space.id, name: space.name, icon: space.icon, tint: space.tint.rawValue,
                    pinned: space.pinned.map(\.snapshotSource), tabs: space.tabs.map(\.snapshotSource),
                    selected: space.selectedID)
            },
            selectedSpace: spaceID)
    }

    // MARK: - Selection

    func select(_ tab: Tab) {
        if let owner = owner(of: tab), owner.id != spaceID { switchTo(owner, realizingSelection: false) }
        guard space.selectedID != tab.id else {
            // Already selected but held back after a crash: the click loads it.
            tab.realize()
            return
        }
        findBar.isPresented = false
        selectedTab?.didHide()
        space.selectedID = tab.id
        tab.lastShown = .now
        tab.realize()
        scheduleSave()
        Windows.shared.trimLiveTabs()
    }

    func selectTab(at index: Int) {
        let visible = space.allTabs
        guard !visible.isEmpty else { return }
        // ⌘9 is always the last tab, as in Safari.
        let i = index == 8 ? visible.count - 1 : index
        if visible.indices.contains(i) { select(visible[i]) }
    }

    func selectNeighbour(_ offset: Int) {
        let visible = space.allTabs
        guard let current = visible.firstIndex(where: { $0.id == selectedID }), !visible.isEmpty else { return }
        select(visible[(current + offset + visible.count) % visible.count])
    }

    // MARK: - Spaces

    /// `realizingSelection: false` when a particular tab is about to be
    /// selected there, so the space's previous one is not loaded for nothing.
    func switchTo(_ target: Space, realizingSelection: Bool = true) {
        guard target.id != spaceID, spaces.contains(where: { $0 === target }) else { return }
        findBar.isPresented = false
        selectedTab?.didHide()
        Breadcrumbs.note("Switched space", in: self)
        spaceID = target.id
        if realizingSelection, let tab = target.selected {
            tab.lastShown = .now
            tab.realize()
        }
        scheduleSave()
        Windows.shared.trimLiveTabs()
    }

    /// The next or previous space, stopping at the ends rather than wrapping:
    /// a swipe that wraps around feels like it went the wrong way.
    func switchSpace(by offset: Int) {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        let target = index + offset
        if spaces.indices.contains(target) { switchTo(spaces[target]) }
    }

    func addSpace(name: String, icon: String, tint: SidebarTint) {
        guard !isPrivate else { return }
        let space = Space(name: name, icon: icon, tint: tint)
        spaces.append(space)
        switchTo(space)
    }

    func spaceDidChange() { scheduleSave() }

    func moveSpace(_ space: Space, by offset: Int) {
        guard let from = spaces.firstIndex(where: { $0 === space }) else { return }
        let to = from + offset
        guard spaces.indices.contains(to) else { return }
        spaces.swapAt(from, to)
        scheduleSave()
    }

    /// Delete a space and close its tabs, pinned ones included.
    func deleteSpace(_ space: Space) {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0 === space }) else { return }
        if space.id == spaceID { switchTo(spaces[index == 0 ? 1 : index - 1]) }
        for tab in space.allTabs { discard(tab) }
        spaces.remove(at: index)
        scheduleSave()
    }

    /// Move a tab to another space of this window, keeping its page.
    func move(_ tab: Tab, to target: Space) {
        guard let owner = owner(of: tab), owner !== target else { return }
        detach(tab, from: owner)
        // A pinned tab stays pinned: it is a place, now in another space.
        if tab.isPinned { target.pinned.append(tab) } else { target.tabs.insert(tab, at: 0) }
        scheduleSave()
    }

    private func owner(of tab: Tab) -> Space? { spaces.first { $0.contains(tab) } }

    // MARK: - Tabs

    @discardableResult
    func openTab(_ url: URL?, after anchor: Tab? = nil, select: Bool = true) -> Tab {
        let tab = Tab(url: url)
        insert(tab, after: anchor, select: select)
        return tab
    }

    /// New tabs go at the top of the list, or just below the tab that opened
    /// them — in the opener's space, never among the pinned tabs.
    func insert(_ tab: Tab, after anchor: Tab?, select: Bool) {
        tab.browser = self
        let target = anchor.flatMap(owner(of:)) ?? space
        if let anchor, let index = target.tabs.firstIndex(where: { $0 === anchor }) {
            target.tabs.insert(tab, at: index + 1)
        } else {
            target.tabs.insert(tab, at: 0)
        }
        Breadcrumbs.note("Opened a tab", in: self)
        if select { self.select(tab) }
        scheduleSave()
    }

    /// ⌘W. An ordinary tab closes. A pinned tab is a place rather than a page,
    /// so — as in Arc — it goes back to its pinned address, unloads, and the
    /// window steps away from it.
    func close(_ tab: Tab) {
        guard let owner = owner(of: tab) else { return }
        if tab.isPinned {
            tab.resetToPin()
            if owner.selectedID == tab.id {
                // The ordinary tab shown most recently; another pinned tab
                // would wake for no reason.
                let recent = owner.tabs.max { $0.lastShown < $1.lastShown }
                owner.selectedID = nil
                if let recent { owner === space ? select(recent) : (owner.selectedID = recent.id) }
            }
            scheduleSave()
            return
        }
        guard let index = owner.tabs.firstIndex(where: { $0 === tab }) else { return }
        Breadcrumbs.note("Closed a tab", in: self)
        if SiteKey.isWeb(tab.url) { closed.append(tab.snapshotSource) }
        if closed.count > 30 { closed.removeFirst() }
        discard(tab)
        owner.tabs.remove(at: index)
        if owner.selectedID == tab.id {
            // The tab below, as in every Mac app with a list; else the one
            // above. Never a pinned tab: those wake only when asked.
            let next = owner.tabs.indices.contains(index) ? owner.tabs[index] : owner.tabs.last
            owner.selectedID = nil
            if let next { owner === space ? select(next) : (owner.selectedID = next.id) }
        }
        scheduleSave()
    }

    // The survivor is selected first: closing the selected tab selects the
    // next, which would wake a web view (and load its page) for every tab in
    // turn, only to close it a moment later.

    func closeOthers(than keep: Tab) {
        if space.selectedID != keep.id { select(keep) }
        for tab in space.tabs where tab !== keep { close(tab) }
    }

    func closeBelow(_ anchor: Tab) {
        guard let index = space.tabs.firstIndex(where: { $0 === anchor }) else { return }
        let below = Array(space.tabs[(index + 1)...])
        if below.contains(where: { $0.id == space.selectedID }) { select(anchor) }
        for tab in below { close(tab) }
    }

    func reopenClosed() {
        if let last = closed.last { reopenClosed(last.id) }
    }

    func reopenClosed(_ id: UUID) {
        guard let index = closed.firstIndex(where: { $0.id == id }) else { return }
        let saved = closed.remove(at: index)
        let tab = Tab(id: UUID(), url: saved.url, title: saved.title)
        insert(tab, after: selectedTab, select: true)
    }

    var canReopen: Bool { !closed.isEmpty }

    func duplicate(_ tab: Tab) {
        openTab(tab.url, after: tab)
    }

    /// Release a tab for good: its page, its in-flight work, its saved state.
    private func discard(_ tab: Tab) {
        tab.design.reset()  // and cancel any model call in flight
        tab.suspend(persisting: false)
        tab.forgetSavedState()
    }

    /// Take a tab out of its space without releasing it, choosing a new
    /// selection if it was the one shown.
    private func detach(_ tab: Tab, from owner: Space) {
        let wasSelected = owner.selectedID == tab.id
        owner.pinned.removeAll { $0 === tab }
        owner.tabs.removeAll { $0 === tab }
        if wasSelected {
            owner.selectedID = nil
            if let next = owner.tabs.first {
                owner === space ? select(next) : (owner.selectedID = next.id)
            }
        }
    }

    // MARK: - Pinned tabs

    func pin(_ tab: Tab) {
        guard !isPrivate, !tab.isPinned, let owner = owner(of: tab) else { return }
        owner.tabs.removeAll { $0 === tab }
        tab.pinnedURL = tab.url
        owner.pinned.append(tab)
        scheduleSave()
    }

    func unpin(_ tab: Tab) {
        guard tab.isPinned, let owner = owner(of: tab) else { return }
        owner.pinned.removeAll { $0 === tab }
        tab.pinnedURL = nil
        owner.tabs.insert(tab, at: 0)
        scheduleSave()
    }

    /// Drag-reordering. Dropping onto a row in the other section pins or
    /// unpins the dragged tab.
    func move(_ id: UUID, onto targetID: UUID) {
        let current = space
        guard id != targetID,
            let tab = current.allTabs.first(where: { $0.id == id }),
            let target = current.allTabs.first(where: { $0.id == targetID })
        else { return }
        let toPinned = target.isPinned
        if toPinned && isPrivate { return }
        var list = toPinned ? current.pinned : current.tabs
        let from = list.firstIndex { $0 === tab }
        list.removeAll { $0 === tab }
        guard var to = list.firstIndex(where: { $0 === target }) else { return }
        // Moving down lands after the target; moving up lands before it.
        if let from, from <= to { to += 1 }
        list.insert(tab, at: to)
        if tab.isPinned != toPinned {
            if toPinned {
                current.tabs.removeAll { $0 === tab }
                tab.pinnedURL = tab.url
            } else {
                current.pinned.removeAll { $0 === tab }
                tab.pinnedURL = nil
            }
        }
        if toPinned { current.pinned = list } else { current.tabs = list }
        scheduleSave()
    }

    /// Dropped on the space's header: pin at the end.
    func pinByDrop(_ id: UUID) {
        guard let tab = space.tabs.first(where: { $0.id == id }) else { return }
        pin(tab)
    }

    // MARK: - Windows

    func moveToNewWindow(_ tab: Tab) {
        guard let owner = owner(of: tab) else { return }
        detach(tab, from: owner)
        tab.pinnedURL = nil
        scheduleSave()
        Windows.shared.openWindow(adopting: tab, from: self)
    }

    /// Adopt a tab moved here from another window, as this window's only tab.
    func adopt(_ tab: Tab) {
        tab.browser = self
        space.tabs = [tab]
        space.selectedID = tab.id
    }

    /// The window closed for good: release every page.
    func closeAllTabs(forgettingState: Bool) {
        for tab in allTabs {
            tab.design.reset()
            tab.suspend(persisting: !forgettingState)
            if forgettingState { tab.forgetSavedState() }
        }
    }

    /// Open a favourite: switch to a tab in this space already on that site,
    /// or open one.
    func open(_ favorite: Favorite) {
        let key = SiteKey.for(favorite.url)
        if let existing = space.allTabs.first(where: { $0.siteKey == key }) {
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

    /// ⌘L and a click on the address: edit it in place while the toolbar is
    /// open at the top of the page; the command bar only once the page has
    /// been scrolled and the toolbar has folded away.
    func editAddress() {
        if selectedTab?.chromeCollapsed == true {
            showCommandBar(newTab: false)
        } else {
            editingAddress = true
        }
    }

    func showCommandBar(newTab: Bool) {
        commandBar.opensNewTab = newTab
        commandBar.text = newTab ? "" : (selectedTab?.url?.absoluteString ?? "")
        commandBar.isPresented = true
    }

    // MARK: - Site choices

    /// A private window's own changes to sites, laid over the shared book and
    /// forgotten with the window. A nil value is a site this window reset.
    private var privateSites: [String: SiteSettings?] = [:]

    /// What this window's pages follow: the user's choices, plus — in a
    /// private window — whatever was changed here.
    var book: SiteBook { overlay(AppModel.shared.book) }

    private func overlay(_ shared: SiteBook) -> SiteBook {
        isPrivate ? shared.overlaying(privateSites) : shared
    }

    func mode(for url: URL?) -> SiteMode {
        SiteKey.isWeb(url) ? book.mode(for: SiteKey.for(url)) : .original
    }

    func custom(for url: URL?) -> CustomVersion? { book.custom(for: SiteKey.for(url)) }

    func setMode(_ mode: SiteMode, for url: URL?) {
        guard let key = SiteKey.for(url) else { return }
        guard isPrivate else { return AppModel.shared.setMode(mode, for: url) }
        changePrivately(key) { $0.setMode(mode, for: key) }
    }

    func saveCustom(_ version: CustomVersion, for url: URL?) {
        guard let key = SiteKey.for(url) else { return }
        guard isPrivate else { return AppModel.shared.saveCustom(version, for: url) }
        changePrivately(key) { $0.saveCustom(version, for: key) }
    }

    func removeCustom(forKey key: String) {
        guard isPrivate else { return AppModel.shared.removeCustom(forKey: key) }
        changePrivately(key) { $0.removeCustom(for: key) }
    }

    private func changePrivately(_ key: String, _ change: (inout SiteBook) -> Void) {
        let old = book
        privateSites[key] = .some(old.override(key, change))
        sitesChanged(from: old, to: book)
    }

    /// The user's choices changed, in any window.
    func sharedSitesChanged(from old: SiteBook, to new: SiteBook) {
        sitesChanged(from: overlay(old), to: overlay(new))
    }

    /// The user picked a mode for the current page's site.
    func choose(_ mode: SiteMode) {
        guard let tab = selectedTab, SiteKey.isWeb(tab.url) else { return }
        if mode == .custom && custom(for: tab.url) == nil {
            // Nothing to show yet: start one.
            modePickerPresented = false
            tab.design.present()
            return
        }
        Breadcrumbs.note("Chose \(mode.title) for a site", in: self)
        tab.design.reset()
        setMode(mode, for: tab.url)
        // Also correct when the choice equals what is stored already (e.g. a
        // preview is on screen): put the page back to what the user chose.
        tab.applyMode()
    }

    private func sitesChanged(from old: SiteBook, to new: SiteBook) {
        guard old.inPageConfig() != new.inPageConfig() else { return }
        for tab in allTabs where tab.isRealized {
            let key = tab.siteKey
            let changed =
                old.mode(for: key) != new.mode(for: key)
                || !CustomVersion.sameDesign(old.custom(for: key), new.custom(for: key))
            if changed { tab.applyMode() } else { tab.installScripts() }
        }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        guard !isPrivate else { return }
        Windows.shared.scheduleSave()
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
