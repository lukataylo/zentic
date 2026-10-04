import AppKit
import SwiftUI
import ZenticKit

@main
struct ZenticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var browser = AppDelegate.browser

    var body: some Scene {
        Window("Zentic", id: "browser") {
            BrowserView()
                .environment(browser)
                .environment(AppModel.shared)
                .frame(minWidth: 720, minHeight: 480)
                .containerBackground(.clear, for: .window)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 880)
        .commands { BrowserCommands(browser: browser) }

        Settings {
            SettingsView()
                .environment(AppModel.shared)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One browser for the app's one window. It outlives the window, so closing
    /// the window and reopening it from the Dock brings the same tabs back.
    static let browser = Browser()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // `swift run` launches a bare executable with no bundle; make it a
        // proper foreground app with a Dock icon and menu bar.
        NSApp.setActivationPolicy(.regular)
        AppModel.shared.appearance.apply()
        Blocking.warm()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.browser.saveNow()
        AppModel.shared.saveHistoryNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
