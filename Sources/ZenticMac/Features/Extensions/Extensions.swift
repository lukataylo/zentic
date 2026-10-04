import AppKit
import Observation
import WebKit
import ZenticKit

/// Safari Web Extensions: the controller every tab's web view shares, which
/// extensions run in it, and what the user has allowed each one to do.
@MainActor
@Observable
final class Extensions {
    static let shared = Extensions()

    /// One for every web view, private windows' included. WebKit keeps an
    /// extension out of private windows — their web views use a
    /// non-persistent data store — unless its context has
    /// `hasAccessToPrivateData`, which is the user's "Allow in Private Windows".
    @ObservationIgnored let controller: WKWebExtensionController
    @ObservationIgnored let events: ExtensionEvents
    /// Where each extension's toolbar button is, for its popup to point at.
    @ObservationIgnored let anchors = ExtensionAnchors()
    @ObservationIgnored private let delegate = ExtensionControllerDelegate()

    /// What the user turned on or answered, in the order extensions were
    /// added — which is also their order in the toolbar.
    private(set) var records: [ExtensionRecord] = [] {
        didSet { if records != oldValue { scheduleSave() } }
    }
    /// Extensions loaded into the controller, by record id.
    private(set) var contexts: [String: WKWebExtensionContext] = [:]
    /// Extensions read from disk, running or not, by record id — what
    /// Settings describes.
    private(set) var parsed: [String: WKWebExtension] = [:]
    /// The Safari extensions in installed apps, as of the last look.
    private(set) var installed: [ExtensionDiscovery.Found] = []
    /// Why an extension could not be read or started, by record id.
    private(set) var failures: [String: String] = [:]
    /// Bumped when an extension changes its button — icon, label, badge —
    /// since WebKit's action objects are not observable themselves.
    private(set) var actionRevision = 0
    /// Questions for the user, oldest first. Each is shown from its
    /// extension's toolbar button in the window it concerns.
    var prompts: [ExtensionPrompt] = []

    @ObservationIgnored private let file = JSONFile<[ExtensionRecord]>(name: "extensions.json")
    @ObservationIgnored private let io = DispatchQueue(label: "Zentic.extensions", qos: .utility)
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loadedRecords = false
    /// Sites allowed from a private window, by record id. In force until
    /// quit and never written down: a private window writes nothing to disk.
    @ObservationIgnored private var privateSites: [String: [String: Date]] = [:]
    /// Set while a private window's question is being answered, so the grants
    /// WebKit makes in reply stay out of the saved record.
    @ObservationIgnored private var answeringPrivately = false
    @ObservationIgnored private var shortcutMonitor: Any?
    /// "Not Now" answers to a click, as "record-id pattern", for this run.
    @ObservationIgnored private var notNow: Set<String> = []

    private init() {
        let configuration: WKWebExtensionController.Configuration =
            DataDirectory.isIsolated ? .init(identifier: DataDirectory.isolationID) : .default()
        configuration.defaultWebsiteDataStore = .zentic
        controller = WKWebExtensionController(configuration: configuration)
        events = ExtensionEvents(controller: controller)
        controller.delegate = delegate
        observeGrants()
    }

    // MARK: - Launch

    /// Read the saved choices off the main thread and start what was on. The
    /// first window does not wait; its page gets the extensions' content
    /// scripts from its next load if it beat them.
    func start() {
        Task {
            let file = self.file
            let saved = await Task.detached(priority: .userInitiated) { file.load() ?? [] }.value
            records = saved
            loadedRecords = true
            for record in saved where record.isEnabled { await run(record.id) }
        }
    }

    // MARK: - Reading

    func record(_ id: String) -> ExtensionRecord? { records.first { $0.id == id } }

    func isRunning(_ id: String) -> Bool { contexts[id] != nil }

    func name(_ id: String) -> String {
        parsed[id]?.displayName ?? installed.first { "app:\($0.bundleID)" == id }?.appName ?? "Extension"
    }

