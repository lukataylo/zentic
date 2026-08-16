import AppKit
import ZenticKit

/// The five-stop rail: how much Zentic is changing this site, and one click to
/// change it.
///
/// Drawn rather than assembled from an `NSSegmentedControl`, because three of the
/// things that make it readable are not segment behaviour: the gap before the last
/// stop that shows the AI threshold *before* you cross it, the hollow marker
/// showing where the automatic answer sits when you have overridden it, and struck
/// stops for levels this page cannot reach. Accessibility is therefore wired by
/// hand — see `accessibilityChildren`.
final class LevelRailView: ChromeView {

    /// A stop was clicked.
    var onSelect: ((PageLevel) -> Void)?
    /// A stop the page cannot reach was clicked.
    ///
    /// Reported rather than swallowed. A struck stop that simply ignores a click
    /// teaches the user the control is broken; the click is the moment they have
    /// asked the question, and so the moment to answer it.
    var onBlocked: ((PageLevel) -> Void)?
    /// The label or a modifier-click asked for the detail popover.
    var onOpenDetail: (() -> Void)?

    private(set) var level: PageLevel = .reader
    /// Where `auto` would land. Drawn hollow when it differs from ``level``.
    private var automatic: PageLevel = .reader
    /// Stops at or below this are selectable; above it they are struck through.
    private var ceiling: PageLevel = .rewritten
    /// Why the stops above the ceiling are unavailable, for the tooltip.
    private var ceilingReason: String?

    private var hovered: PageLevel?

    private let label = NSTextField(labelWithString: "")

