import AppKit
import WebKit
import ZenticKit

/// The one window's contents, and the coordinator everything else reports to.
///
/// Holds the store, the tab controllers, and the residency policy. That is a lot in
/// one type, but the alternative — a tab manager, a layout controller and a command
/// router — mostly moves the same coupling behind three protocols: every command
/// needs the selected tab, the store *and* the sidebar.
@MainActor
final class BrowserViewController: NSViewController {
    private let store: BrowsingStore
    private let faviconService = FaviconService()
    private let downloads = DownloadsController()
    private let palette = CommandPalette()

    private var spaces: [Space] = []
    private var activeSpace: Space?
    private var controllers: [UUID: TabController] = [:]
    private var residency = TabResidency(capacity: BrowserViewController.liveWebViewBudget)

    /// Normally ``Budget/maxLiveWebViews``. `ZENTIC_MAX_LIVE` overrides it, which
    /// exists purely so the suspension claim can be *dis*proved: running the stress
    /// mode with the cap raised is the control measurement.
    private static var liveWebViewBudget: Int {
        guard let raw = ProcessInfo.processInfo.environment["ZENTIC_MAX_LIVE"],
            let value = Int(raw), value >= 1
        else { return Budget.maxLiveWebViews }
        trace("tabs", "live web view budget overridden to \(value)")
        return value
    }
    private var selectedTabID: UUID?

    // MARK: Views

    private let vibrancy = NSVisualEffectView()
    private let tint = TintView(frame: .zero)
    private let sidebar = SidebarView(frame: .zero)
    private let dividerHandle = SidebarResizeHandle(frame: .zero)
    private let toolbar = ContentToolbar(frame: .zero)
    private let findBar = FindBar(frame: .zero)
    private let card = ContentCardView(frame: .zero)

    /// Blur behind the sidebar and the toolbar while they float over the page.
    /// Hidden while pinned, when the window's own vibrancy is already behind them.
    private let sidebarGlass = GlassPanel(withinWindow: true)
    private let toolbarGlass = GlassPanel(withinWindow: true)
    private let sidebarHotZone = HoverZone(frame: .zero)
    private let toolbarHotZone = HoverZone(frame: .zero)

    private var sidebarWidth: NSLayoutConstraint!
    /// Collapsed to zero height rather than hidden, so ⌘F does not reflow the page.
    private var findBarHeight: NSLayoutConstraint!
    private var cardTrailing: NSLayoutConstraint!
    private var cardBottom: NSLayoutConstraint!
    private var toolbarTop: NSLayoutConstraint!
    private var toolbarLeading: NSLayoutConstraint!
    /// Slides the sidebar out past the window edge while collapsed.
    private var sidebarLeading: NSLayoutConstraint!

    /// Card edges, in the two arrangements. Exactly one of each pair is active:
    /// pinned chrome takes space from the card, collapsed chrome floats over it.
    private var cardLeadingPinned: NSLayoutConstraint!
    private var cardLeadingCollapsed: NSLayoutConstraint!
    private var cardTopPinned: NSLayoutConstraint!
    private var cardTopCollapsed: NSLayoutConstraint!

    /// Whether the sidebar and toolbar hold their own space or float on hover.
    private var isSidebarPinned = true
    private var isToolbarPinned = true
    private var isFocusMode = false
    private var sidebarReveal: RevealLatch!
    private var toolbarReveal: RevealLatch!
    /// Sidebar width to restore when the sidebar comes back.
    private var restoredSidebarWidth: CGFloat = Chrome.sidebarDefaultWidth

    private static let activeSpaceKey = "zentic.activeSpaceID"