    /// The extension a `webkit-extension://` page belongs to — its options
    /// page, say — for the address bar to name it.
    func name(ofPage url: URL?) -> String? {
        guard let url, url.scheme == "webkit-extension" else { return nil }
        return controller.extensionContext(for: url)?.webExtension.displayName
    }

    struct Listing: Identifiable {
        let id: String
        var appName: String?
        var isFolder: Bool
    }

    /// Everything Settings lists: each installed app's extension, and any
    /// recorded one that is not among them (a folder, or an app since deleted).
    var listings: [Listing] {
        var all = installed.map { Listing(id: "app:\($0.bundleID)", appName: $0.appName, isFolder: false) }
        for record in records where !all.contains(where: { $0.id == record.id }) {
            if case .folder = record.source {
                all.append(Listing(id: record.id, isFolder: true))
            } else {
                all.append(Listing(id: record.id, isFolder: false))
            }
        }
        return all.sorted { name($0.id).localizedStandardCompare(name($1.id)) == .orderedAscending }
    }

    struct ToolbarItem: Identifiable {
        let id: String
        let context: WKWebExtensionContext
    }

    /// The running extensions with a button in a window, in toolbar order.
    func toolbarItems(privateWindow: Bool) -> [ToolbarItem] {
        records.compactMap { record in
            guard let context = contexts[record.id], !privateWindow || context.hasAccessToPrivateData else { return nil }
            return ToolbarItem(id: record.id, context: context)
        }
    }

    // MARK: - Turning on and off

    func setEnabled(_ on: Bool, _ id: String) {
        if record(id) == nil, on, let found = installed.first(where: { "app:\($0.bundleID)" == id }) {
            records.append(ExtensionRecord(source: .app(bundleID: found.bundleID, path: found.path.path)))
        }
        update(id) { $0.isEnabled = on }
        if on { Task { await run(id) } } else { stop(id) }
    }

    func setAllowsPrivateWindows(_ on: Bool, _ id: String) {
        update(id) { $0.allowsPrivateWindows = on }
        contexts[id]?.hasAccessToPrivateData = on
    }

    /// Read and start one extension, if it is still meant to be on.
    private func run(_ id: String) async {
        guard let record = record(id), record.isEnabled, contexts[id] == nil else { return }
        do {
            let webExtension = try await load(record.source)
            // Turned off, or started by another caller, while it was read.
            guard self.record(id)?.isEnabled == true, contexts[id] == nil, let record = self.record(id) else { return }
            let context = WKWebExtensionContext(for: webExtension)
            context.uniqueIdentifier = record.storageID
            context.isInspectable = true
            context.hasAccessToPrivateData = record.allowsPrivateWindows
            restore(record.grants.live(at: .now), into: context, id: id)
            // As in Safari, turning an extension on accepts the API permissions
            // its manifest lists. Only websites are asked about, one by one.
            for permission in webExtension.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            try controller.load(context)
            contexts[id] = context
            failures[id] = nil
            if contexts.count == 1 { events.start() }
            updateShortcuts()
        } catch {
            failures[id] = error.localizedDescription
        }
    }

