import AppKit
import SwiftUI
import ZenticKit

@main
struct ZenticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // One scene, many windows: each is opened with its browser's id.
        WindowGroup("Zentic", id: "browser", for: UUID.self) { $windowID in
            BrowserWindow(windowID: $windowID)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 880)
        // Zentic restores its own windows from the session, spaces and all;
        // SwiftUI restoring them as well would open each one twice.
        .restorationBehavior(.disabled)
        .commands {
            BrowserCommands()
            PasswordCommands()
            BookmarkCommands()
        }

        // Each is reached from its own menu item; `commandsRemoved` keeps
        // SwiftUI from also listing them in the Window menu — which would
        // show Bookmarks even while bookmarks are turned off.
        Window("History", id: HistoryWindow.id) {
            HistoryWindow().environment(AppModel.shared)
        }
        .defaultSize(width: 760, height: 600)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Window("Bookmarks", id: BookmarksWindow.id) {
            BookmarksWindow().environment(AppModel.shared)
        }
        .defaultSize(width: 560, height: 560)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(AppModel.shared)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // `swift run` launches a bare executable with no bundle; make it a
        // proper foreground app with a Dock icon and menu bar.
        NSApp.setActivationPolicy(.regular)
        AppModel.shared.appearance.apply()
        // Before anything else can crash: notes the launch, reads the session.
        _ = Windows.shared
        // Now, so a link that launched Zentic is caught too.
        OpenFromElsewhere.install()
        Blocking.warm()
        SafeBrowsing.shared.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        OpenFromElsewhere.didFinishLaunching(notification)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Windows.shared.saveForTermination()
        AppModel.shared.saveHistoryNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