    init(store: BrowsingStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1_280, height: 840))

        vibrancy.material = .sidebar
        // Behind-window blending: the sidebar tint sits over the desktop, which is
        // what gives it depth rather than looking like a flat coloured panel.
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .followsWindowActiveState
        vibrancy.translatesAutoresizingMaskIntoConstraints = false

        let managed: [NSView] = [
            tint, card, toolbarGlass, toolbar, findBar,
            sidebarGlass, sidebar, dividerHandle, sidebarHotZone, toolbarHotZone,
        ]
        for subview in managed {
            subview.translatesAutoresizingMaskIntoConstraints = false
        }

        // Back to front. The card sits *below* the sidebar and toolbar because when
        // either is collapsed it floats over the page; while pinned they do not
        // overlap the card at all, so one order serves both arrangements.
        root.addSubview(vibrancy)
        root.addSubview(tint)
        root.addSubview(card)
        root.addSubview(toolbarGlass)
        root.addSubview(toolbar)
        root.addSubview(findBar)
        root.addSubview(sidebarGlass)
        root.addSubview(sidebar)
        root.addSubview(dividerHandle)
        root.addSubview(sidebarHotZone)
        root.addSubview(toolbarHotZone)

        sidebarGlass.isHidden = true
        toolbarGlass.isHidden = true
        sidebarHotZone.isArmed = false
        toolbarHotZone.isArmed = false

        // Explicit constraints rather than a stack view. The card has to absorb all
        // remaining space in *both* axes, and a vertical NSStackView sizes its views
        // to their intrinsic width — which for a view whose only content is a
        // centred empty-state message is about 300pt, not the window.
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: Chrome.sidebarDefaultWidth)
        sidebarLeading = sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        cardLeadingPinned = card.leadingAnchor.constraint(
            equalTo: sidebar.trailingAnchor,
            constant: Chrome.contentInset
        )
        cardLeadingCollapsed = card.leadingAnchor.constraint(
            equalTo: root.leadingAnchor,
            constant: Chrome.contentInset
        )
        cardTrailing = card.trailingAnchor.constraint(
            equalTo: root.trailingAnchor,
            constant: -Chrome.contentInset
        )
        cardBottom = card.bottomAnchor.constraint(
            equalTo: root.bottomAnchor,
            constant: -Chrome.contentInset
        )
        cardTopPinned = card.topAnchor.constraint(equalTo: findBar.bottomAnchor)
        // With the toolbar collapsed the card still starts below the traffic lights:
        // a page running under them would put its own content behind three buttons
        // the user cannot move.
        cardTopCollapsed = card.topAnchor.constraint(
            equalTo: root.topAnchor,
            constant: Chrome.trafficLightInset
        )
        toolbarTop = toolbar.topAnchor.constraint(equalTo: root.topAnchor)
        // Shifted right of the traffic lights whenever the sidebar is not there to
        // hold them, so the back button never lands under the close button.
        toolbarLeading = toolbar.leadingAnchor.constraint(equalTo: card.leadingAnchor)

        NSLayoutConstraint.activate([
            vibrancy.topAnchor.constraint(equalTo: root.topAnchor),
            vibrancy.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            vibrancy.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            vibrancy.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            tint.topAnchor.constraint(equalTo: root.topAnchor),
            tint.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tint.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarLeading,
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarWidth,

            dividerHandle.topAnchor.constraint(equalTo: root.topAnchor),
            dividerHandle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            dividerHandle.centerXAnchor.constraint(equalTo: sidebar.trailingAnchor),
            dividerHandle.widthAnchor.constraint(equalToConstant: 8),

            toolbarTop,
            toolbarLeading,
            toolbar.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            findBar.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            findBar.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            findBarHeight,

            cardTopPinned,
            cardLeadingPinned,
            cardTrailing,
            cardBottom,

            // The glass panels track the chrome they sit behind, inset slightly so
            // the frosted edge reads as a pane the content floats on rather than a
            // border drawn around it.
            sidebarGlass.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: Chrome.contentInset),
            sidebarGlass.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: Chrome.contentInset),
            sidebarGlass.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarGlass.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -Chrome.contentInset),

            toolbarGlass.topAnchor.constraint(equalTo: toolbar.topAnchor),
            toolbarGlass.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            toolbarGlass.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            toolbarGlass.bottomAnchor.constraint(equalTo: findBar.bottomAnchor),

            // Hot zones: a narrow strip down the leading edge, and one across the top
            // of the content. Both lie over the page and never take a click.
            sidebarHotZone.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarHotZone.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarHotZone.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarHotZone.widthAnchor.constraint(equalToConstant: Chrome.revealHotZone),

            toolbarHotZone.topAnchor.constraint(equalTo: root.topAnchor),
            toolbarHotZone.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            toolbarHotZone.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            toolbarHotZone.heightAnchor.constraint(
                equalToConstant: Chrome.trafficLightInset + Chrome.revealHotZone
            ),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        sidebar.delegate = self
        toolbar.delegate = self
        palette.delegate = self
        toolbar.setDownloadsVisible(false)

        downloads.onChange = { [weak self] in
            self?.toolbar.setDownloadsVisible(true)
        }

        dividerHandle.onDrag = { [weak self] location in
            guard let self, isSidebarPinned else { return }
            let width = location.clamped(to: Chrome.sidebarMinWidth...Chrome.sidebarMaxWidth)
            sidebarWidth.animator().constant = width
            restoredSidebarWidth = width
        }

        sidebarReveal = RevealLatch { [weak self] _ in
            self?.updateChromeLayout(animated: true)
        }
        toolbarReveal = RevealLatch { [weak self] _ in
            self?.updateChromeLayout(animated: true)
        }

        sidebarHotZone.onEnter = { [weak self] in self?.sidebarReveal.show() }
        toolbarHotZone.onEnter = { [weak self] in self?.toolbarReveal.show() }
        // The exit that matters is leaving the *panel*, not the strip that opened
        // it: the pointer crosses out of a 6pt strip the moment the sidebar appears
        // under it, so hiding on the strip's exit would close it instantly.
        sidebar.onPointerExit = { [weak self] in self?.sidebarReveal.hideSoon() }
        sidebar.onPointerEnter = { [weak self] in self?.sidebarReveal.show() }
        toolbar.onPointerExit = { [weak self] in self?.toolbarReveal.hideSoon() }
        toolbar.onPointerEnter = { [weak self] in self?.toolbarReveal.show() }

        findBar.onSearch = { [weak self] query, forwards in
            guard let self else { return }
            Task {
                let found = await self.selectedController?.find(query, forwards: forwards) ?? false
                self.findBar.reportMatch(found)
            }
        }
        findBar.onClose = { [weak self] in self?.hideFindBar() }

        card.onAddressRequested = { [weak self] in self?.focusAddressBar() }

        // Establishes the pinned arrangement without animating it: the window has
        // not been shown yet, and animating from an unset layout produces a visible
        // slide on launch.
        updateChromeLayout(animated: false)

        restoreSession()
    }

    // MARK: - Session

    private func restoreSession() {
        spaces = store.spacesEnsuringDefault()

        let savedSpaceID = UserDefaults.standard.string(forKey: Self.activeSpaceKey)
            .flatMap(UUID.init(uuidString:))
        activeSpace = spaces.first { $0.id == savedSpaceID } ?? spaces.first

        // Keyed on the store being empty rather than a "did seed" flag in
        // UserDefaults: the two can disagree — deleting the store leaves the flag
        // set, and the user gets a browser with no pins and no folders and no way to
        // discover that either feature exists.
        if let space = activeSpace, space.tabs.isEmpty, space.folders.isEmpty {
            seedFirstRun(into: space)
        }

        Launch.mark("spaces loaded")
        // Immediate, not coalesced: the window is shown at the end of this call
        // stack, and deferring would put an empty sidebar on screen for a frame.
        rebuildSidebarNow()
        Launch.mark("sidebar built")
        applyTint()

        // Restore the most recently used tab. Residency is seeded in the same
        // order, so a restored session suspends the same tabs the last one had.
        let ordered = (activeSpace?.tabs ?? [])
            .filter { !$0.isPinned }
            .sorted { $0.lastActivatedAt < $1.lastActivatedAt }

        // Deferred by one turn of the run loop, so the window is on screen before a
        // `WKWebView` is built. Creating one spins up a web content process and
        // installs the reader's user scripts — tens of milliseconds that used to sit
        // between launch and the user seeing anything at all. The sidebar, tint and
        // chrome above are all synchronous, so what appears first is a complete
        // window rather than an empty one.
        Task { @MainActor in
            await Task.yield()
            if let last = ordered.last {
                select(tabID: last.id)
            } else {
                newTab(url: nil)
            }
            Launch.mark("first tab realized")
            prefetchPinnedIcons()
        }
        trace("session", "restored \(spaces.count) spaces, \(activeSpace?.tabs.count ?? 0) tabs")
    }

    /// Fetch icons for pinned tabs that have never been opened.
    ///
    /// The pinned grid is icon-only, so a pin with no favicon is a grey square with
    /// a letter in it. Loading the page to get one would defeat suspension, so the
    /// icon is fetched on its own — one small request per pinned site, once.
    private func prefetchPinnedIcons() {
        let pending = (activeSpace?.tabs ?? []).filter { $0.isPinned && $0.faviconData == nil }
        guard !pending.isEmpty else { return }
        Task {
            for tab in pending {
                guard let url = tab.url else { continue }
                guard let data = await faviconService.iconData(pageURL: url, declared: nil) else {
                    continue
                }
                tab.faviconData = data
                sidebar.updateTab(id: tab.id, title: tab.displayTitle, icon: NSImage(data: data))
            }
            store.save()
        }
    }

    /// Give a brand-new window something to look at.
    ///
    /// Pinned records only — nothing is loaded until the user clicks one — so the
    /// pinned grid, a folder and the tab list are all populated on first launch
    /// without eight web views starting up behind the user's back.
    private func seedFirstRun(into space: Space) {
        for (index, seed) in Self.firstRunPins.enumerated() {
            store.addTab(
                to: space,
                url: URL(string: seed.url),
                title: seed.title,
                pinned: true,
                at: index
            )
        }
        store.addFolder(
            to: space,
            title: "Reading",
            items: [
                Bookmark(title: "Swift Evolution", urlString: "https://swift.org/swift-evolution/"),
                Bookmark(title: "WebKit Blog", urlString: "https://webkit.org/blog/"),
            ]
        )
    }

    private static let firstRunPins: [(title: String, url: String)] = [
        ("Apple", "https://www.apple.com"),
        ("GitHub", "https://github.com"),
        ("Hacker News", "https://news.ycombinator.com"),
        ("Wikipedia", "https://en.wikipedia.org"),
    ]

    /// Write everything back before the process goes away.
    ///
    /// Synchronous, and therefore without snapshots: `applicationWillTerminate` has
    /// no time budget for an async round trip to WebKit, and a missing placeholder
    /// image on relaunch is invisible next to a lost session.
    func persistBeforeTermination() {
        for controller in controllers.values where controller.isResident {
            guard let webView = controller.webView else { continue }
            controller.record.interactionState = webView.interactionState as? Data
            if let url = webView.url { controller.record.urlString = url.absoluteString }
            if let title = webView.title, !title.isEmpty { controller.record.title = title }
        }
        store.save()
        trace("session", "persisted \(controllers.count) tab controllers")
    }

    // MARK: - Tabs

    private var selectedController: TabController? {
        selectedTabID.flatMap { controllers[$0] }
    }

    private func controller(for record: Tab) -> TabController {
        if let existing = controllers[record.id] { return existing }
        let controller = TabController(record: record, faviconService: faviconService)
        controller.delegate = self
        controllers[record.id] = controller
        return controller
    }

    func select(tabID: UUID) {
        guard let record = (activeSpace?.tabs.first { $0.id == tabID }) ?? store.tab(id: tabID)
        else { return }

        // A tab in another space: follow it there rather than showing it out of
        // context, which is what ⌘K over all spaces implies.
        if let owner = record.space, owner.id != activeSpace?.id {
            switchTo(space: owner, selecting: tabID)
            return
        }

        let outgoing = selectedTabID == tabID ? nil : selectedController
        selectedTabID = tabID
        record.lastActivatedAt = .now

        let controller = self.controller(for: record)
        let wasResident = controller.isResident
        let webView = controller.realize()
        card.present(webView: webView, placeholder: wasResident ? nil : controller.snapshot)
        card.setStartPageVisible(record.url == nil)

        // Admit *after* realizing, so the tab that just became visible is the most
        // recently used and therefore cannot be the one evicted.
        let evicted = residency.activate(tabID)

        // Snapshot the outgoing tab before its web view leaves the hierarchy, then
        // suspend whatever fell out of the budget. Sequenced in one task because
        // both steps need the covered web views still attached.
        Task {
            await outgoing?.captureSnapshotForSuspension()
            card.discardCoveredWebViews()
            for id in evicted {
                await controllers[id]?.suspend()
            }
        }

        sidebar.setSelectedTab(tabID)
        // Leave address-bar editing behind. Without this, passing through a blank
        // tab (which focuses the address bar) latches the breadcrumb into edit mode
        // and every subsequent tab shows an empty field instead of its URL.
        if record.url != nil { toolbar.breadcrumb.endEditing() }
        updateToolbar()
        hideFindBar()
        store.save()

        if record.url == nil { focusAddressBar() }
        if !evicted.isEmpty {
            trace(
                "tabs",
                "select \(tabID.uuidString.prefix(4)) · resident \(residency.count)/\(residency.capacity)"
                    + " · suspended \(evicted.count) · footprint \(MemoryProbe.footprintDescription)"
            )
        }
    }

    @discardableResult
    func newTab(url: URL?, pinned: Bool = false) -> Tab? {
        guard let space = activeSpace else { return nil }
        let tab = store.addTab(to: space, url: url, pinned: pinned)
        rebuildSidebar()
        select(tabID: tab.id)
        return tab
    }

    func closeSelectedTab() {
        guard let id = selectedTabID else { return }
        close(tabID: id)
    }

    func close(tabID: UUID) {
        guard let record = activeSpace?.tabs.first(where: { $0.id == tabID }) else { return }

        // A pinned tab is a permanent fixture, so ⌘W resets it to its pinned URL
        // instead of removing it — the behaviour Arc and Safari's pinned tabs share.
        if record.isPinned {
            if let controller = controllers[tabID] {
                Task { await controller.suspend() }
            }
            residency.remove(tabID)
            selectNeighbour(of: tabID)
            return
        }

        let ordered = orderedSelectableTabs()
        let nextID = ordered.first { $0.id != tabID }?.id

        residency.remove(tabID)
        // Discard, not suspend: `store.close` deletes the record on the next line,
        // and an async suspension would then write captured state into a deleted
        // object, which SwiftData turns into a crash rather than a no-op.
        controllers.removeValue(forKey: tabID)?.discard()
        if selectedTabID == tabID { selectedTabID = nil }
        store.close(record)
        rebuildSidebar()

        if let nextID {
            select(tabID: nextID)
        } else {
            newTab(url: nil)
        }
    }

    private func selectNeighbour(of tabID: UUID) {
        let ordered = orderedSelectableTabs()
        if let next = ordered.first(where: { $0.id != tabID }) {
            select(tabID: next.id)
        }
    }

    /// Tab order as the sidebar shows it: pinned grid, then flat list, then groups.
    /// ⌘1–9 and ⌘⇧[ / ⌘⇧] walk this, so it has to match what the eye sees.
    private func orderedSelectableTabs() -> [Tab] {
        guard let space = activeSpace else { return [] }
        let pinned = space.tabs.filter(\.isPinned).sorted { $0.sortIndex < $1.sortIndex }
        let flat = space.tabs.filter { !$0.isPinned && $0.group == nil }
            .sorted { $0.sortIndex < $1.sortIndex }
        let grouped = space.groups
            .sorted { $0.sortIndex < $1.sortIndex }
            .flatMap { $0.tabs.sorted { $0.sortIndex < $1.sortIndex } }
        return pinned + flat + grouped
    }

    func cycleTab(by offset: Int) {
        let ordered = orderedSelectableTabs()
        guard !ordered.isEmpty,
            let current = ordered.firstIndex(where: { $0.id == selectedTabID })
        else { return }
        // Wraps, because a shortcut that stops at the end feels broken.
        let next = (current + offset + ordered.count) % ordered.count
        select(tabID: ordered[next].id)
    }

    func selectTab(atOrdinal ordinal: Int) {
        let ordered = orderedSelectableTabs()
        guard ordinal >= 1 else { return }
        // ⌘9 goes to the *last* tab, as in Safari and Chrome, rather than nothing
        // when there are fewer than nine.
        let index = ordinal == 9 ? ordered.count - 1 : ordinal - 1
        guard ordered.indices.contains(index) else { return }
        select(tabID: ordered[index].id)
    }

    // MARK: - Spaces

    func switchTo(space: Space, selecting tabID: UUID? = nil) {
        activeSpace = space
        UserDefaults.standard.set(space.id.uuidString, forKey: Self.activeSpaceKey)

        // Suspending the outgoing space's tabs is a policy choice, not a necessity:
        // spaces exist to separate contexts, and the tabs you left in Work should
        // not be holding web content processes while you read in Personal.
        for id in residency.drain() {
            if let controller = controllers[id] { Task { await controller.suspend() } }
        }

        applyTint()
        rebuildSidebar()

        let candidate =
            tabID
            ?? space.tabs.filter { !$0.isPinned }
                .max(by: { $0.lastActivatedAt < $1.lastActivatedAt })?.id
        if let candidate {
            select(tabID: candidate)
        } else {
            newTab(url: nil)
        }
    }

    func addSpace() {
        let tints = ["#6E7BF2", "#E0764A", "#3FA97A", "#C25AA0", "#4E9BD4"]
        let symbols = ["circle.fill", "square.fill", "triangle.fill", "hexagon.fill", "star.fill"]
        let index = spaces.count
        let space = store.addSpace(
            title: "Space \(index + 1)",
            tintHex: tints[index % tints.count],
            symbolName: symbols[index % symbols.count]
        )
        spaces = store.spaces()
        switchTo(space: space)
    }

    private func applyTint() {
        let color = activeSpace.flatMap { NSColor(hex: $0.tintHex) } ?? .systemIndigo
        tint.setTint(color)
    }

    // MARK: - Sidebar model

    /// Set while a rebuild is already scheduled for this turn of the run loop.
    private var sidebarRebuildScheduled = false

    /// Rebuild once, after the current call stack unwinds.
    ///
    /// Several operations change two things at once — closing a tab selects its
    /// neighbour, switching space re-selects a tab — and each used to rebuild the
    /// whole sidebar. Coalescing means the user's one action costs one rebuild.
    private func rebuildSidebar() {
        guard !sidebarRebuildScheduled else { return }
        sidebarRebuildScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            sidebarRebuildScheduled = false
            rebuildSidebarNow()
        }
    }

    private func rebuildSidebarNow() {
        spaces = store.spaces()
        guard let space = activeSpace else { return }
        pruneIconCache()

        var model = SidebarModel()
        model.spaces = spaces.map {
            .init(
                id: $0.id,
                title: $0.title,
                symbolName: $0.symbolName,
                tint: NSColor(hex: $0.tintHex) ?? .systemIndigo
            )
        }
        model.activeSpaceID = space.id
        model.selectedTabID = selectedTabID

        model.pinned = space.tabs.filter(\.isPinned)
            .sorted { $0.sortIndex < $1.sortIndex }
            .map { .init(id: $0.id, icon: icon(for: $0), title: $0.displayTitle) }

        model.folders = space.folders.sorted { $0.sortIndex < $1.sortIndex }
            .map {
                .init(id: $0.id, title: $0.title, isExpanded: $0.isExpanded, bookmarks: $0.items)
            }

        model.tabs = space.tabs.filter { !$0.isPinned && $0.group == nil }
            .sorted { $0.sortIndex < $1.sortIndex }
            .map(item(for:))

        model.groups = space.groups.sorted { $0.sortIndex < $1.sortIndex }
            .map { group in
                .init(
                    id: group.id,
                    title: group.title,
                    isExpanded: group.isExpanded,
                    tabs: group.tabs.sorted { $0.sortIndex < $1.sortIndex }.map(item(for:))
                )
            }

        sidebar.reload(model)
        installTabContextMenus()
    }

    private func item(for tab: Tab) -> SidebarModel.TabItem {
        .init(id: tab.id, title: tab.displayTitle, icon: icon(for: tab))
    }

    /// Decoded favicons, keyed by tab.
    ///
    /// `NSImage(data:)` decodes on every call, and the sidebar asks for every tab's
    /// icon on every rebuild — so opening one tab in a session of two hundred used
    /// to cost two hundred image decodes, and opening two hundred cost forty
    /// thousand. The stored `Data` is the cache key as well as the payload: a
    /// favicon that changes produces different bytes, which is exactly when the
    /// decoded copy must be thrown away.
    private var iconCache: [UUID: (data: Data, image: NSImage)] = [:]

    private func icon(for tab: Tab) -> NSImage? {
        guard let data = tab.faviconData else {
            iconCache[tab.id] = nil
            return nil
        }
        if let cached = iconCache[tab.id], cached.data == data {
            return cached.image
        }
        guard let image = NSImage(data: data) else { return nil }
        iconCache[tab.id] = (data, image)
        return image
    }

    /// Drops cache entries for tabs that no longer exist.
    private func pruneIconCache() {
        let live = Set((activeSpace?.tabs ?? []).map(\.id))
        iconCache = iconCache.filter { live.contains($0.key) }
    }

    private func installTabContextMenus() {
        guard let space = activeSpace else { return }
        for record in space.tabs {
            sidebar.setContextMenu(for: record.id, items: contextMenuItems(for: record))
        }
    }

    private func contextMenuItems(for record: Tab) -> [(String, () -> Void)] {
        let id = record.id
        let wasPinned = record.isPinned
        var items: [(String, () -> Void)] = [
            (wasPinned ? "Unpin" : "Pin", { [weak self] in self?.setPinned(!wasPinned, tabID: id) }),
            ("New Group from Tab", { [weak self] in self?.groupTab(id) }),
        ]
        if record.group != nil {
            items.append(("Remove from Group", { [weak self] in self?.ungroupTab(id) }))
        }
        items.append(("Close Tab", { [weak self] in self?.close(tabID: id) }))
        return items
    }

    func setPinned(_ pinned: Bool, tabID: UUID) {
        guard let record = activeSpace?.tabs.first(where: { $0.id == tabID }) else { return }
        record.isPinned = pinned
        if pinned { record.group = nil }
        record.sortIndex = (activeSpace?.tabs.filter { $0.isPinned == pinned }.count ?? 1) - 1
        store.save()
        rebuildSidebar()
        sidebar.setSelectedTab(selectedTabID)
    }

    private func groupTab(_ tabID: UUID) {
        guard let space = activeSpace,
            let record = space.tabs.first(where: { $0.id == tabID })
        else { return }
        let group = store.addGroup(to: space, title: record.url?.host() ?? "Group")
        record.group = group
        record.isPinned = false
        group.tabs.append(record)
        store.save()
        rebuildSidebar()
        sidebar.setSelectedTab(selectedTabID)
    }

    private func ungroupTab(_ tabID: UUID) {
        guard let record = activeSpace?.tabs.first(where: { $0.id == tabID }) else { return }
        record.group = nil
        store.save()
        rebuildSidebar()
        sidebar.setSelectedTab(selectedTabID)
    }

    // MARK: - Chrome

    private func updateToolbar() {
        let controller = selectedController
        toolbar.update(
            url: controller?.url,
            canGoBack: controller?.canGoBack ?? false,
            canGoForward: controller?.canGoForward ?? false,
            isLoading: controller?.isLoading ?? false
        )
        view.window?.title = controller?.title ?? "Zentic"
    }

    func focusAddressBar() {
        if isFocusMode { toggleFocusMode() }
        toolbar.breadcrumb.beginEditing()
    }

    /// ⌥⌘S — collapse the sidebar to an edge, or pin it back.
    ///
    /// Collapsed is not hidden: the sidebar slides out past the window edge and the
    /// page takes the space, but a strip along that edge stays live, so pushing the
    /// pointer into it floats the sidebar back over the page on glass. That is the
    /// difference between reclaiming space and losing your tabs.
    func toggleSidebar() {
        isSidebarPinned.toggle()
        if isSidebarPinned { sidebarReveal.hideImmediately() }
        updateChromeLayout(animated: true)
    }

    /// ⌥⌘T — the same treatment for the navigation controls.
    func toggleToolbar() {
        isToolbarPinned.toggle()
        if isToolbarPinned { toolbarReveal.hideImmediately() }
        updateChromeLayout(animated: true)
    }

    /// ⌘⇧F — content only.
    ///
    /// Collapses both, and drops the content inset so the page occupies the whole
    /// window. Both stay reachable by hover, and the traffic lights stay put: a
    /// window with no way to close it is a trap, not a feature.
    func toggleFocusMode() {
        isFocusMode.toggle()
        isSidebarPinned = !isFocusMode
        isToolbarPinned = !isFocusMode
        sidebarReveal.hideImmediately()
        toolbarReveal.hideImmediately()
        updateChromeLayout(animated: true)
    }

    /// Resolves every chrome constraint from ``isSidebarPinned``,
    /// ``isToolbarPinned``, ``isFocusMode`` and the two reveal latches.
    ///
    /// One function rather than a mutation per toggle, because the four
    /// combinations interact: with the sidebar collapsed there is no sidebar for the
    /// traffic lights to sit in, so both the card and the toolbar have to clear
    /// them — a rule that belongs in one place instead of being rediscovered in
    /// each toggle.
    private func updateChromeLayout(animated: Bool) {
        let sidebarShowing = isSidebarPinned || sidebarReveal.isRevealed
        let toolbarShowing = isToolbarPinned || toolbarReveal.isRevealed
        let inset = isFocusMode ? 0 : Chrome.contentInset
        // Vertical room the traffic lights need when no sidebar is holding them.
        let topClearance = isSidebarPinned ? inset : Chrome.trafficLightInset

        cardLeadingPinned.isActive = isSidebarPinned
        cardLeadingCollapsed.isActive = !isSidebarPinned
        cardTopPinned.isActive = isToolbarPinned
        cardTopCollapsed.isActive = !isToolbarPinned

        cardLeadingPinned.constant = inset
        cardLeadingCollapsed.constant = inset
        cardTopCollapsed.constant = topClearance
        cardTrailing.constant = -inset
        cardBottom.constant = -inset

        sidebarWidth.constant = restoredSidebarWidth
        // Far enough out to take the glass panel's shadow with it, or the collapsed
        // sidebar leaves a dark smear down the window edge.
        sidebarLeading.constant = sidebarShowing
            ? 0
            : -(restoredSidebarWidth + Chrome.glassShadowRadius + Chrome.contentInset)

        if isToolbarPinned {
            toolbarTop.constant = isSidebarPinned ? 0 : Chrome.trafficLightInset - Chrome.toolbarHeight
        } else {
            toolbarTop.constant = toolbarShowing
                ? topClearance + Chrome.contentInset
                : -(Chrome.toolbarHeight + Chrome.findBarHeight + Chrome.glassShadowRadius)
        }
        toolbarLeading.constant = isSidebarPinned ? 0 : Chrome.trafficLightInset - inset

        // Glass only while floating. Pinned chrome already has the window's vibrancy
        // behind it, and stacking a second blur pass on top costs a frame for
        // nothing.
        sidebarGlass.isHidden = isSidebarPinned
        toolbarGlass.isHidden = isToolbarPinned
        dividerHandle.isHidden = !isSidebarPinned
        sidebarHotZone.isArmed = !isSidebarPinned
        toolbarHotZone.isArmed = !isToolbarPinned
        card.setCornersRounded(!isFocusMode)

        let apply = {
            self.view.layoutSubtreeIfNeeded()
            // Hidden rather than merely off-screen once it has left: an off-screen
            // view still draws, and the sidebar is the most expensive thing here.
            self.sidebar.alphaValue = sidebarShowing ? 1 : 0
            self.toolbar.alphaValue = toolbarShowing ? 1 : 0
        }

        guard animated else {
            apply()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Chrome.revealDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            apply()
        }
    }

    func showFindBar() {
        findBarHeight.constant = Chrome.findBarHeight
        findBar.focus()
    }

    private func hideFindBar() {
        guard findBarHeight.constant > 0 else { return }
        findBarHeight.constant = 0
        view.window?.makeFirstResponder(selectedController?.webView)
    }

    func togglePalette() {
        guard let window = view.window else { return }
        palette.toggle(over: window)
    }

    func load(_ text: String) {
        guard let url = URLGuess.resolve(text) else { return }
        guard let controller = selectedController else {
            newTab(url: url)
            return
        }
        card.setStartPageVisible(false)
        controller.load(url)
        if controller.isResident {
            updateToolbar()
        } else {
            select(tabID: controller.id)
        }
    }

    // MARK: - Stress mode

    /// Open `count` tabs and report how many web views survive. `--stress 30`.
    ///
    /// The point is falsifiability: the M1 claim is that thirty tabs do not cost
    /// thirty web views, and this makes it measurable rather than asserted.
    ///
    /// Thirty *distinct* origins, deliberately. WebKit can serve several same-origin
    /// web views from one web content process, so thirty copies of one page would
    /// look economical whether suspension worked or not.
    func runStress(tabCount: Int) {
        trace("stress", "opening \(tabCount) tabs · \(MemoryProbe.totalDescription())")
        Task {
            for index in 0..<tabCount {
                let host = Self.stressHosts[index % Self.stressHosts.count]
                let suffix = index >= Self.stressHosts.count ? "/?n=\(index)" : ""
                newTab(url: URL(string: "https://\(host)\(suffix)"))
                try? await Task.sleep(for: .milliseconds(1_200))
                trace(
                    "stress",
                    "tab \(index + 1)/\(tabCount) \(host) · resident \(residency.count)"
                        + " · live \(controllers.values.filter(\.isResident).count)"
                        + " · \(MemoryProbe.totalDescription())"
                )
            }
            // Suspensions are async; give the last ones time to land before the final
            // reading, or it counts web views that are already doomed.
            try? await Task.sleep(for: .seconds(5))
            let live = controllers.values.filter(\.isResident).count
            trace(
                "stress",
                "DONE · \(controllers.count) tabs · \(live) live web views"
                    + " · budget \(residency.capacity) · \(MemoryProbe.totalDescription())"
            )
            // Accounts for what the shell itself is holding per tab. The stress run
            // showed shell memory growing with tabs *opened* rather than tabs
            // resident, which points at retained per-tab payloads rather than at
            // web views.
            trace(
                "stress",
                "web views · \(TrackedWebView.created) created · \(TrackedWebView.alive) still alive"
                    + " · sidebar rows \(SidebarRowView.created) created · \(SidebarRowView.alive) alive"
            )
            // A second reading once everything has quiesced. The first is taken five
            // seconds after the last tab, which catches both browsers mid-cleanup —
            // Safari was still releasing hundreds of megabytes a minute later, and
            // comparing its unsettled figure against our settled one would be a
            // rigged benchmark.
            try? await Task.sleep(for: .seconds(120))
            trace("stress", "SETTLED · \(MemoryProbe.totalDescription())")

            let records = activeSpace?.tabs ?? []
            let snapshots = records.reduce(0) { $0 + ($1.snapshotData?.count ?? 0) }
            let sessions = records.reduce(0) { $0 + ($1.interactionState?.count ?? 0) }
            let icons = records.reduce(0) { $0 + ($1.faviconData?.count ?? 0) }
            trace(
                "stress",
                String(
                    format: "payloads · %d records · snapshots %.1fMB · sessions %.1fMB · icons %.1fMB",
                    records.count,
                    Double(snapshots) / 1_048_576,
                    Double(sessions) / 1_048_576,
                    Double(icons) / 1_048_576
                )
            )
        }
    }

    private static let stressHosts = [
        "example.com", "www.iana.org", "en.wikipedia.org", "www.apple.com", "github.com",
        "news.ycombinator.com", "www.mozilla.org", "www.w3.org", "www.python.org", "www.swift.org",
        "www.kernel.org", "www.gnu.org", "www.debian.org", "archlinux.org", "www.rust-lang.org",
        "go.dev", "nodejs.org", "www.postgresql.org", "sqlite.org", "nginx.org",
        "curl.se", "www.openssl.org", "www.ietf.org", "home.unicode.org", "webkit.org",
        "clang.llvm.org", "www.sqlite.com", "www.redhat.com", "ubuntu.com", "www.freebsd.org",
    ]
}

