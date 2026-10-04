import AppKit
import Observation
import WebKit
import ZenticKit

/// Tells WebKit what happens to Zentic's windows and tabs, so extensions get
/// their `tabs.onCreated`, `onUpdated`, `onActivated` and the rest.
///
/// Rather than a call at every place a tab can open, close or change — a
/// dozen paths through `Browser` and `Tab` — it watches the observable model
/// and compares it with what it last reported. A burst of changes (a page
/// load sets URL, title and loading in quick succession) becomes one pass.
/// Nothing is watched until an extension is running.
@MainActor
final class ExtensionEvents {
    private let controller: WKWebExtensionController
    private var tabAdapters: [UUID: ExtensionTab] = [:]
    private var windowAdapters: [UUID: ExtensionWindow] = [:]

    /// What WebKit was last told about each open tab.
    private var reported: [UUID: Reported] = [:]
    private var reportedSelection: [UUID: UUID] = [:]
    private var isWatching = false
    /// Each registration of the observer gets a number; a stale one that
    /// fires after a newer registration is ignored.
    private var generation = 0

    private struct Reported {
        var window: UUID
        var index: Int
        var url: URL?
        var title: String
        var isLoading: Bool
        var isPinned: Bool
        var zoom: Double
    }

    init(controller: WKWebExtensionController) {
        self.controller = controller
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            let window = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated {
                guard let self, self.isWatching,
                    let browser = Windows.shared.open.first(where: { $0.window.map(ObjectIdentifier.init) == window })
                else { return }
                self.controller.didFocusWindow(self.window(for: browser))
            }
        }
    }

    func tab(for tab: Tab) -> ExtensionTab {
        if let adapter = tabAdapters[tab.id] { return adapter }
        let adapter = ExtensionTab(tab)
        tabAdapters[tab.id] = adapter
        return adapter
    }

    func window(for browser: Browser) -> ExtensionWindow {
        if let adapter = windowAdapters[browser.id] { return adapter }
        let adapter = ExtensionWindow(browser)
        windowAdapters[browser.id] = adapter
        return adapter
    }

    /// The first extension loaded. WebKit reads the windows and tabs open at
    /// that moment from the delegate, so they are recorded as already told.
    func start() {
        guard !isWatching else { return }
        isWatching = true
        reported = current()
        reportedSelection = selections()
        watch()
    }

    /// The last extension unloaded: stop paying for any of this.
    func stop() {
        isWatching = false
        generation += 1
        reported = [:]
        reportedSelection = [:]
        // With nothing running, nothing holds these; tabs closed from now on
        // would otherwise leave theirs behind.
        tabAdapters = [:]
        windowAdapters = [:]
    }

    func windowOpened(_ browser: Browser) {
        guard isWatching else { return }
        controller.didOpenWindow(window(for: browser))
        sync()
        watch()
    }

    func windowClosed(_ browser: Browser) {
        guard isWatching, let adapter = windowAdapters[browser.id] else { return }
        for (id, tab) in reported where tab.window == browser.id {
            if let tabAdapter = tabAdapters.removeValue(forKey: id) {
                controller.didCloseTab(tabAdapter, windowIsClosing: true)
            }
            reported[id] = nil
        }
        reportedSelection[browser.id] = nil
        controller.didCloseWindow(adapter)
        windowAdapters[browser.id] = nil
    }

    /// Report anything that changed now, rather than on the next turn — for a
    /// tab an extension just opened, which WebKit must know before it hears
    /// back about it.
    func sync() {
        guard isWatching else { return }
        let now = current()

        for id in reported.keys where now[id] == nil {
            if let adapter = tabAdapters.removeValue(forKey: id) {
                controller.didCloseTab(adapter, windowIsClosing: false)
            }
        }
        for browser in Windows.shared.open {
            for tab in browser.allTabs {
                guard let new = now[tab.id] else { continue }
                let adapter = self.tab(for: tab)
                guard let old = reported[tab.id] else {
                    controller.didOpenTab(adapter)
                    continue
                }
                if old.window != new.window {
                    controller.didMoveTab(adapter, from: old.index, in: windowAdapters[old.window])
                }
                var changed: WKWebExtension.TabChangedProperties = []
                if old.url != new.url { changed.insert(.URL) }
                if old.title != new.title { changed.insert(.title) }
                if old.isLoading != new.isLoading { changed.insert(.loading) }
                if old.isPinned != new.isPinned { changed.insert(.pinned) }
                if old.zoom != new.zoom { changed.insert(.zoomFactor) }
                if !changed.isEmpty { controller.didChangeTabProperties(changed, for: adapter) }
            }
        }
        reported = now

        let selected = selections()
        for (windowID, tabID) in selected where reportedSelection[windowID] != tabID {
            guard let adapter = tabAdapters[tabID] else { continue }
            let previous = reportedSelection[windowID].flatMap { tabAdapters[$0] }
            controller.didActivateTab(adapter, previousActiveTab: previous)
        }
        reportedSelection = selected
    }

    private func watch() {
        generation += 1
        let mine = generation
        withObservationTracking {
            for browser in Windows.shared.open {
                _ = browser.selectedTab
                for tab in browser.allTabs {
                    _ = (tab.url, tab.title, tab.isLoading, tab.pinnedURL, tab.zoom)
                }
            }
        } onChange: { [weak self] in
            // Called as the value is about to change: read it on the next turn.
            Task { @MainActor in
                guard let self, self.isWatching, self.generation == mine else { return }
                self.sync()
                self.watch()
            }
        }
    }

    private func current() -> [UUID: Reported] {
        var tabs: [UUID: Reported] = [:]
        for browser in Windows.shared.open {
            for (index, tab) in browser.allTabs.enumerated() {
                tabs[tab.id] = Reported(
                    window: browser.id, index: index, url: tab.url, title: tab.title,
                    isLoading: tab.isLoading, isPinned: tab.isPinned, zoom: tab.zoom)
            }
        }
        return tabs
    }

    private func selections() -> [UUID: UUID] {
        var selected: [UUID: UUID] = [:]
        for browser in Windows.shared.open {
            if let tab = browser.selectedTab { selected[browser.id] = tab.id }
        }
        return selected
    }
}