    // Geometry. The rail has to earn its ~110pt against the breadcrumb, which is
    // the toolbar's most valuable tenant, so the dots are tight and the label
    // carries the meaning.
    private let dotSize: CGFloat = 8
    /// Size of the current stop, which is drawn larger so the eye lands on it first.
    private let activeDotSize: CGFloat = 12
    private let dotSpacing: CGFloat = 22
    /// Extra gap before the last stop. This is the consent boundary made visible.
    private let thresholdGap: CGFloat = 12
    private let labelWidth: CGFloat = 64
    private let railInset: CGFloat = 7

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: labelWidth),
            widthAnchor.constraint(equalToConstant: railWidth + 4 + labelWidth),
            heightAnchor.constraint(equalToConstant: 24),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
        addGestureRecognizer(click)

        applyLayerColors()
        apply()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var railWidth: CGFloat {
        CGFloat(PageLevel.allCases.count - 1) * dotSpacing + activeDotSize + thresholdGap
            + railInset * 2
    }

    // MARK: - State

    func apply(
        level: PageLevel,
        automatic: PageLevel,
        ceiling: PageLevel,
        ceilingReason: String?
    ) {
        self.level = level
        self.automatic = automatic
        self.ceiling = ceiling
        self.ceilingReason = ceilingReason
        apply()
    }

    private func apply() {
        // The label previews whatever the pointer is over, so a stop can be read
        // before it is chosen — five dots cannot say "Calm" on their own, and a
        // control whose options are only legible after you pick one is a guess.
        let shown = hovered ?? level
        label.stringValue = shown.title
        label.textColor = hovered == nil ? .secondaryLabelColor : .labelColor

        let describing = shown
        toolTip =
            describing > ceiling
            ? ceilingReason
            : "\(describing.title) — \(describing.summary)\n\nLess ⌥⌘[  ·  More ⌥⌘]"
        needsDisplay = true
    }

    // MARK: - Layout

    /// Centre of the dot for a stop. The last one sits past the threshold gap.
    private func centre(of level: PageLevel) -> CGPoint {
        let index = CGFloat(level.ordinal)
        let gap = level == .rewritten ? thresholdGap : 0
        return CGPoint(x: railInset + activeDotSize / 2 + index * dotSpacing + gap, y: bounds.midY)
    }

    private func stop(at point: NSPoint) -> PageLevel? {
        // Generous targets: five 7pt dots in a 38pt toolbar are not clickable at
        // their drawn size, so each owns the space around it.
        PageLevel.allCases.first { level in
            abs(centre(of: level).x - point.x) <= dotSpacing / 2 + 1
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let dark = isDarkAppearance

        // A capsule behind the dots, so the whole thing reads as one control rather
        // than as decoration that happens to sit in the toolbar. Without it the dots
        // look like a progress indicator — something that reports, not something you
        // press.
        let capsule = NSRect(x: 0, y: 1, width: railWidth, height: bounds.height - 2)
        (dark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.045))
            .setFill()
        NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2)
            .fill()

        // The connecting track, broken at the threshold so the gap reads as a
        // boundary rather than as uneven spacing.
        NSColor.tertiaryLabelColor.withAlphaComponent(dark ? 0.5 : 0.4).setStroke()
        let track = NSBezierPath()
        track.lineWidth = 1.5
        track.move(to: CGPoint(x: centre(of: .original).x, y: bounds.midY))
        track.line(to: CGPoint(x: centre(of: .reader).x, y: bounds.midY))
        track.stroke()

        let threshold = NSBezierPath()
        threshold.lineWidth = 1.5
        threshold.setLineDash([1.5, 2.5], count: 2, phase: 0)
        threshold.move(to: CGPoint(x: centre(of: .reader).x, y: bounds.midY))
        threshold.line(to: CGPoint(x: centre(of: .rewritten).x, y: bounds.midY))
        threshold.stroke()

        for stop in PageLevel.allCases {
            let point = centre(of: stop)
            let isReachable = stop <= ceiling
            let size = stop == level ? activeDotSize : dotSize
            let rect = NSRect(
                x: point.x - size / 2,
                y: point.y - size / 2,
                width: size,
                height: size
            )

            if stop == level {
                // Punched out of the track first, so the line does not show through
                // a translucent accent colour.
                (dark ? NSColor.black : NSColor.white).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: -1.5, dy: -1.5)).fill()
                (isReachable ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).setFill()
                NSBezierPath(ovalIn: rect).fill()
            } else if !isReachable {
                // Struck rather than merely dim, and a click on it is answered
                // rather than swallowed — see `onBlocked`.
                NSColor.quaternaryLabelColor.setStroke()
                let cross = NSBezierPath()
                cross.lineWidth = 1.5
                let inset = rect.insetBy(dx: 0.5, dy: 0.5)
                cross.move(to: CGPoint(x: inset.minX, y: inset.minY))
                cross.line(to: CGPoint(x: inset.maxX, y: inset.maxY))
                cross.move(to: CGPoint(x: inset.minX, y: inset.maxY))
                cross.line(to: CGPoint(x: inset.maxX, y: inset.minY))
                cross.stroke()
            } else if stop == automatic && automatic != level {
                // Where the page would have landed on its own. Hollow, so an
                // override always has something to be measured against.
                NSColor.secondaryLabelColor.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            } else {
                let hot = stop == hovered
                (hot ? NSColor.labelColor : NSColor.tertiaryLabelColor).setFill()
                NSBezierPath(ovalIn: hot ? rect : rect.insetBy(dx: 1, dy: 1)).fill()
            }
        }
    }

    // MARK: - Input

    @objc private func clicked(_ gesture: NSClickGestureRecognizer) {
        let point = gesture.location(in: self)
        // The label opens the detail; the dots set the level directly.
        guard point.x < railWidth + 2 else {
            onOpenDetail?()
            return
        }
        guard let stop = stop(at: point) else { return }
        if stop <= ceiling {
            onSelect?(stop)
        } else {
            onBlocked?(stop)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                owner: self
            )
        )
    }

    override func mouseMoved(with event: NSEvent) {
        // Blocked stops are hovered too: the label and tooltip are how the user
        // finds out *why* they cannot have one.
        let next = stop(at: convert(event.locationInWindow, from: nil))
        guard next != hovered else { return }
        hovered = next
        apply()
    }

    override func mouseExited(with event: NSEvent) {
        guard hovered != nil else { return }
        hovered = nil
        apply()
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { "Page level" }
    override func accessibilityValue() -> Any? { level.title }
}