// MARK: - Sidebar delegate

extension BrowserViewController: SidebarViewDelegate {
    func sidebar(_ sidebar: SidebarView, didSelectTab id: UUID) {
        select(tabID: id)
    }

    func sidebar(_ sidebar: SidebarView, didRequestCloseTab id: UUID) {
        close(tabID: id)
    }

    func sidebar(_ sidebar: SidebarView, didToggleGroup id: UUID) {
        guard let group = activeSpace?.groups.first(where: { $0.id == id }) else { return }
        group.isExpanded.toggle()
        store.save()
        rebuildSidebar()
    }

    func sidebar(_ sidebar: SidebarView, didToggleFolder id: UUID) {
        guard let folder = activeSpace?.folders.first(where: { $0.id == id }) else { return }
        folder.isExpanded.toggle()
        store.save()
        rebuildSidebar()
    }

    func sidebar(_ sidebar: SidebarView, didOpenBookmark urlString: String) {
        newTab(url: URL(string: urlString))
    }

    func sidebar(_ sidebar: SidebarView, didSelectSpace id: UUID) {
        guard let space = spaces.first(where: { $0.id == id }), space.id != activeSpace?.id else {
            return
        }
        switchTo(space: space)
    }

    func sidebar(_ sidebar: SidebarView, didRequestUnpinTab id: UUID) {
        setPinned(false, tabID: id)
    }

