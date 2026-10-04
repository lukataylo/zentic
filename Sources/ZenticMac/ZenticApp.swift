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
        .commands { BrowserCommands() }

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
        Blocking.warm()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        TabSync.shared.start()
    }

    /// The other Macs should see the tabs this one quit with. Held up for a
    /// moment at most; offline, they go on the next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard TabSync.shared.hasUnsentChanges else { return .terminateNow }
        Task {
            await TabSync.shared.sendBeforeQuit(within: .seconds(3))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Windows.shared.saveForTermination()
        AppModel.shared.saveHistoryNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
