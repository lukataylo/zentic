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
        // Without these the window paints its own opaque background *behind* the
        // vibrancy view, so behind-window blending has nothing to blend with and
        // the chrome renders as flat colour. This is the difference between a
        // tinted panel and actual glass.
        window.isOpaque = false
        window.backgroundColor = .clear
        // Deliberately off. With `fullSizeContentView` the toolbar sits inside the
        // band AppKit still treats as titlebar, and background-dragging claims the
        // mouse-down there — so the mode toggle and the rewrite button were dead on
        // arrival, intermittently logging "Window move completed without beginning".
        // The sidebar drags the window explicitly instead; see `SidebarView`.
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 720, height: 480)
        window.contentViewController = browser
        window.setFrameAutosaveName("ZenticMainWindow")
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
