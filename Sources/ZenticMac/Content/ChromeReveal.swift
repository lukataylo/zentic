import AppKit

/// An invisible strip along a window edge that reports the pointer entering and
/// leaving it.
///
/// `hitTest` returns nil so the strip never takes a click: it lies on top of the
/// page, and a browser where the leftmost few points of every link are dead would
/// be worse than having no reveal at all. Tracking areas are delivered from the
/// window's event routing rather than from hit testing, so the hover still lands.
final class HoverZone: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    /// Set while the zone is not in use, so a collapsed-then-pinned sidebar stops
    /// reacting to the pointer without having to be removed from the hierarchy.
    var isArmed = true {
        // AppKit has no "invalidate my tracking areas" flag, so the rebuild is
        // driven directly. `updateTrackingAreas` is idempotent.
        didSet { updateTrackingAreas() }
    }

    private var zone: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let zone { removeTrackingArea(zone) }
        guard isArmed else {
            zone = nil
            return
        }
        let area = NSTrackingArea(
            rect: bounds,
            // `.activeInActiveApp` rather than `.activeAlways`: chrome should not
            // slide open under a pointer that is only crossing the window on its way
            // somewhere else in a different app.
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        zone = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A view that reports the pointer entering and leaving its bounds.
///
/// The base class for the two pieces of chrome that can float: while revealed,
/// each keeps itself open by reporting that the pointer is still over it. Nested
/// tracking areas — a sidebar row inside the sidebar — do not interfere, because
/// entering a subview's area does not exit its ancestor's.
class PointerTrackingView: NSView {
    var onPointerEnter: (() -> Void)?
    var onPointerExit: (() -> Void)?

    private var pointerArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        pointerArea = area
    }

    override func mouseEntered(with event: NSEvent) { onPointerEnter?() }
    override func mouseExited(with event: NSEvent) { onPointerExit?() }
}

/// Tracks whether a piece of auto-hidden chrome should currently be on screen.
///
/// The delay on hide is the whole reason this is a type rather than two booleans:
/// the pointer leaves the panel constantly — crossing a gap between subviews,
/// clipping a corner on the way to the page — and hiding on the first exit makes
/// the panel flicker. A pending hide is cancelled if the pointer comes back.
@MainActor
final class RevealLatch {
    private(set) var isRevealed = false
    private var pendingHide: Task<Void, Never>?
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func show() {
        pendingHide?.cancel()
        pendingHide = nil
        guard !isRevealed else { return }
        isRevealed = true
        onChange(true)
    }

    /// Hide after ``Chrome/revealHideDelay``, unless ``show()`` intervenes.
    func hideSoon() {
        guard isRevealed else { return }
        pendingHide?.cancel()
        pendingHide = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Chrome.revealHideDelay))
            guard !Task.isCancelled, let self, isRevealed else { return }
            isRevealed = false
            onChange(false)
        }
    }

    /// Hide now — for a state change (pinning, a new tab) rather than a pointer move.
    func hideImmediately() {
        pendingHide?.cancel()
        pendingHide = nil
        guard isRevealed else { return }
        isRevealed = false
        onChange(false)
    }
}