    private func stop(_ id: String) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        try? controller.unload(context)
        prompts.removeAll { $0.extensionID == id }
        if contexts.isEmpty { events.stop() }
        updateShortcuts()
    }

    private func load(_ source: ExtensionRecord.Source) async throws -> WKWebExtension {
        if let known = parsed[source.key] { return known }
        let webExtension: WKWebExtension
        switch source {
        case .app(let bundleID, let path):
            var bundle = Bundle(path: path)
            if bundle == nil, let moved = await relocate(bundleID) { bundle = Bundle(url: moved) }
            guard let bundle else { throw LoadError.appMissing }
            webExtension = try await WKWebExtension(appExtensionBundle: bundle)
        case .folder(let path):
            webExtension = try await WKWebExtension(resourceBaseURL: URL(filePath: path, directoryHint: .isDirectory))
        }
        parsed[source.key] = webExtension
        return webExtension
    }

    /// The app was moved or updated to a new place since it was recorded.
    private func relocate(_ bundleID: String) async -> URL? {
        await lookForInstalled()
        return installed.first { $0.bundleID == bundleID }?.path
    }

    enum LoadError: LocalizedError {
        case appMissing, noWindow
        var errorDescription: String? {
            switch self {
            case .appMissing: "The app that contains this extension is no longer installed."
            case .noWindow: "There is no window to show it in."
            }
        }
    }

    // MARK: - Finding and adding

    /// Look through installed apps for Safari extensions, and read each one
    /// so Settings can describe it.
    func lookForInstalled() async {
        let found = await Task.detached(priority: .userInitiated) {
            ExtensionDiscovery.appExtensions(in: ExtensionDiscovery.applicationDirectories)
        }.value
        installed = found
        for item in found {
            let id = "app:\(item.bundleID)"
            if let index = records.firstIndex(where: { $0.id == id }), records[index].source.path != item.path.path {
                records[index].source = .app(bundleID: item.bundleID, path: item.path.path)
                parsed[id] = nil
            }
            guard parsed[id] == nil else { continue }
            do {
                _ = try await load(.app(bundleID: item.bundleID, path: item.path.path))
            } catch {
                failures[id] = error.localizedDescription
            }
        }
    }

    /// Load Unpacked Extension: read the folder, and turn it on — a developer
    /// choosing a folder wants to see it run.
    func addFolder(_ url: URL) async throws {
        let source = ExtensionRecord.Source.folder(path: url.standardizedFileURL.path)
        parsed[source.key] = nil
        _ = try await load(source)
        if record(source.key) == nil { records.append(ExtensionRecord(source: source)) }
        if isRunning(source.key) { await reload(source.key) } else { setEnabled(true, source.key) }
    }

    /// Read a folder extension from disk again, after its developer changed it.
    func reload(_ id: String) async {
        stop(id)
        parsed[id] = nil
        failures[id] = nil
        if case .folder(let path)? = record(id)?.source {
            do { _ = try await load(.folder(path: path)) } catch { failures[id] = error.localizedDescription }
        }
        await run(id)
    }

    /// Forget an extension: stop it, drop what the user allowed, and delete
    /// the data it stored in Zentic. The app that ships it is left alone.
    func remove(_ id: String) async {
        let storageID = record(id)?.storageID
        stop(id)
        records.removeAll { $0.id == id }
        privateSites[id] = nil
        failures[id] = nil
        if id.hasPrefix("folder:") { parsed[id] = nil }
        guard let storageID else { return }
        let types = WKWebExtensionController.allExtensionDataTypes
        let stored = await controller.dataRecords(ofTypes: types).filter { $0.uniqueIdentifier == storageID }
        if !stored.isEmpty {
            await withCheckedContinuation { done in controller.removeData(ofTypes: types, from: stored) { done.resume() } }
        }
    }

    // MARK: - Websites

    /// Every pattern the extension asks for, content scripts' included.
    func requestedSites(_ id: String) -> Set<String> {
        Set(parsed[id]?.allRequestedMatchPatterns.map(\.string) ?? [])
    }

    func siteAccess(_ id: String) -> SiteAccess {
        let saved = record(id)?.grants.sites.keys.map { $0 } ?? []
        let unsaved = privateSites[id]?.keys.map { $0 } ?? []
        return SiteAccess(requested: requestedSites(id), granted: Set(saved + unsaved))
    }

    /// Everywhere it asks for, or only where allowed one site at a time.
    func setAllSites(_ on: Bool, _ id: String) {
        let requested = requestedSites(id)
        changeSites(id) { sites in
            for pattern in requested { sites[pattern] = on ? .distantFuture : nil }
        }
    }

    /// Whether the extension asks for a site at all — allowing one it never
    /// asked for would do nothing.
    func asksFor(site pattern: String, _ id: String) -> Bool {
        guard let candidate = try? WKWebExtension.MatchPattern(string: pattern) else { return false }
        return parsed[id]?.allRequestedMatchPatterns.contains { $0.matches(candidate) } == true
    }

    func allow(site pattern: String, _ id: String, until: Date = .distantFuture, privately: Bool = false) {
        if privately {
            privateSites[id, default: [:]][pattern] = until
            if let context = contexts[id], let match = try? WKWebExtension.MatchPattern(string: pattern) {
                context.setPermissionStatus(.grantedExplicitly, for: match, expirationDate: until)
            }
            return
        }
        changeSites(id) { $0[pattern] = until }
    }

    func disallow(site: String, _ id: String) {
        privateSites[id] = privateSites[id]?.filter { SitePattern.site(of: $0.key) != site }
        changeSites(id) { sites in sites = sites.filter { SitePattern.site(of: $0.key) != site } }
    }

    private func changeSites(_ id: String, _ change: (inout [String: Date]) -> Void) {
        update(id) { change(&$0.grants.sites) }
        guard let context = contexts[id], let record = record(id) else { return }
        context.grantedPermissionMatchPatterns = patterns(record.grants.sites.merging(privateSites[id] ?? [:]) { a, _ in a })
    }

    /// Whether the extension would like to run on this page and has not been
    /// allowed to: its button shows a dot, and a click asks.
    func wantsAccess(_ context: WKWebExtensionContext, to tab: Tab?) -> Bool {
        guard let tab, let url = tab.url, SiteKey.isWeb(url) else { return false }
        let status = context.permissionStatus(for: url, in: events.tab(for: tab))
        return status == .requestedImplicitly || status == .requestedExplicitly
    }

    // MARK: - Grants in and out of WebKit

    private func restore(_ grants: ExtensionGrants, into context: WKWebExtensionContext, id: String) {
        context.grantedPermissions = permissions(grants.permissions)
        context.deniedPermissions = permissions(grants.deniedPermissions)
        context.grantedPermissionMatchPatterns = patterns(grants.sites.merging(privateSites[id] ?? [:]) { a, _ in a })
        context.deniedPermissionMatchPatterns = patterns(grants.deniedSites)
    }

    private func permissions(_ grants: [String: Date]) -> [WKWebExtension.Permission: Date] {
        Dictionary(grants.map { (WKWebExtension.Permission(rawValue: $0.key), $0.value) }) { a, _ in a }
    }

    private func patterns(_ grants: [String: Date]) -> [WKWebExtension.MatchPattern: Date] {
        Dictionary(grants.compactMap { key, date in (try? WKWebExtension.MatchPattern(string: key)).map { ($0, date) } }) {
            a, _ in a
        }
    }

    /// An extension's grants changed inside WebKit — it asked and was
    /// answered, or gave something up. Copy them back to be saved.
    private func capture(_ context: WKWebExtensionContext) {
        guard let id = contexts.first(where: { $0.value === context })?.key else { return }
        let manifest = Set(context.webExtension.requestedPermissions.map(\.rawValue))
        var sites = Dictionary(context.grantedPermissionMatchPatterns.map { ($0.key.string, $0.value) }) { a, _ in a }
        if answeringPrivately {
            let saved = record(id)?.grants.sites ?? [:]
            for (pattern, date) in sites where saved[pattern] == nil { privateSites[id, default: [:]][pattern] = date }
        }
        sites = sites.filter { privateSites[id]?[$0.key] == nil }
        update(id) { record in
            record.grants = ExtensionGrants(
                permissions: Dictionary(
                    context.grantedPermissions.map { ($0.key.rawValue, $0.value) }.filter { !manifest.contains($0.0) }
                ) { a, _ in a },
                sites: sites,
                deniedPermissions: Dictionary(context.deniedPermissions.map { ($0.key.rawValue, $0.value) }) { a, _ in a },
                deniedSites: Dictionary(context.deniedPermissionMatchPatterns.map { ($0.key.string, $0.value) }) { a, _ in a })
        }
    }

    private func observeGrants() {
        let names: [Notification.Name] = [
            WKWebExtensionContext.permissionsWereGrantedNotification,
            WKWebExtensionContext.permissionsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionsWereRemovedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereGrantedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionMatchPatternsWereRemovedNotification,
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let context = note.object as? WKWebExtensionContext else { return }
                MainActor.assumeIsolated { self?.capture(context) }
            }
        }
    }

    // MARK: - Toolbar

    func actionDidChange() { actionRevision &+= 1 }

    /// The toolbar button was clicked: ask for the site first if it wants
    /// one, else do what the extension does — usually open its popup.
    func click(_ id: String, in browser: Browser) {
        guard let context = contexts[id] else { return }
        let tab = browser.selectedTab
        if let tab, let url = tab.url, wantsAccess(context, to: tab),
            let pattern = SitePattern.forSite(url.absoluteString), !notNow.contains("\(id) \(pattern)")
        {
            let host = URLGuess.displayHost(url)
            prompts.append(
                ExtensionPrompt(extensionID: id, window: browser.id, asks: [.site(host)], isClick: true) {
                    [weak self] answer in
                    guard let self else { return }
                    if answer == .deny {
                        // Not asked again on this site until relaunch; the
                        // button's menu still offers to allow it.
                        self.notNow.insert("\(id) \(pattern)")
                    } else {
                        self.allow(
                            site: pattern, id, until: answer == .oneDay ? .now.addingTimeInterval(86_400) : .distantFuture,
                            privately: browser.isPrivate)
                        // Content scripts arrive with a document; this one is
                        // already loaded.
                        if context.hasInjectedContent(for: url) { tab.reload() }
                    }
                    context.performAction(for: self.events.tab(for: tab))
                })
            return
        }
        context.performAction(for: tab.map(events.tab(for:)))
    }

    /// WebKit has the popup loaded: show it from the extension's button.
    func present(_ action: WKWebExtension.Action, of context: WKWebExtensionContext) -> Error? {
        guard let popover = action.popupPopover,
            let id = contexts.first(where: { $0.value === context })?.key,
            let browser = (action.associatedTab as? ExtensionTab)?.tab?.browser ?? Windows.shared.frontmost,
            let window = browser.window
        else { return LoadError.noWindow }
        action.hasUnreadBadgeText = false
        actionDidChange()
        // A folded toolbar has no buttons to point from; unfold it first and
        // show the popup once the buttons are laid out.
        let folded = browser.selectedTab?.chromeCollapsed == true
        browser.selectedTab?.chromeCollapsed = false
        Task {
            if folded { try? await Task.sleep(for: .milliseconds(250)) }
            if let anchor = anchors.view(for: id, in: browser.id) ?? anchors.view(for: ExtensionAnchors.overflow, in: browser.id) {
                popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
            } else if let content = window.contentView {
                let corner = NSRect(x: content.bounds.maxX - 60, y: content.bounds.maxY - 50, width: 1, height: 1)
                popover.show(relativeTo: corner, of: content, preferredEdge: .minY)
            }
        }
        return nil
    }

    func openOptions(_ id: String) {
        if let context = contexts[id] { openOptions(of: context) }
    }

    /// The extension's options page, in a new tab of the frontmost ordinary
    /// window — never a private one, whose tabs the extension may not see.
    func openOptions(of context: WKWebExtensionContext) {
        guard let url = context.optionsPageURL else { return }
        let front = Windows.shared.frontmost.flatMap { $0.isPrivate ? nil : $0 }
        guard let browser = front ?? Windows.shared.open.first(where: { !$0.isPrivate }) else {
            _ = Windows.shared.openWindow(showing: [url], private: false)
            return
        }
        browser.openTab(url, after: browser.selectedTab)
        browser.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: - Questions from extensions

    /// Ask about something an extension requested at run time. `respond`
    /// gets nil for "Don't Allow", else when the answer expires.
    func ask(
        _ asks: [ExtensionPrompt.Ask], from context: WKWebExtensionContext, in tab: (any WKWebExtensionTab)?,
        respond: @escaping (_ allowedUntil: Date?) -> Void
    ) {
        guard let id = contexts.first(where: { $0.value === context })?.key,
            let browser = (tab as? ExtensionTab)?.tab?.browser ?? Windows.shared.frontmost
        else { return respond(nil) }
        browser.selectedTab?.chromeCollapsed = false
        prompts.append(
            ExtensionPrompt(extensionID: id, window: browser.id, asks: asks, isClick: false) { [weak self] answer in
                guard let self else { return }
                switch answer {
                case .deny: respond(nil)
                case .oneDay, .always:
                    self.answeringPrivately = browser.isPrivate
                    respond(answer == .oneDay ? .now.addingTimeInterval(86_400) : .distantFuture)
                    self.answeringPrivately = false
                }
            })
    }

    func answer(_ prompt: ExtensionPrompt, _ answer: ExtensionPrompt.Answer) {
        guard prompts.contains(where: { $0.id == prompt.id }) else { return }
        prompts.removeAll { $0.id == prompt.id }
        prompt.respond(answer)
    }

    /// The question was closed without an answer. One prompted by a click
    /// just goes away; an extension's own request is declined.
    func dismiss(_ prompt: ExtensionPrompt) {
        guard prompts.contains(where: { $0.id == prompt.id }) else { return }
        prompts.removeAll { $0.id == prompt.id }
        if !prompt.isClick { prompt.respond(.deny) }
    }

    // MARK: - Keyboard shortcuts

    /// Watch keystrokes only while some running extension has a shortcut.
    private func updateShortcuts() {
        let wanted = contexts.values.contains { $0.commands.contains { $0.activationKey != nil } }
        if wanted, shortcutMonitor == nil {
            shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Local monitors are called on the main thread, with an event
                // that never leaves it.
                nonisolated(unsafe) let event = event
                let handled = MainActor.assumeIsolated { Extensions.shared.performShortcut(event) }
                return handled ? nil : event
            }
        } else if !wanted, let monitor = shortcutMonitor {
            NSEvent.removeMonitor(monitor)
            shortcutMonitor = nil
        }
    }

    /// An extension's shortcut, in a browser window — unless one of Zentic's
    /// own menu items uses the same keys. Zentic's ⇧⌘T must stay Reopen
    /// Closed Tab whatever an extension asks for.
    private func performShortcut(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            let browser = Windows.shared.open.first(where: { $0.window === event.window })
        else { return false }
        for item in toolbarItems(privateWindow: browser.isPrivate) {
            guard let command = item.context.command(for: event), let chord = command.chord,
                !ExtensionShortcuts.menu(NSApp.mainMenu, uses: chord)
            else { continue }
            item.context.performCommand(command)
            return true
        }
        return false
    }

    // MARK: - Saving

    private func update(_ id: String, _ change: (inout ExtensionRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
    }

    private func scheduleSave() {
        // Not before the file was read: an empty list would overwrite it.
        guard loadedRecords else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            let (records, file) = (self.records, self.file)
            self.io.async { file.save(records) }
        }
    }
}

