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
        let controller = TabController(
            record: record,
            faviconService: faviconService,
            instantOrigins: { [store] in store.instantOrigins() },
            resolveLevel: { [store, weak self] origin in
                store.resolution(for: origin, isRewriteEnabled: self?.isRewriteEnabled ?? false)
            }
        )
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
        let tab = store.addTab(
            to: space,
            url: url,
            pinned: pinned,
            at: insertionIndex(in: space, pinned: pinned)
        )
        rebuildSidebar()
        select(tabID: tab.id)
        return tab
    }

    /// Directly below the selected tab, which is where Safari and Arc both put a
    /// new one: a tab opened from the page you are reading — especially by
    /// ⌘-click — belongs beside its parent, not at the bottom of a long sidebar.
    ///
    /// Returns nil, meaning "at the end", when there is nothing comparable to sit
    /// after: no selection, or a selection in a different run (pinned, or inside a
    /// group) from the tab being created.
    private func insertionIndex(in space: Space, pinned: Bool) -> Int? {
        guard
            let selectedTabID,
            let current = space.tabs.first(where: { $0.id == selectedTabID }),
            current.isPinned == pinned,
            current.group == nil
        else { return nil }

        let siblings = space.tabs
            .filter { $0.isPinned == pinned && $0.group == nil }
            .sorted { $0.sortIndex < $1.sortIndex }
        guard let position = siblings.firstIndex(where: { $0.id == current.id }) else { return nil }
        return position + 1
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

    /// Tabs that reached the top stop before extraction had anything to rewrite.
    ///
    /// Jumping from Calm to Rewritten asks for two things at once, and the second
    /// cannot happen until the first has finished rendering. Rather than fail the
    /// click, the request waits here for the reveal that makes it possible.
    private var pendingRewriteTabs: Set<UUID> = []

    private static let rewriteEnabledKey = "zentic.rewriteEnabled"

    /// The global rewrite opt-in, off by default.
    ///
    /// Invariant 6's first clause. A per-site pin at Rewritten is a standing
    /// *permission*, and this is the switch that says permissions of that kind may
    /// be granted at all — so a user who has never opted in cannot reach the top
    /// stop by dragging a slider they were exploring.
    var isRewriteEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.rewriteEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.rewriteEnabledKey)
            updateToolbar()
        }
    }

    private static let tintStrengthKey = "zentic.tintStrength"

    /// How much of the space colour sits over the vibrancy. Persisted, because it
    /// is a taste setting the user makes once, not something to relearn each launch.
    private var tintStrength: TintStrength {
        get {
            UserDefaults.standard.string(forKey: Self.tintStrengthKey)
                .flatMap(TintStrength.init(rawValue:)) ?? .clear
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
        let cap = levelCeiling(for: controller)
        toolbar.apply(
            reader: ReaderControlState(
                rewrite: controller?.rewriteState ?? .none,
                level: controller?.level ?? .reader,
                automatic: controller?.automaticLevel ?? .reader,
                ceiling: cap.level,
                ceilingReason: cap.reason
            )
        )
        view.window?.title = controller?.title ?? "Zentic"
    }

    /// The highest stop this page can actually reach, and why.
    ///
    /// Invariant 2 is the interesting case: the bundle will decline to restructure
    /// an app whatever the control says, so offering Reader there would be offering
    /// something that cannot happen. Saying *why* beats being quietly inert.
    private func levelCeiling(for controller: TabController?) -> (level: PageLevel, reason: String?) {
        guard let controller else { return (.rewritten, nil) }

        if controller.extraction?.archetype == .app {
            return (
                .calm,
                "Zentic won't restructure an app. Mangling your mail client costs your"
                    + " trust; leaving it alone costs nothing."
            )
        }
        if !isRewriteEnabled {
            return (.reader, "Rewriting is off. Zentic ▸ Allow Rewriting turns it on.")
        }
        return (.rewritten, nil)
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

    func toolbar(_ toolbar: ContentToolbar, didSelectLevel level: PageLevel) {
        setLevel(level)
    }

    /// A stop the page cannot reach was clicked.
    ///
    /// The two reasons are not the same kind of thing, so they get different
    /// answers. Rewriting being off is the user's own setting and the click is them
    /// asking to change it — so offer. An app being unrestructurable is a decision
    /// the browser has made on their behalf, so explain it instead of offering a
    /// switch that does not exist.
    func toolbar(_ toolbar: ContentToolbar, didSelectBlockedLevel level: PageLevel) {
        let cap = levelCeiling(for: selectedController)

        if level == .rewritten && !isRewriteEnabled {
            let alert = NSAlert()
            alert.messageText = "Allow Zentic to rewrite pages?"
            alert.informativeText = """
                Rewriting sends a page's prose to a model and shows you its version. \
                Code, tables, maths and embeds are never sent.

                Rewritten text stays badged while it is shown, and ⌘\\ brings the \
                original straight back. Pages where exact wording matters ask again \
                each time.
                """
            alert.addButton(withTitle: "Allow Rewriting")
            alert.addButton(withTitle: "Not Now")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            isRewriteEnabled = true
            setLevel(.rewritten)
            return
        }

        guard let reason = cap.reason else { return }
        let alert = NSAlert()
        alert.messageText = "\(level.title) isn't available here"
        alert.informativeText = reason
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func toolbar(_ toolbar: ContentToolbar, didRequestLevelDetail sender: NSView) {
        guard let controller = selectedController, let origin = controller.url?.zenticOrigin else {
            return
        }
        presentLevelMenu(from: sender, origin: origin, current: controller.level)
    }

    /// Move this site to a level, remember it, and apply it.
    ///
    /// The two halves of "apply" are not the same kind of operation. Anything above
    /// the strip layer is live: entering the reader re-runs extraction against the
    /// DOM already in front of the user, and leaving it un-hides a document that was
    /// never destroyed. Changing what is *blocked* is not live — WebKit bakes
    /// `css-display-none` in at load and a request already sent cannot be recalled —
    /// so that one, and only that one, costs a reload.
    func setLevel(_ level: PageLevel) {
        guard let controller = selectedController else { return }
        let previous = controller.level
        guard level != previous else { return }

        if let origin = controller.url?.zenticOrigin {
            store.setPreference(.pinned(level), for: origin)
        }

        controller.setLevel(level)
        updateToolbar()
        sidebar.updateTransform(id: controller.id, state: transformState(for: controller.id))
        trace(
            "level",
            "\(previous.rawValue) → \(level.rawValue)"
                + (PageLevel.requiresReload(from: previous, to: level) ? " · reloading" : "")
        )

        // The top stop is the only one that *does* something beyond changing what
        // the page is allowed to be. Reaching it has to actually start a rewrite,
        // or it is a control that moves and achieves nothing.
        if level == .rewritten {
            startRewriteForTopStop(on: controller, revertingTo: previous)
        } else if previous == .rewritten {
            controller.discardRewrite()
            updateToolbar()
        }
    }

    /// Run the default rewrite on arrival at the top stop, and fall back down if it
    /// cannot happen — the rail must never sit on a level the page is not at.
    private func startRewriteForTopStop(on controller: TabController, revertingTo previous: PageLevel) {
        // Extraction has to have produced something rewritable first. Straight after
        // a jump from Calm the page may still be rendering, so this is not an error
        // — it is just not ready, and the honest answer is to wait for the reveal.
        guard controller.canRewrite else {
            if controller.level == .rewritten && !controller.didRestructure {
                pendingRewriteTabs.insert(controller.id)
            }
            return
        }
        if !requestRewrite(.simplify) {
            setLevel(previous)
        }
    }

    /// The detail menu behind the rail's label: the per-site memory, and the way
    /// back to letting the page decide.
    private func presentLevelMenu(from sender: NSView, origin: String, current: PageLevel) {
        let menu = NSMenu()
        let host = URL(string: origin)?.host() ?? origin
        menu.addItem(withTitle: host, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())

        let preference = store.preference(for: origin)
        let cap = levelCeiling(for: selectedController)

        let auto = NSMenuItem(
            title: "Automatic",
            action: #selector(setLevelAutoCommand(_:)),
            keyEquivalent: ""
        )
        auto.target = self
        auto.state = preference == .auto ? .on : .off
        menu.addItem(auto)

        menu.addItem(.separator())
        for level in PageLevel.allCases {
            let item = NSMenuItem(
                title: "Always \(level.title)",
                action: #selector(setLevelPinCommand(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = level.ordinal
            item.state = preference == .pinned(level) ? .on : .off
            item.isEnabled = level <= cap.level
            item.toolTip = level <= cap.level ? level.summary : cap.reason
            menu.addItem(item)
        }

        menu.addItem(.separator())
        for level in PageLevel.allCases where level < .rewritten {
            let item = NSMenuItem(
                title: "Never above \(level.title)",
                action: #selector(setLevelCeilingCommand(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = level.ordinal
            item.state = preference == .ceiling(level) ? .on : .off
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func applyPreference(_ preference: SitePreference) {
        guard let controller = selectedController, let origin = controller.url?.zenticOrigin
        else { return }
        store.setPreference(preference, for: origin, isRewriteEnabled: isRewriteEnabled)
        let resolved = store.resolution(for: origin, isRewriteEnabled: isRewriteEnabled)
        controller.setLevel(resolved.level)
        controller.refreshLevelResolution()
        updateToolbar()
    }

    @objc func setLevelAutoCommand(_ sender: Any?) { applyPreference(.auto) }
    /// Invariant 6's opt-in. Off until asked for, and asked for in one place.
    @objc func toggleRewriteEnabledCommand(_ sender: Any?) {
        isRewriteEnabled.toggle()
    }

    @objc func levelDownCommand(_ sender: Any?) { stepLevel(by: -1) }
    @objc func levelUpCommand(_ sender: Any?) { stepLevel(by: 1) }

    @objc func setLevelPinCommand(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let level = PageLevel.allCases[safe: item.tag]
        else { return }
        applyPreference(.pinned(level))
    }

    @objc func setLevelCeilingCommand(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let level = PageLevel.allCases[safe: item.tag]
        else { return }
        applyPreference(.ceiling(level))
    }

    /// ⌥⌘[ and ⌥⌘] — one stop down or up.
    func stepLevel(by delta: Int) {
        guard let controller = selectedController else { return }
        let all = PageLevel.allCases
        let cap = levelCeiling(for: controller).level
        let next = min(max(controller.level.ordinal + delta, 0), cap.ordinal)
        setLevel(all[next])
    }

    func toolbarDidRequestDiscardRewrite() {
        selectedController?.discardRewrite()
        updateToolbar()
        rebuildSidebar()
    }


    @objc func runRewritePreset(_ sender: NSMenuItem) {
        guard let preset = RewritePreset(rawValue: sender.tag) else { return }
        _ = requestRewrite(preset)
    }

    /// The one door to the rewrite layer.
    ///
    /// Every guard invariant 6 asks for lives here, and nowhere else: the model is
    /// never reached except through this function. The fidelity confirm used to sit
    /// inline in the menu handler, which made it a property of *that button* rather
    /// than of rewriting — so the level rail, arriving later as a second caller,
    /// would have walked straight past it.
    ///
    /// - Returns: whether a rewrite actually started.
    @discardableResult
    func requestRewrite(_ preset: RewritePreset) -> Bool {
        guard let controller = selectedController, controller.canRewrite else { return false }

        // News, medical, legal and financial pages need an explicit confirm,
        // because on those a re-voiced sentence stops being a style choice and
        // becomes a claim about what someone said.
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
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }

        controller.rewrite(
            tone: preset.tone,
            length: preset.length,
            readingLevel: preset.readingLevel
        )
        updateToolbar()
        return true
    }

    @objc func discardRewriteCommand(_ sender: Any?) { toolbarDidRequestDiscardRewrite() }

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
        // A rewrite asked for before the page had been rendered. The reveal is the
        // first moment it can happen, and the request is honoured once or dropped —
        // never retried on every chrome update.
        if pendingRewriteTabs.contains(controller.id), controller.canRewrite {
            pendingRewriteTabs.remove(controller.id)
            if controller.id == selectedTabID { requestRewrite(.simplify) }
        }

        sidebar.updateTab(
            id: controller.id,
            title: controller.title,
            icon: controller.favicon
        )
        sidebar.updateTransform(id: controller.id, state: transformState(for: controller.id))
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

    func tabController(
        _ controller: TabController,
        didExtract result: ExtractionResult,
        from url: URL
    ) {
        guard let origin = url.zenticOrigin else { return }
        // The extraction's own verdict, not whether the reader rendered: on an
        // origin already treated as instant the page is deliberately left alone
        // even when it would have restructured, and reading the render back would
        // then confirm its own assumption forever.
        store.recordReaderOutcome(
            origin: origin,
            wouldRestructure: result.confidence >= Budget.minConfidence
        )
        // What this page turned out to be, so the *next* page from this origin can
        // be levelled before anyone has looked at it.
        store.recordExtraction(
            origin: origin,
            archetype: result.archetype,
            isFidelitySensitive: result.isFidelitySensitive
        )
        // The one moment the origin's memory changes, so the one moment the cached
        // resolution needs re-reading. Doing it here rather than in `updateToolbar`
        // is the difference between a store fetch per extraction and one per frame.
        controller.refreshLevelResolution()
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

    /// Apply one of the built-in looks to this site, and remember it.
    ///
    /// Presentation is a separate axis from tone: a theme is lossless and
    /// reversible, so it carries no confirm, no badge and no ceremony — unlike a
    /// rewrite, which changes what the words say. That distinction is why these are
    /// a menu of their own rather than stops on the level rail.
    @objc func applyBuiltInThemeCommand(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
            let theme = ReaderTheme.allBuiltIn[safe: item.tag],
            let controller = selectedController
        else { return }

        let origin = controller.url?.host()
        controller.applyDesign(theme)
        Task { await RedesignController.shared.adopt(theme, for: origin) }
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

    /// Settings ▸ the BYO key. Stored in the Keychain, never in a file.
    @objc func setAPIKeyCommand(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "OpenAI API key"
        alert.informativeText = """
            Used only for redesign and cloud rewriting, sent only to OpenAI, and \
            stored in your login Keychain. Zentic has no server: your key never \
            reaches us.
            """
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = APIKeyStore.redacted(.openAI) ?? "sk-…"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            try? APIKeyStore.save(field.stringValue, for: .openAI)
        case .alertSecondButtonReturn:
            APIKeyStore.remove(.openAI)
        default:
            break
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

        case #selector(toggleRewriteEnabledCommand):
            menuItem.state = isRewriteEnabled ? .on : .off
            return true

        // The ladder's own state, ticked here rather than at build time: the menu
        // bar is assembled once at launch and these change per tab.
        case #selector(setLevelPinCommand):
            guard let level = PageLevel.allCases[safe: menuItem.tag] else { return false }
            menuItem.state = selectedController?.level == level ? .on : .off
            return level <= levelCeiling(for: selectedController).level

        case #selector(setLevelAutoCommand):
            guard let origin = selectedController?.url?.zenticOrigin else { return false }
            menuItem.state = store.preference(for: origin) == .auto ? .on : .off
            return true

        // The design axis only exists where the page is ours to draw. Below Reader
        // a theme would be applied to an overlay that is not on screen, which is a
        // menu item that appears to work and does nothing.
        case #selector(applyBuiltInThemeCommand), #selector(redesignSiteCommand),
            #selector(resetDesignCommand):
            return selectedController?.level.allowsTheme ?? false

        default: return true
        }
    }
}

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