    func sidebarDidRequestNewTab(_ sidebar: SidebarView) {
        newTab(url: nil)
    }
}

// MARK: - Toolbar delegate

extension BrowserViewController: ContentToolbarDelegate {
    func toolbarDidToggleSidebar() { toggleSidebar() }
    func toolbarDidGoBack() { selectedController?.goBack() }
    func toolbarDidGoForward() { selectedController?.goForward() }

    func toolbarDidReload() {
        guard let controller = selectedController else { return }
        if controller.isLoading {
            controller.stopLoading()
        } else {
            controller.reload()
        }
        updateToolbar()
    }

    func toolbar(_ toolbar: ContentToolbar, didSubmitAddress text: String) {
        load(text)
    }

    func toolbarDidRequestDownloads(_ sender: NSView) {
        downloads.showPopover(relativeTo: sender)
    }
}

// MARK: - Tab controller delegate

extension BrowserViewController: TabControllerDelegate {
    func tabControllerDidChangeChrome(_ controller: TabController) {
        sidebar.updateTab(
            id: controller.id,
            title: controller.title,
            icon: controller.favicon
        )
        guard controller.id == selectedTabID else { return }
        updateToolbar()
        card.setStartPageVisible(controller.url == nil)
    }

    func tabControllerDidFinishLoad(_ controller: TabController) {
        guard controller.id == selectedTabID else { return }
        card.hidePlaceholder()
    }