/// A question for the user from an extension, shown from its toolbar button.
struct ExtensionPrompt: Identifiable {
    enum Ask: Hashable {
        case site(String)
        case permission(WKWebExtension.Permission)
    }

    enum Answer { case deny, oneDay, always }

    let id = UUID()
    let extensionID: String
    /// The browser window it concerns.
    let window: UUID
    let asks: [Ask]
    /// Asked because the user clicked the button: declining still opens the
    /// extension, so the button reads "Not Now" rather than "Don't Allow".
    let isClick: Bool
    let respond: (Answer) -> Void
}

/// Weak references to the views extension buttons are drawn in, so a popup
/// WebKit asks to show can point at the button it belongs to.
@MainActor
final class ExtensionAnchors {
    /// The overflow menu's button, for extensions that did not fit.
    static let overflow = "overflow"

    private final class Weak {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    private var views: [String: Weak] = [:]

    func set(_ view: NSView, for item: String, in browser: UUID) {
        views = views.filter { $0.value.view != nil }
        views["\(browser)/\(item)"] = Weak(view)
    }

    /// Only one on screen: a button scrolled away under a folded toolbar
    /// would put the popup in the wrong place.
    func view(for item: String, in browser: UUID) -> NSView? {
        guard let view = views["\(browser)/\(item)"]?.view, view.window != nil, !view.isHiddenOrHasHiddenAncestor
        else { return nil }
        return view
    }
}
