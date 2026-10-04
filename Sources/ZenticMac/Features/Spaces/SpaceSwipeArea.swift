import AppKit
import SwiftUI
import ZenticKit

/// Two-finger horizontal swipes over the sidebar switch spaces.
///
/// Placed behind the sidebar to learn its frame. It watches scroll events
/// rather than receiving them — the tab list above it must still scroll — and
/// only those in its own window, inside its own bounds.
struct SpaceSwipeArea: NSViewRepresentable {
    var onSwipe: (SpaceSwipe.Direction) -> Void

    func makeNSView(context: Context) -> SwipeView {
        let view = SwipeView()
        view.onSwipe = onSwipe
        return view
    }

    func updateNSView(_ view: SwipeView, context: Context) {
        view.onSwipe = onSwipe
    }

    final class SwipeView: NSView {
        var onSwipe: ((SpaceSwipe.Direction) -> Void)?
        private var monitor: Any?
        private var swipe = SpaceSwipe()
        private var tracking = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func handle(_ event: NSEvent) {
            // Trackpad gestures only: a mouse wheel has no phases, and a
            // momentum tail is the end of a gesture already handled.
            guard event.window === window, event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
            if event.phase == .began {
                tracking = bounds.contains(convert(event.locationInWindow, from: nil))
                swipe.begin()
            }
            guard tracking, event.phase == .changed else { return }
            // In physical terms, whatever the scrolling-direction setting.
            let sign: Double = event.isDirectionInvertedFromDevice ? 1 : -1
            if let direction = swipe.move(dx: sign * event.scrollingDeltaX, dy: sign * event.scrollingDeltaY) {
                onSwipe?(direction)
            }
        }

        isolated deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