    func tabController(_ controller: TabController, didCommit url: URL, title: String) {
        store.recordVisit(url: url, title: title)
    }

    func tabController(_ controller: TabController, wantsNewTabFor url: URL) {
        newTab(url: url)
    }

    func tabController(_ controller: TabController, didStart download: WKDownload) {
        downloads.attach(download)
    }
}

// MARK: - Palette delegate

extension BrowserViewController: CommandPaletteDelegate {
    /// Candidates in priority order — open tabs, spaces, actions, then history.
    ///
    /// The order is the tie-break: fuzzy scores collide constantly across sources,
    /// and "the tab I already have open" is almost always what was meant.
    func paletteItems(for query: String) -> [PaletteItem] {
        var items: [PaletteItem] = []

        for space in spaces {
            for tab in space.tabs.sorted(by: { $0.lastActivatedAt > $1.lastActivatedAt }) {
                let suffix = space.id == activeSpace?.id ? "" : " · \(space.title)"
                items.append(
                    .tab(
                        id: tab.id,
                        title: tab.displayTitle,
                        subtitle: (tab.url?.host() ?? tab.urlString) + suffix
                    )
                )
            }
        }

        if let url = URLGuess.resolve(query), !query.isEmpty {
            items.insert(.open(text: query, url: url), at: 0)
        }

        items += spaces.filter { $0.id != activeSpace?.id }.map { .space(id: $0.id, title: $0.title) }
        items += PaletteAction.allCases.map { .action($0) }
        items += store.recentHistory(limit: 600).map {
            .history(url: URL(string: $0.urlString) ?? URLGuess.searchURL(for: $0.title), title: $0.title)
        }
        return items
    }

