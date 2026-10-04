import AppKit
import SwiftUI
import WebKit

/// Hosts the selected tab's web view, keeping the others' alive off-screen.
///
/// Also reports when the pointer is near the top edge: the collapsed toolbar
/// reveals itself on hover there, and a SwiftUI hover region over the page
/// would swallow the page's own clicks.
struct WebContainer: NSViewRepresentable {
    let tab: Tab?
    var onPointerNearTop: (Bool) -> Void

    func makeNSView(context: Context) -> ContainerView {
        let view = ContainerView()
        view.onPointerNearTop = onPointerNearTop
        return view
    }

    func updateNSView(_ view: ContainerView, context: Context) {
        view.onPointerNearTop = onPointerNearTop
        view.show(tab?.isRealized == true ? tab?.webView : nil)
    }

    final class ContainerView: NSView {
        var onPointerNearTop: ((Bool) -> Void)?
        private weak var current: WKWebView?
        private var nearTop = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            // SwiftUI's clip does not reach an AppKit subview; the card's
            // corners have to be cut here too.
            layer?.cornerRadius = Metrics.cardRadius
            layer?.cornerCurve = .continuous
        }

        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }

        func show(_ webView: WKWebView?) {
            guard current !== webView else { return }
            // Only if still ours: a tab moved to another window took its web
            // view along, and removing it here would blank that window.
            if current?.superview === self { current?.removeFromSuperview() }
            current = webView
            guard let webView else { return }
            webView.frame = bounds
            webView.autoresizingMask = [.width, .height]
            addSubview(webView)
            // Keep typing where it was: a newly shown page takes focus only if
            // nothing else in the window (the address bar, the composer) has it.
            if window?.firstResponder == nil || window?.firstResponder === window {
                window?.makeFirstResponder(webView)
            }
        }

        // Enter/exit on a strip along the top only — no mouse-moved events
        // for every pixel of travel across the page.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: NSRect(x: 0, y: 0, width: bounds.width, height: 64),
                    options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            update(true)
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            update(false)
        }

        private func update(_ near: Bool) {
            guard near != nearTop else { return }
            nearTop = near
            onPointerNearTop?(near)
        }
    }
}
