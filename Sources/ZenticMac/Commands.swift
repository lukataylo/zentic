import SwiftUI
import ZenticKit

/// The menu bar. Every action in the app is reachable from here, with the key
/// equivalents Safari users already have in their hands. Each acts on the
/// focused window.
struct BrowserCommands: Commands {
    @FocusedValue(Browser.self) private var browser
    @FocusedValue(\.historySearch) private var historySearch
    @Environment(\.openWindow) private var openWindow

    private var tab: Tab? { browser?.selectedTab }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { Windows.shared.newWindow(private: false) }
                .keyboardShortcut("n")
            Button("New Private Window") { Windows.shared.newWindow(private: true) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Tab") { showCommandBar(newTab: true) }
                .keyboardShortcut("t")
            Button("Open Location…") { showCommandBar(newTab: false) }
                .keyboardShortcut("l")
                .disabled(browser == nil)
            Button("Reopen Closed Tab") { browser?.reopenClosed() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(browser?.canReopen != true)
            Button("Reopen Closed Window") { Windows.shared.reopenClosedWindow() }
                .disabled(!Windows.shared.canReopenWindow)
        }

        CommandGroup(replacing: .saveItem) {
            Button(tab?.isPinned == true ? "Close Pinned Tab" : "Close Tab") {
                // Nothing to close in an empty window, or with Settings in
                // front: ⌘W closes the window instead, as everywhere on the Mac.
                if let tab { browser?.close(tab) } else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") { tab?.printPage() }
                .keyboardShortcut("p")
                .disabled(tab?.isRealized != true)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Link") { if let url = tab?.url { copy(url) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(tab?.url == nil)
        }

        CommandGroup(replacing: .textEditing) {
            Button("Find…") {
                if let historySearch { return historySearch.focus() }
                browser?.findBar.isPresented = true
                browser?.findBar.notFound = false
            }
            .keyboardShortcut("f")
            .disabled(tab == nil && historySearch == nil)
            Button("Find Next") { find(backwards: false) }
                .keyboardShortcut("g")
                .disabled(browser?.findBar.text.isEmpty != false)
            Button("Find Previous") { find(backwards: true) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(browser?.findBar.text.isEmpty != false)
        }

        CommandGroup(replacing: .sidebar) {
            Button(browser?.sidebarVisible == false ? "Show Sidebar" : "Hide Sidebar") {
                withAnimation(.smooth(duration: 0.32)) { browser?.sidebarVisible.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(browser == nil)
            Button("Show Downloads") { showDownloads() }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Divider()
            Button("Reload Page") { tab?.reload() }
                .keyboardShortcut("r")
                .disabled(tab == nil)
            Button("Stop") { tab?.stop() }
                .keyboardShortcut(".")
                .disabled(tab?.isLoading != true)
            Divider()
            Button("Actual Size") { tab?.zoom = 1 }
                .keyboardShortcut("0")
                .disabled(tab == nil)
            Button("Zoom In") { zoom(by: 1) }
                .keyboardShortcut("=")
                .disabled(tab == nil)
            Button("Zoom Out") { zoom(by: -1) }
                .keyboardShortcut("-")
                .disabled(tab == nil)
            Divider()
        }

        CommandMenu("Page") {
            ForEach(Array(SiteMode.allCases.enumerated()), id: \.element) { index, mode in
                Toggle(
                    mode.title,
                    isOn: Binding(get: { tab?.mode == mode }, set: { _ in browser?.choose(mode) }))
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                .disabled(!SiteKey.isWeb(tab?.url))
            }
            Divider()
            // Not ⌘E: that is "Use Selection for Find" everywhere on the Mac.
            Button("Design Your Version…") { tab?.design.present() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!SiteKey.isWeb(tab?.url))
            Button("Remove Custom Version") {
                if let key = tab?.siteKey { browser?.removeCustom(forKey: key) }
            }
            .disabled(browser?.custom(for: tab?.url) == nil)
            Button("Show Certificate…") {
                if let tab, let trust = tab.serverTrust {
                    CertificateTrust.show(trust, for: tab.displayHost, in: browser?.window)
                }
            }
            .disabled(tab?.canShowCertificate != true)
            Button("Repair Custom Version…") {
                if let tab, let drift = Rechecks.shared.drift(for: tab) { tab.design.repair(on: tab, drift: drift) }
            }
            .keyboardShortcut("e", modifiers: [.command, .option, .shift])
            .disabled(Rechecks.shared.drift(for: tab) == nil)
            Divider()
            Button("Page Settings…") {
                // A transient popover opened while the menu is still tracking is
                // dismissed by the menu closing. Present on the next turn.
                let browser = browser
                Task {
                    try? await Task.sleep(for: .milliseconds(60))
                    browser?.selectedTab?.chromeCollapsed = false
                    browser?.modePickerPresented = true
                }
            }
                // Not ⌥⌘D, which shows and hides the Dock system-wide.
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(!SiteKey.isWeb(tab?.url))
            Button("Site Permissions…") {
                DataDirectory.defaults.set(true, forKey: "pagePermissionsExpanded")
                let browser = browser
                Task {
                    try? await Task.sleep(for: .milliseconds(60))
                    browser?.selectedTab?.chromeCollapsed = false
                    browser?.modePickerPresented = true
                }
            }
            .disabled(!SiteKey.isWeb(tab?.url))
            if let permissions = tab?.permissions, permissions.isCapturing {
                Button("Stop Using \(permissions.inUseTitle)") { permissions.stopCapture() }
            }
        }

        CommandMenu("History") {
            Button("Back") { tab?.goBack() }
                .keyboardShortcut("[")
                .disabled(tab?.canGoBack != true)
            Button("Forward") { tab?.goForward() }
                .keyboardShortcut("]")
                .disabled(tab?.canGoForward != true)
            OtherDevicesMenu(browser: browser)
            Divider()
            Button("Show All History") { openWindow(id: HistoryWindow.id) }
                .keyboardShortcut("y")
            RecentlyClosedMenu(browser: browser ?? Windows.shared.frontmost)
            Divider()
            Button("Clear History…") { ClearHistoryAlert.run() }
                .disabled(!AppModel.shared.historyLoaded)
        }

        CommandMenu("Tabs") {
            Button("Show Next Tab") { browser?.selectNeighbour(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(tab == nil)
            Button("Show Previous Tab") { browser?.selectNeighbour(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(tab == nil)
            Divider()
            Button("Duplicate Tab") { if let tab { browser?.duplicate(tab) } }
                .disabled(tab == nil)
            Button(tab?.isPinned == true ? "Unpin Tab" : "Pin Tab") {
                guard let tab else { return }
                tab.isPinned ? browser?.unpin(tab) : browser?.pin(tab)
            }
            .disabled(tab == nil || browser?.isPrivate == true)
            Button(AppModel.shared.isFavorite(tab?.url) ? "Remove from Favorites" : "Add to Favorites") {
                toggleFavorite()
            }
            .keyboardShortcut("d")
            .disabled(!SiteKey.isWeb(tab?.url))
            Divider()
            Button("Move Tab to New Window") { if let tab { browser?.moveToNewWindow(tab) } }
                .disabled(tab == nil || browser?.allTabs.count == 1)
            if let browser, browser.spaces.count > 1, let tab {
                Menu("Move Tab to Space") {
                    ForEach(browser.spaces.filter { $0 !== browser.space }) { space in
                        Button(space.name) { browser.move(tab, to: space) }
                    }
                }
            }
            Divider()
            ForEach(0..<9) { index in
                Button(index == 8 ? "Last Tab" : "Tab \(index + 1)") { browser?.selectTab(at: index) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    .disabled(tab == nil && browser?.space.allTabs.isEmpty != false)
            }
        }

        // In place of "Zentic Help", which had no help book behind it.
        CommandGroup(replacing: .help) {
            Button("Welcome to Zentic") { Onboarding.shared.show(over: browser) }
        }

        CommandMenu("Spaces") {
            Button("New Space…") { if let browser { browser.spaceDraft = SpaceDraft(newIn: browser) } }
                .disabled(browser == nil || browser?.isPrivate == true)
            Button("Edit Space…") { if let browser { browser.spaceDraft = SpaceDraft(editing: browser.space) } }
                .disabled(browser == nil || browser?.isPrivate == true)
            Divider()
            if let browser {
                // ⌃1…⌃9, as Arc. Off by default in macOS, where they would
                // otherwise switch desktops.
                ForEach(Array(browser.spaces.prefix(9).enumerated()), id: \.element.id) { index, space in
                    Toggle(space.name, isOn: Binding(get: { browser.space === space }, set: { _ in browser.switchTo(space) }))
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
                }
            }
        }
    }

    private func showCommandBar(newTab: Bool) {
        // Settings in front: the browser window behind it.
        guard let browser = browser ?? Windows.shared.frontmost else {
            // No window open: ⌘T opens one, as in Safari.
            return Windows.shared.newWindow(private: false)
        }
        browser.window?.makeKeyAndOrderFront(nil)
        if newTab { browser.showCommandBar(newTab: true) } else { browser.editAddress() }
    }

    /// ⌥⌘L, as in Safari: the downloads list, from the toolbar of the
    /// window in front — even before anything has been downloaded.
    private func showDownloads() {
        guard let target = browser ?? Windows.shared.frontmost else { return }
        let downloads = Downloads.shared
        if downloads.presentedIn == target.id { return downloads.presentedIn = nil }
        target.window?.makeKeyAndOrderFront(nil)
        // A popover opened while the menu is still tracking is dismissed by
        // the menu closing. Present on the next turn.
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            target.selectedTab?.chromeCollapsed = false
            downloads.presentedIn = target.id
        }
    }

    private func find(backwards: Bool) {
        guard let browser, let tab else { return }
        let text = browser.findBar.text
        Task { browser.findBar.notFound = !(await tab.find(text, backwards: backwards)) }
    }

    private static let zoomSteps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    private func zoom(by step: Int) {
        guard let tab else { return }
        let steps = Self.zoomSteps
        let index = steps.firstIndex { $0 >= tab.zoom - 0.001 } ?? 5
        tab.zoom = steps[min(max(index + step, 0), steps.count - 1)]
    }

    private func toggleFavorite() {
        guard let tab, let url = tab.url else { return }
        let app = AppModel.shared
        if let existing = app.favorites.first(where: { SiteKey.for($0.url) == tab.siteKey }) {
            app.removeFavorite(existing.id)
        } else {
            app.addFavorite(url: url, title: tab.title)
        }
    }
}