    func palette(didChoose item: PaletteItem) {
        switch item {
        case .tab(let id, _, _):
            select(tabID: id)
        case .history(let url, _), .open(_, let url):
            newTab(url: url)
        case .space(let id, _):
            if let space = spaces.first(where: { $0.id == id }) { switchTo(space: space) }
        case .action(let action):
            perform(action)
        }
    }

    private func perform(_ action: PaletteAction) {
        switch action {
        case .newTab: newTab(url: nil)
        case .closeTab: closeSelectedTab()
        case .reload: selectedController?.reload()
        case .toggleOriginal: selectedController?.toggleReaderMode()
        case .toggleFocusMode: toggleFocusMode()
        case .toggleSidebar: toggleSidebar()
        case .findInPage: showFindBar()
        case .nextTab: cycleTab(by: 1)
        case .previousTab: cycleTab(by: -1)
        case .newSpace: addSpace()
        case .clearHistory: store.clearHistory()
        }
    }
}

// MARK: - Menu commands

extension BrowserViewController {
    @objc func newTabCommand(_ sender: Any?) { newTab(url: nil) }
    @objc func closeTabCommand(_ sender: Any?) { closeSelectedTab() }
    @objc func focusAddressCommand(_ sender: Any?) { focusAddressBar() }
    @objc func reloadCommand(_ sender: Any?) { selectedController?.reload() }
    @objc func goBackCommand(_ sender: Any?) { selectedController?.goBack() }
    @objc func goForwardCommand(_ sender: Any?) { selectedController?.goForward() }
    @objc func nextTabCommand(_ sender: Any?) { cycleTab(by: 1) }
    @objc func previousTabCommand(_ sender: Any?) { cycleTab(by: -1) }
    @objc func toggleOriginalCommand(_ sender: Any?) { selectedController?.toggleReaderMode() }
    @objc func findCommand(_ sender: Any?) { showFindBar() }
    @objc func paletteCommand(_ sender: Any?) { togglePalette() }
    @objc func toggleSidebarCommand(_ sender: Any?) { toggleSidebar() }
    @objc func toggleToolbarCommand(_ sender: Any?) { toggleToolbar() }
    @objc func toggleFocusModeCommand(_ sender: Any?) { toggleFocusMode() }
    @objc func newSpaceCommand(_ sender: Any?) { addSpace() }

    @objc func selectTabByOrdinal(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        selectTab(atOrdinal: item.tag)
    }

}

// Menu validation comes from `NSMenuItemValidation`, not `NSResponder`, so this is a
// conformance rather than an override — greying out Back and Forward is the only
// place it matters.
extension BrowserViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBackCommand): selectedController?.canGoBack ?? false
        case #selector(goForwardCommand): selectedController?.canGoForward ?? false
        default: true
        }
    }
}

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
