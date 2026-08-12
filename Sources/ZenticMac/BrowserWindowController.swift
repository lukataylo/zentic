import AppKit
import ZenticKit

/// The one window.
///
/// No title bar, full-size content, so the traffic lights land at the top-left of
/// the sidebar and the space tint runs to every edge. `titleVisibility` alone is not
/// enough — without `fullSizeContentView` the content still starts below an
/// invisible 28pt strip, and the sidebar would begin too low.
@MainActor
final class BrowserWindowController: NSWindowController {
    let browser: BrowserViewController

    init(store: BrowsingStore) {
        browser = BrowserViewController(store: store)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Zentic"
        // Lets the sidebar's empty areas drag the window, since there is no title
        // bar left to grab.
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 720, height: 480)
        window.contentViewController = browser
        window.setFrameAutosaveName("ZenticMainWindow")
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
