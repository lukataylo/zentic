import AppKit
import SwiftUI

/// The root of one browser window: finds its `Browser` and hands it down.
struct BrowserWindow: View {
    /// The value the window was opened with. Nil for the window SwiftUI opens
    /// by itself; set once claimed, so SwiftUI will bring this window forward
    /// rather than open a second one for the same browser.
    @Binding var windowID: UUID?
    @State private var claim = Claim()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let browser = claim.browser(for: windowID)
        BrowserView()
            .environment(browser)
            .environment(AppModel.shared)
            .focusedSceneValue(browser)
            .navigationTitle(browser.windowTitle)
            .frame(minWidth: 720, minHeight: 480)
            .containerBackground(.clear, for: .window)
            .onAppear {
                if windowID != browser.id { windowID = browser.id }
                Windows.shared.windowAppeared(openWindow)
            }
    }

    /// Claims a browser once per window. `body` runs many times; claiming on
    /// each run would hand this window a second browser.
    @MainActor
    final class Claim {
        private var browser: Browser?

        func browser(for id: UUID?) -> Browser {
            if let browser { return browser }
            let claimed = Windows.shared.claim(id)
            browser = claimed
            return claimed
        }
    }
}

extension Browser {
    /// Shown in the Window menu and Mission Control; the title bar itself is hidden.
    var windowTitle: String {
        let page = selectedTab.map { $0.title.isEmpty ? $0.displayHost : $0.title } ?? ""
        if isPrivate { return page.isEmpty ? "Private Window" : "Private — \(page)" }
        return page.isEmpty ? "Zentic" : page
    }

    /// The window this browser is shown in has been created. Put it where it
    /// was last time, and follow it from now on.
    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        if let frame, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            window.setFrame(frame, display: false)
        } else if adoptsLegacyFrame {
            // Where the single window of an earlier Zentic used to open.
            window.setFrameUsingName("ZenticBrowserWindow")
        }
        if isPrivate { window.appearance = NSAppearance(named: .darkAqua) }
        TrafficLights.setHidden(!sidebarVisible, in: window)

        let center = NotificationCenter.default
        let remember: @Sendable (Notification) -> Void = { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window, !window.styleMask.contains(.fullScreen) else { return }
                self.frame = window.frame
            }
        }
        windowObservers = [
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main, using: remember),
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main, using: remember),
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.windowObservers.forEach(NotificationCenter.default.removeObserver)
                    self.windowObservers = []
                    self.window = nil
                    Windows.shared.windowClosed(self)
                }
            },
        ]
    }
}
