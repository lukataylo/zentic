import SwiftUI
import ZenticKit

/// The menu bar. Every action in the app is reachable from here, with the key
/// equivalents Safari users already have in their hands.
struct BrowserCommands: Commands {
    let browser: Browser
    @Environment(\.openSettings) private var openSettings

    private var tab: Tab? { browser.selectedTab }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { showCommandBar(newTab: true) }
                .keyboardShortcut("t")
            Button("Open Location…") { showCommandBar(newTab: false) }
                .keyboardShortcut("l")
            Button("Reopen Closed Tab") { browser.reopenClosed() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!browser.canReopen)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { browser.closeSelected() }
                .keyboardShortcut("w")
                .disabled(tab == nil)
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
            Button("Copy Link") { copyLink() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(tab?.url == nil)
        }

        CommandGroup(replacing: .textEditing) {
            Button("Find…") {
                browser.findBar.isPresented = true
                browser.findBar.notFound = false
            }
            .keyboardShortcut("f")
            Button("Find Next") { find(backwards: false) }
                .keyboardShortcut("g")
                .disabled(browser.findBar.text.isEmpty)
            Button("Find Previous") { find(backwards: true) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(browser.findBar.text.isEmpty)
        }

        CommandGroup(replacing: .sidebar) {
            Button(browser.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                withAnimation(.smooth(duration: 0.32)) { browser.sidebarVisible.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            Divider()
            Button("Reload Page") { tab?.reload() }
                .keyboardShortcut("r")
            Button("Stop") { tab?.stop() }
                .keyboardShortcut(".")
                .disabled(tab?.isLoading != true)
            Divider()
            Button("Actual Size") { tab?.zoom = 1 }
                .keyboardShortcut("0")
            Button("Zoom In") { zoom(by: 1) }
                .keyboardShortcut("=")
            Button("Zoom Out") { zoom(by: -1) }
                .keyboardShortcut("-")
            Divider()
        }

        CommandMenu("Page") {
            ForEach(Array(SiteMode.allCases.enumerated()), id: \.element) { index, mode in
                Toggle(
                    mode.title,
                    isOn: Binding(get: { tab?.mode == mode }, set: { _ in browser.choose(mode) }))
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                .disabled(!SiteKey.isWeb(tab?.url))
            }
            Divider()
            // Not ⌘E: that is "Use Selection for Find" everywhere on the Mac.
            Button("Design Your Version…") { tab?.design.present() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!SiteKey.isWeb(tab?.url))
            Button("Remove Custom Version") {
                if let key = tab?.siteKey { AppModel.shared.removeCustom(forKey: key) }
            }
            .disabled(AppModel.shared.custom(for: tab?.url) == nil)
            Divider()
            Button("Page Settings…") {
                // A transient popover opened while the menu is still tracking is
                // dismissed by the menu closing. Present on the next turn.
                Task {
                    try? await Task.sleep(for: .milliseconds(60))
                    browser.selectedTab?.chromeCollapsed = false
                    browser.modePickerPresented = true
                }
            }
                // Not ⌥⌘D, which shows and hides the Dock system-wide.
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(!SiteKey.isWeb(tab?.url))
        }

        CommandMenu("History") {
            Button("Back") { tab?.goBack() }
                .keyboardShortcut("[")
                .disabled(tab?.canGoBack != true)
            Button("Forward") { tab?.goForward() }
                .keyboardShortcut("]")
                .disabled(tab?.canGoForward != true)
            Divider()
            Button("Clear History…") { AppModel.shared.clearHistory() }
        }

        CommandMenu("Tabs") {
            Button("Show Next Tab") { browser.selectNeighbour(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Show Previous Tab") { browser.selectNeighbour(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            Button("Duplicate Tab") { if let tab { browser.duplicate(tab) } }
                .disabled(tab == nil)
            Button(AppModel.shared.isFavorite(tab?.url) ? "Remove from Favorites" : "Add to Favorites") {
                toggleFavorite()
            }
            .keyboardShortcut("d")
            .disabled(!SiteKey.isWeb(tab?.url))
            Divider()
            ForEach(0..<9) { index in
                Button(index == 8 ? "Last Tab" : "Tab \(index + 1)") { browser.selectTab(at: index) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
    }

    private func showCommandBar(newTab: Bool) {
        browser.commandBar.opensNewTab = newTab
        browser.commandBar.text = newTab ? "" : (tab?.url?.absoluteString ?? "")
        browser.commandBar.isPresented = true
    }

    private func copyLink() {
        guard let url = tab?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func find(backwards: Bool) {
        let text = browser.findBar.text
        Task { browser.findBar.notFound = !(await tab?.find(text, backwards: backwards) ?? false) }
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
