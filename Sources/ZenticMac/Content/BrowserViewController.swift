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
    private let lensPopover = LensPopover()

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

        // A lens saved, deleted or switched off changes what the page in front of
        // the user should look like, and the change can come from a popover this
        // controller did not open — a menu command, another window. One observer
        // rather than a refresh at each call site, so no path can forget.
        //
        // The selector-based registration is the one that unregisters itself when
        // this controller is deallocated, which matters because `LensController` is
        // a process-lifetime singleton and a window is not.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(lensesDidChange),
            name: LensController.didChangeLenses,
            object: nil
        )

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

    override func viewDidAppear() {
        super.viewDidAppear()
        // The traffic lights only have a frame once there is a window, and the
        // toolbar's row is measured from them. Cheap, and only on window show.
        updateChromeLayout(animated: false)
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

    private static let tintStrengthKey = "zentic.tintStrength"

    /// How much of the space colour sits over the vibrancy. Persisted, because it
    /// is a taste setting the user makes once, not something to relearn each launch.
    private var tintStrength: TintStrength {
        get {
            UserDefaults.standard.string(forKey: Self.tintStrengthKey)
                .flatMap(TintStrength.init(rawValue:)) ?? .glass
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.tintStrengthKey)
            applyTint()
        }
    }

    private func applyTint() {
        let color = activeSpace.flatMap { NSColor(hex: $0.tintHex) } ?? .systemIndigo
        tint.setTint(color)
        tint.setStrength(tintStrength)
    }

    /// Cycles the background through the tint presets — ⌥⌘B.
    func cycleTintStrength() {
        let all = TintStrength.allCases
        let next = all[((all.firstIndex(of: tintStrength) ?? 0) + 1) % all.count]
        tintStrength = next
        trace("chrome", "background \(next.title)")
    }

    func setTintStrength(_ strength: TintStrength) {
        tintStrength = strength
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
        .init(
            id: tab.id,
            title: tab.displayTitle,
            icon: icon(for: tab),
            transform: transformState(for: tab.id)
        )
    }

    /// What the tab's row should advertise. Only a resident tab can say — a
    /// suspended one has no page to describe, so it shows nothing rather than a
    /// stale claim.
    private func transformState(for tabID: UUID) -> SidebarModel.TabTransformState {
        guard let controller = controllers[tabID], controller.isResident else { return .original }
        switch controller.rewriteState {
        case .running: return .rewriting
        case .shown: return .rewritten
        case .none, .failed: return controller.isTransformed ? .transformed : .original
        }
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
        toolbar.apply(
            reader: ReaderControlState(
                mode: controller?.readerMode ?? .restructured,
                canTransform: controller?.didRestructure ?? false,
                canRewrite: controller?.canRewrite ?? false,
                rewrite: controller?.rewriteState ?? .none,
                lens: controller?.lensState ?? LensState()
            )
        )
        view.window?.title = controller?.title ?? "Zentic"

        if let origin = controller?.url?.host() {
            Task { @MainActor in toolbar.setShield(await Blocking.engine.shield(for: origin)) }
        } else {
            toolbar.setShield(.standard)
        }
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

    /// Where the traffic lights actually are, measured rather than assumed.
    ///
    /// With the sidebar collapsed the toolbar shares their row, so "close to the
    /// right place" is not good enough — a few points out and the address bar reads
    /// as a second row rather than one continuous strip. AppKit positions the
    /// buttons itself and the offsets differ by system version, so the only
    /// reliable source is the buttons.
    ///
    /// Returns the distance from the top of the content view to their vertical
    /// centre, and the x just past the rightmost one.
    private var trafficLightMetrics: (centerFromTop: CGFloat, trailingX: CGFloat) {
        guard
            let window = view.window,
            let close = window.standardWindowButton(.closeButton),
            let zoom = window.standardWindowButton(.zoomButton)
        else {
            // Before the window exists. `updateChromeLayout` runs again from
            // `viewDidAppear`, so this only ever shows for the first layout pass.
            return (Chrome.trafficLightInset / 2, Chrome.trafficLightInset)
        }
        let closeInRoot = view.convert(close.bounds, from: close)
        let zoomInRoot = view.convert(zoom.bounds, from: zoom)
        let centerFromTop = view.bounds.height - closeInRoot.midY
        return (centerFromTop, zoomInRoot.maxX)
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

        let lights = trafficLightMetrics
        // With no sidebar, the toolbar shares the traffic lights' row: centred on
        // them, and starting just past the zoom button. That is the whole point of
        // collapsing — the address bar moves up into space that was already spent
        // on window furniture, instead of costing a row of its own.
        let inlineTop = lights.centerFromTop - Chrome.toolbarHeight / 2

        if isToolbarPinned {
            toolbarTop.constant = isSidebarPinned ? 0 : inlineTop
        } else {
            toolbarTop.constant = toolbarShowing
                ? (isSidebarPinned ? topClearance + Chrome.contentInset : inlineTop)
                : -(Chrome.toolbarHeight + Chrome.findBarHeight + Chrome.glassShadowRadius)
        }
        toolbarLeading.constant = isSidebarPinned ? 0 : max(0, lights.trailingX + 10 - inset)

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

    func toolbar(_ toolbar: ContentToolbar, didSelectMode mode: ReaderMode) {
        guard let controller = selectedController else { return }
        guard controller.didRestructure else {
            // Snap back, then say why. Silently ignoring the click is what made
            // this corner of the toolbar feel broken.
            updateToolbar()
            explain(
                "Zentic left this page as it is, so there is nothing to switch between.",
                from: toolbar.modeAnchor
            )
            return
        }
        controller.setReaderMode(mode)
        updateToolbar()
        sidebar.updateTransform(id: controller.id, state: transformState(for: controller.id))
    }

    /// The blocking menu: this origin's shield, and the state of the lists.
    ///
    /// State, never a count. `WKContentRuleList` matches inside the network
    /// process and tells the app nothing about what it stopped, so the only
    /// honest numbers here are the ones we produced ourselves at compile time.
    func toolbarDidRequestShield(_ sender: NSView) {
        guard let controller = selectedController, let origin = controller.url?.host() else {
            explain("Blocking applies to a loaded site.", from: sender)
            return
        }
        Task { @MainActor in
            let current = await Blocking.engine.shield(for: origin)
            let menu = NSMenu()
            let header = NSMenuItem(title: origin, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())

            for state in ShieldState.allCases {
                let item = NSMenuItem(
                    title: Self.shieldTitle(state),
                    action: #selector(self.setShieldCommand(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = ShieldState.allCases.firstIndex(of: state) ?? 0
                item.state = state == current ? .on : .off
                menu.addItem(item)
            }

            menu.addItem(.separator())
            let update = NSMenuItem(
                title: "Update Filter Lists Now",
                action: #selector(self.updateFilterListsCommand(_:)),
                keyEquivalent: ""
            )
            update.target = self
            menu.addItem(update)

            let counts = (try? await Blocking.engine.installedRuleLists().count) ?? 0
            let status = NSMenuItem(
                title: counts == 0
                    ? "No filter lists compiled yet"
                    : "\(counts) compiled rule lists installed",
                action: nil,
                keyEquivalent: ""
            )
            status.isEnabled = false
            menu.addItem(status)

            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        }
    }

    private static func shieldTitle(_ state: ShieldState) -> String {
        switch state {
        case .standard: "Standard — ads, trackers, cookie walls"
        case .blockingOnly: "Blocking only — do not hide elements"
        case .off: "Off for this site"
        }
    }

    @objc private func setShieldCommand(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
            let state = ShieldState.allCases[safe: item.tag],
            let controller = selectedController,
            let origin = controller.url?.host()
        else { return }
        Task { @MainActor in
            await Blocking.engine.setShield(state, for: origin)
            controller.applyShield()
            toolbar.setShield(state)
            trace("blocking", "shield \(state.rawValue) for \(origin)")
        }
    }

    @objc private func updateFilterListsCommand(_ sender: Any?) {
        Task { @MainActor in
            let alert = NSAlert()
            do {
                let report = try await Blocking.engine.refresh(force: false)
                alert.messageText = report.listsUpdated.isEmpty
                    ? "Filter lists are up to date"
                    : "Updated \(report.listsUpdated.count) filter lists"
                // Compile-time facts, which we do know — unlike block counts.
                alert.informativeText = """
                    \(report.rulesCompiled) rules compiled, \(report.rulesDropped) dropped as \
                    inexpressible in Safari's rule syntax.
                    """
            } catch {
                alert.messageText = "Could not update filter lists"
                alert.informativeText = "\(error)"
                alert.alertStyle = .warning
            }
            alert.addButton(withTitle: "OK")
            if let window = view.window {
                alert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
    }

    /// The lens popover: every lens this site has, and what each one just did.
    func toolbarDidRequestLenses(_ sender: NSView) {
        guard let controller = selectedController, let url = controller.url, url.host() != nil
        else {
            explain("Lenses apply to a loaded site.", from: sender)
            return
        }
        Task { @MainActor in
            lensPopover.show(
                relativeTo: sender,
                host: url.host(),
                rows: await lensRows(for: controller, url: url),
                actions: lensActions(for: controller)
            )
        }
    }

    /// The stored set changed. See ``LensController/didChangeLenses``.
    ///
    /// Every resident tab, not just the selected one: a background tab on the same
    /// site is showing the lens that was just deleted, and it will keep showing it
    /// until the user goes back to it and reloads — the one moment they are certain
    /// the change did not work.
    @objc private func lensesDidChange() {
        for controller in controllers.values where controller.isResident {
            Task { await controller.refreshLenses() }
        }
        // A popover that is up is describing the set that just changed. Left alone
        // it keeps a row for a lens deleted in another window, and every action on
        // that row silently does nothing.
        refreshLensPopover()
    }

    /// Rebuild an open lens popover from the store, in place.
    ///
    /// Rebuilt rather than closed: the change that triggered this is usually one the
    /// user made *in* the popover — a checkbox, a delete — and closing the surface
    /// they are working in as a side effect of working in it reads as a crash.
    private func refreshLensPopover() {
        guard lensPopover.isShown,
            let controller = selectedController,
            let url = controller.url
        else { return }
        Task { @MainActor in
            lensPopover.update(
                rows: await lensRows(for: controller, url: url),
                actions: lensActions(for: controller)
            )
        }
    }

    /// One row per lens this site has, married to what it did on this page.
    ///
    /// Built from two sources on purpose. The rows come from the store, so a lens
    /// that is switched off or scoped to another path still has somewhere to be
    /// switched on from; the tallies come from the tab, which holds only what the
    /// page reported about the load in front of the user. Invariant 8 — a row shows
    /// `3/4` because a page said so, or it shows no number at all.
    private func lensRows(for controller: TabController, url: URL) async -> [LensPopover.Row] {
        let lenses = await LensController.shared.allLenses(for: url)
        let entries = Dictionary(
            controller.lensState.entries.map { ($0.lens.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return lenses.map { .init(lens: $0, entry: entries[$0.id]) }
    }

    private func lensActions(for controller: TabController) -> LensPopover.Actions {
        LensPopover.Actions(
            setEnabled: { lens, isEnabled in
                Task { await LensController.shared.setEnabled(isEnabled, id: lens.id) }
            },
            edit: { [weak self] lens in self?.editLens(lens, in: controller) },
            duplicate: { [weak self] lens in
                Task { @MainActor in
                    await LensController.shared.duplicate(id: lens.id, over: self?.view.window)
                }
            },
            refit: { [weak self] lens in self?.refit(lens, in: controller) },
            delete: { [weak self] lens in self?.confirmDelete(lens) },
            newLens: { [weak self] in self?.newLensCommand(nil) }
        )
    }

    /// Edit a lens — on a page that is actually running it, or not at all.
    ///
    /// The editor is only ever handed the page's *applied* set: enabled, and matching
    /// this URL's path pattern. The popover lists everything the site has, switched
    /// off and scoped-elsewhere rows included, so Edit on one of those named a lens
    /// the page had never been given. The overlay could not find it, fell back to
    /// authoring — blank, fresh id — and Save then wrote a **third** lens beside the
    /// two already there, with the one the user pressed Edit on untouched. A
    /// duplicate nobody asked for is the worst possible answer to "edit this".
    ///
    /// So the lens is brought onto the page first, or the user is told why it cannot
    /// be. Sending the whole lens down instead would let the editor open it anywhere,
    /// and that is worse than it sounds: the editor works by *pointing*, and a lens
    /// scoped to `/watch` has selectors written against a document this page is not.
    /// Every region would fail to resolve, the overlay would highlight nothing, and
    /// the scope control would be showing this page's pattern rather than the lens's
    /// — an editor that cannot show you what you are editing, and one keystroke from
    /// re-scoping the lens to the wrong place.
    private func editLens(_ lens: Lens, in controller: TabController) {
        Task { @MainActor in
            guard let url = controller.url else { return }
            // Resolved from the store, not from the row: the popover's rows are a
            // snapshot, and another window can have changed any of it since.
            guard var current = await LensController.shared.lens(id: lens.id) else {
                explain("“\(lens.name)” is no longer saved.", from: toolbar.lensAnchor)
                return
            }

            if !current.isEnabled {
                guard confirmSwitchOn(current) else { return }
                await LensController.shared.setEnabled(true, id: current.id)
                guard let switched = await LensController.shared.lens(id: current.id) else {
                    return
                }
                current = switched
            }

            // The store owns the matching rule — path pattern, last edit —
            // and asking it is how this stays the same answer the page will reach.
            let applies = await LensController.shared.lenses(for: url)
                .contains { $0.id == current.id }
            guard applies else {
                explain(
                    "“\(current.name)” is for this site's \(current.pathPattern) pages. "
                        + "Open one and press ⌥⌘L to edit it there.",
                    from: toolbar.lensAnchor
                )
                return
            }

            // The page has to be holding the lens before the editor is opened on it:
            // the overlay refuses an id it was not given, which is what stops the
            // silent duplicate, and refusing is not an error message anybody sees.
            await controller.refreshLenses()
            openLensEditor(in: controller) { $0.edit(lens: current, onUnavailable: $1) }
        }
    }

    /// Ask before switching a lens on to edit it. Enabling one changes the page
    /// behind the popover, so it is a decision rather than a side effect.
    private func confirmSwitchOn(_ lens: Lens) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Switch “\(lens.name)” on to edit it?"
        alert.informativeText = """
            The editor works by pointing at the page in front of you, so a lens has to \
            be running on it. This one is switched off. You can switch it back off in \
            the same list afterwards.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Switch On and Edit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Re-fit a drifted lens against the page as it is now.
    ///
    /// The catalog has to come from the live page rather than from anything stored:
    /// the whole premise of a re-fit is that the site changed, so a saved view of it
    /// is a description of the problem, not of the fix.
    private func refit(_ lens: Lens, in controller: TabController) {
        Task { @MainActor in
            guard let catalog = await controller.freshCatalog() else {
                explain(
                    "Zentic could not read this page's structure, so there is nothing to re-fit against.",
                    from: toolbar.lensAnchor
                )
                return
            }
            // No refresh afterwards: saving the re-fitted lens fires `observeChanges`,
            // which already queues one for every resident tab. Awaiting a second here
            // meant two passes over the same page for one repair.
            await LensController.shared.refit(lens: lens, catalog: catalog, over: view.window)
        }
    }

    /// Deleting is the one action here with nothing behind it — the ops came from a
    /// model call the user paid for, and there is no undo.
    private func confirmDelete(_ lens: Lens) {
        Task { @MainActor in
            // Asked of the store first. A row can outlive the lens it describes —
            // another window deletes it, this popover is a snapshot — and putting up
            // a "Delete “Focus”?" sheet for something that is already gone got a
            // considered yes and then did nothing at all.
            guard await LensController.shared.lens(id: lens.id) != nil else {
                explain(
                    "“\(lens.name)” is no longer saved — it was deleted somewhere else.",
                    from: toolbar.lensAnchor
                )
                return
            }

            let alert = NSAlert()
            alert.messageText = "Delete “\(lens.name)”?"
            alert.informativeText = """
                This site goes back to how it looks without the lens. Re-creating it means \
                describing it to the model again.
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            // And again on the way out: the sheet is modal for as long as the user
            // takes to read it, which is plenty of time to lose the race.
            guard await LensController.shared.delete(id: lens.id) else {
                explain(
                    "“\(lens.name)” was already deleted somewhere else.",
                    from: toolbar.lensAnchor
                )
                return
            }
        }
    }

    func toolbarDidRequestRewrite(_ sender: NSView) {
        guard let controller = selectedController else { return }
        guard controller.canRewrite else {
            explain(Self.rewriteBlockReason(for: controller), from: sender)
            return
        }
        presentRewriteMenu(from: sender, for: controller)
    }

    /// Why the rewrite button cannot run right now, in the user's terms.
    private static func rewriteBlockReason(for controller: TabController) -> String {
        if !controller.didRestructure {
            return "Zentic left this page as it is, so there is no prose to rewrite."
        }
        if controller.readerMode == .original {
            return "Switch to the transformed page (⌘\\) to rewrite it."
        }
        return "This page has nothing rewritable — only code, tables or embeds."
    }

    /// A one-line answer anchored to the control that was pressed.
    ///
    /// A menu rather than an alert: it is dismissed by the next click, it points at
    /// the control it is about, and it costs the user nothing to have opened.
    private func explain(_ message: String, from sender: NSView) {
        let menu = NSMenu()
        let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    func toolbarDidRequestDiscardRewrite() {
        selectedController?.discardRewrite()
        updateToolbar()
        rebuildSidebar()
    }

    /// The rewrite menu: one-click presets, then the axes spelled out.
    private func presentRewriteMenu(from sender: NSView, for controller: TabController) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Rewrite this page", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())

        for preset in RewritePreset.allCases {
            let item = NSMenuItem(
                title: preset.title,
                action: #selector(runRewritePreset(_:)),
                keyEquivalent: preset.keyEquivalent
            )
            item.keyEquivalentModifierMask = [.command, .shift]
            item.target = self
            item.tag = preset.rawValue
            item.toolTip = preset.detail
            menu.addItem(item)
        }

        if case .shown = controller.rewriteState {
            menu.addItem(.separator())
            let restore = NSMenuItem(
                title: "Show Original Text",
                action: #selector(discardRewriteCommand(_:)),
                keyEquivalent: ""
            )
            restore.target = self
            menu.addItem(restore)
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func runRewritePreset(_ sender: NSMenuItem) {
        guard let preset = RewritePreset(rawValue: sender.tag),
            let controller = selectedController,
            controller.canRewrite
        else { return }

        // Invariant 6: news, medical, legal and financial pages need an explicit
        // confirm, because on those a re-voiced sentence stops being a style
        // choice and becomes a claim about what someone said.
        if controller.needsFidelityConfirmation {
            let alert = NSAlert()
            alert.messageText = "Rewrite this page?"
            alert.informativeText = """
                This looks like news, medical, legal or financial content, where exact \
                wording matters. A rewrite is generated by a model and can lose nuance.

                The original stays one click away, and rewritten text is badged.
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Rewrite")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        controller.rewrite(
            tone: preset.tone,
            length: preset.length,
            readingLevel: preset.readingLevel
        )
        updateToolbar()
    }

    @objc func discardRewriteCommand(_ sender: Any?) { toolbarDidRequestDiscardRewrite() }

    /// ⌘⇧S — the headline action, straight to Simplify with no menu.
    @objc func simplifyCommand(_ sender: Any?) {
        guard let controller = selectedController, controller.canRewrite else { return }
        let item = NSMenuItem()
        item.tag = RewritePreset.simplify.rawValue
        runRewritePreset(item)
    }
}

/// The rewrite presets offered in the UI.
///
/// Presets rather than three separate pickers for tone, length and reading level:
/// the axes are real and the API exposes them, but a menu of twelve combinations
/// is a worse product than five that each answer a question someone actually has.
enum RewritePreset: Int, CaseIterable {
    case simplify
    case concise
    case bullets
    case plainEnglish
    case explain

    var title: String {
        switch self {
        case .simplify: "Simplify"
        case .concise: "Make Concise"
        case .bullets: "Summarise as Bullets"
        case .plainEnglish: "Plain English"
        case .explain: "Explain More"
        }
    }

    var detail: String {
        switch self {
        case .simplify: "Shorter sentences, common words, same facts."
        case .concise: "Cuts filler and repetition."
        case .bullets: "Turns each passage into a short list."
        case .plainEnglish: "Removes jargon without shortening."
        case .explain: "Unpacks what is there — never adds facts."
        }
    }

    var keyEquivalent: String {
        switch self {
        case .simplify: "s"
        default: ""
        }
    }

    var tone: Tone {
        switch self {
        case .simplify, .plainEnglish: .plain
        case .concise, .bullets: .concise
        case .explain: .neutral
        }
    }

    var length: LengthPreference {
        switch self {
        case .simplify: .shorter
        case .concise: .shorter
        case .bullets: .bullets
        case .plainEnglish: .asIs
        case .explain: .expanded
        }
    }

    var readingLevel: ReadingLevel? {
        switch self {
        case .simplify: .simple
        case .plainEnglish: .general
        default: nil
        }
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
        sidebar.updateTransform(id: controller.id, state: transformState(for: controller.id))
        guard controller.id == selectedTabID else { return }
        updateToolbar()
        // The popover is drawn from the same two sources the badge is, and only one
        // of them was refreshing it. With the list open, a report arriving moved the
        // toolbar's `3/4` to `4/4` while the row underneath kept saying `3/4` — two
        // numbers about one page, disagreeing, on screen at once.
        refreshLensPopover()
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
    @objc func cycleTintCommand(_ sender: Any?) { cycleTintStrength() }

    @objc func setTintStrengthCommand(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
            let strength = TintStrength.allCases[safe: item.tag]
        else { return }
        setTintStrength(strength)
    }

    /// Recolour the active space. The tint is the space's identity, so this edits
    /// the record rather than a global preference.
    @objc func pickSpaceColorCommand(_ sender: Any?) {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(spaceColorChanged(_:)))
        panel.color = activeSpace.flatMap { NSColor(hex: $0.tintHex) } ?? .systemIndigo
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func spaceColorChanged(_ sender: NSColorPanel) {
        guard let space = activeSpace,
            let srgb = sender.color.usingColorSpace(.sRGB)
        else { return }
        space.tintHex = String(
            format: "#%02X%02X%02X",
            Int((srgb.redComponent * 255).rounded()),
            Int((srgb.greenComponent * 255).rounded()),
            Int((srgb.blueComponent * 255).rounded())
        )
        store.save()
        applyTint()
        rebuildSidebar()
    }

    /// ⌥⌘D — describe a look, and keep it for this site.
    @objc func redesignSiteCommand(_ sender: Any?) {
        guard let controller = selectedController else { return }
        let origin = controller.url?.host()
        Task { @MainActor in
            guard
                let theme = await RedesignController.shared.promptForDesign(
                    origin: origin,
                    over: view.window
                )
            else { return }
            controller.applyDesign(theme)
        }
    }

    /// ⇧⌥⌘D — hand the whole page to the model to lay out in HTML.
    @objc func rebuildPageCommand(_ sender: Any?) {
        guard let controller = selectedController else { return }
        guard let extraction = controller.currentExtraction, controller.didRestructure else {
            explain(
                "Zentic left this page as it is, so there is nothing to rebuild.",
                from: toolbar.modeAnchor
            )
            return
        }
        Task { @MainActor in
            guard
                let document = await RedesignController.shared.promptForDocument(
                    extraction: extraction,
                    origin: controller.url?.host(),
                    over: view.window
                )
            else { return }
            controller.applyGeneratedDocument(document)
        }
    }

    /// Drop this site's design and fall back to the default.
    @objc func resetDesignCommand(_ sender: Any?) {
        guard let controller = selectedController else { return }
        let origin = controller.url?.host()
        Task { @MainActor in
            await RedesignController.shared.forget(origin: origin)
            // Reloads rather than pushing a default theme: the renderer's own
            // default is defined by the bundle, not by anything we hold here.
            controller.reload()
        }
    }

    /// ⌥⌘L — the in-page lens editor, on or off.
    ///
    /// A toggle rather than an opener because the editor covers the page it is
    /// editing: the shortcut that put a scrim over the article has to be the one
    /// that takes it away, or the user is hunting for an exit while looking at
    /// something they cannot read.
    ///
    /// Both halves say something when they cannot do anything. Pressing a shortcut
    /// and getting silence is the failure that gets reported as "lenses are broken".
    @objc func lensEditorCommand(_ sender: Any?) {
        guard let controller = selectedController, controller.url?.host() != nil else {
            explain("Lenses apply to a loaded site.", from: toolbar.lensAnchor)
            return
        }
        // Closing is never gated, whatever is on screen.
        guard !controller.isLensEditing else {
            controller.setLensMode(false)
            return
        }
        openLensEditor(in: controller) { $0.setLensMode(true, onUnavailable: $1) }
    }

    /// ⇧⌥⌘L — start a new lens for this site.
    ///
    /// The same overlay, entered rather than toggled: someone who asked for a new
    /// lens while the editor happened to be open meant "open it", never "close it".
    @objc func newLensCommand(_ sender: Any?) {
        guard let controller = selectedController, controller.url?.host() != nil else {
            explain("Lenses apply to a loaded site.", from: toolbar.lensAnchor)
            return
        }
        openLensEditor(in: controller) { $0.setLensMode(true, onUnavailable: $1) }
    }

    /// Open the in-page editor, once the page is one it can honestly be opened on.
    ///
    /// The editor works by pointing: it outlines the regions of the live document
    /// and asks the user to click the one they mean. The reader hides that document
    /// with `visibility: hidden` rather than removing it, so layout survives and
    /// every rect in the catalog is *correct* — correct about a document the user
    /// cannot see. Opening it over the reader's own render draws accurate outlines
    /// of boxes that are not on screen, in positions that have nothing to do with
    /// what is. So the original is offered first, rather than the editor being
    /// disabled outright: the page the lens acts on is one keystroke away, and
    /// switching to it is the thing the user was going to have to do anyway.
    private func openLensEditor(
        in controller: TabController,
        _ open: (TabController, @escaping @MainActor () -> Void) -> Void
    ) {
        let unavailable: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            explain(
                "There is no page here for a lens to act on — a PDF or an error page has no "
                    + "structure to point at.",
                from: toolbar.lensAnchor
            )
        }

        guard controller.isTransformed else {
            open(controller, unavailable)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Show the original page first?"
        alert.informativeText = """
            A lens acts on the site's own page, and you are looking at Zentic's \
            rendering of it. The editor would outline boxes you cannot see.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Show Original")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        controller.setReaderMode(.original)
        updateToolbar()
        open(controller, unavailable)
    }

    /// The lens list, from the keyboard. Same surface the toolbar button opens.
    @objc func manageLensesCommand(_ sender: Any?) {
        toolbarDidRequestLenses(toolbar.lensAnchor)
    }

    /// Settings ▸ the BYO key. Stored in the Keychain, never in a file.
    @objc func setAPIKeyCommand(_ sender: Any?) {
        RedesignController.shared.promptForAPIKey()
    }

    /// Which model draws generated designs. Tag is `DesignModel.allCases` order.
    @objc func setDesignModelCommand(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
            let model = RedesignController.DesignModel.allCases[safe: item.tag]
        else { return }
        RedesignController.shared.designModel = model
        if model == .openAI, !APIKeyStore.has(.openAI) {
            RedesignController.shared.promptForAPIKey()
        }
    }

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
        case #selector(goBackCommand): return selectedController?.canGoBack ?? false
        case #selector(goForwardCommand): return selectedController?.canGoForward ?? false
        case #selector(lensEditorCommand), #selector(newLensCommand),
            #selector(manageLensesCommand):
            // A lens is per-origin and acts on a live DOM, so both halves have to
            // exist: a blank tab has no site to save one for, and a `file:` or
            // `about:` page has no host to key one on.
            return selectedController?.url?.host() != nil
        case #selector(setDesignModelCommand):
            menuItem.state =
                RedesignController.DesignModel.allCases[safe: menuItem.tag]
                == RedesignController.shared.designModel ? .on : .off
            return true
        default: return true
        }
    }
}

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