// MARK: - Tabs

/// A Zentic tab as extensions see it. WebKit tells tabs apart by identity, so
/// each tab has exactly one of these (see `ExtensionEvents.tab(for:)`).
///
/// A suspended tab has no web view; WebKit treats it as a tab that is not
/// loaded, and it gains one again when it is next shown.
@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    weak var tab: Tab?

    init(_ tab: Tab) { self.tab = tab }

    private var browser: Browser? { tab?.browser }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        browser.map(Extensions.shared.events.window(for:))
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tab, let index = browser?.allTabs.firstIndex(where: { $0 === tab }) else { return NSNotFound }
        return index
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { tab?.webView }
    func title(for context: WKWebExtensionContext) -> String? { tab?.title }
    func url(for context: WKWebExtensionContext) -> URL? { tab?.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { tab?.isLoading != true }
    func isPinned(for context: WKWebExtensionContext) -> Bool { tab?.isPinned == true }
    func isSelected(for context: WKWebExtensionContext) -> Bool { tab != nil && browser?.selectedTab === tab }
    func size(for context: WKWebExtensionContext) -> CGSize { tab?.webView?.bounds.size ?? .zero }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { tab?.zoom ?? 1 }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if let tab, let browser, tab.isPinned != pinned {
            pinned ? browser.pin(tab) : browser.unpin(tab)
        }
        completionHandler(nil)
    }

    func setZoomFactor(
        _ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void
    ) {
        tab?.zoom = min(max(zoomFactor, 0.3), 5)
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        tab?.load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if fromOrigin, let webView = tab?.webView { webView.reloadFromOrigin() } else { tab?.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        tab?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        tab?.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if let tab, let browser {
            browser.select(tab)
            browser.window?.makeKeyAndOrderFront(nil)
        }
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if let tab { browser?.close(tab) }
        completionHandler(nil)
    }

    func duplicate(
        using configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void
    ) {
        guard let tab, let browser else { return completionHandler(nil, nil) }
        let copy = browser.openTab(tab.url, after: tab, select: configuration.shouldBeActive)
        Extensions.shared.events.sync()
        completionHandler(Extensions.shared.events.tab(for: copy), nil)
    }

    func takeSnapshot(
        using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext,
        completionHandler: @escaping (NSImage?, Error?) -> Void
    ) {
        guard let webView = tab?.webView else { return completionHandler(nil, nil) }
        webView.takeSnapshot(with: configuration) { image, error in completionHandler(image, error) }
    }
}

// MARK: - Windows

/// A browser window as extensions see it. Its tabs are every space's, pinned
/// tabs first — spaces are Zentic's way of showing a window, not separate
/// windows, and a tab switching space has not moved anywhere an extension
/// could tell.
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var browser: Browser?

    init(_ browser: Browser) { self.browser = browser }

    private var window: NSWindow? { browser?.window }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        browser?.allTabs.map(Extensions.shared.events.tab(for:)) ?? []
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        browser?.selectedTab.map(Extensions.shared.events.tab(for:))
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isZoomed ? .maximized : .normal
    }

    func setWindowState(
        _ state: WKWebExtension.WindowState, for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let window else { return completionHandler(nil) }
        switch state {
        case .minimized: window.miniaturize(nil)
        case .fullscreen: if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        case .maximized: if !window.isZoomed { window.zoom(nil) }
        default:
            if window.isMiniaturized { window.deminiaturize(nil) }
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        }
        completionHandler(nil)
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { browser?.isPrivate == true }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        (window?.screen ?? NSScreen.main)?.frame ?? .zero
    }

    func frame(for context: WKWebExtensionContext) -> CGRect { window?.frame ?? .null }

    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        window?.setFrame(frame, display: true, animate: false)
        completionHandler(nil)
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        window?.performClose(nil)
        completionHandler(nil)
    }
}
