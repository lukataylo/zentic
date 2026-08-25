import AppKit
import ZenticKit

/// Everything the rail and its detail menu *say* about the level, the automatic
/// answer and the standing preference.
///
/// Pure, and lifted out of the view, for the reason the rail's own doc comment
/// gives about drawing: once a sentence has been rendered into a tooltip it is not
/// observable, and the defect this exists for is a control that knows the answer
/// and never states it. The rail had exactly one indication of the automatic level
/// — a hollow ring, drawn only when it differed from the current stop — and it
/// carried no name, no tooltip of its own and nothing in the accessibility value.
/// Under the default preference the two always agree, so the ring was suppressed
/// and the automatic answer appeared nowhere at all.
///
/// Every branch below names the automatic level. That is the fix: it is stated in
/// words whether or not it differs from where the page is sitting.
enum LevelRailCopy {

    /// The line under the level's own description: what this site is set to, and
    /// where the page lands when nothing is set.
    static func standing(preference: SitePreference, automatic: PageLevel) -> String {
        switch preference {
        case .auto:
            "Automatic here — on its own this page lands at \(automatic.title)."
        case .pinned(let pin) where pin == automatic:
            "Always \(pin.title) here, which is also where this page lands on its own."
        case .pinned(let pin):
            "Always \(pin.title) here — on its own this page lands at \(automatic.title)."
        case .ceiling(let cap) where automatic <= cap:
            "Never above \(cap.title) here. On its own this page lands at \(automatic.title)."
        case .ceiling(let cap):
            "Never above \(cap.title) here, so \(automatic.title) is held back to \(cap.title)."
        }
    }

    /// The stop the page is **actually at**: the level, capped by what this
    /// document turned out to be able to do.
    ///
    /// The distinction the whole control rests on. The level is a *request*. It is
    /// per origin and it outlives this page, so a pin to Reader has to survive one
    /// thin page and be in force again on the next article — which is why the
    /// clamp lives here, in the layer that chooses words, and never in the stored
    /// level. Clamping the model instead would strand the user at Calm the moment
    /// they navigated somewhere with prose in it.
    ///
    /// The ceiling is a fact about this document, so naming a stop above it is
    /// invariant 8: the control claiming a state the page is not in.
    static func effective(level: PageLevel, ceiling: PageLevel) -> PageLevel {
        min(level, ceiling)
    }

    /// The one word beside the dots.
    ///
    /// With the pointer on a stop the label previews *that* stop, which is a
    /// question about a target rather than a claim about the page — and it is drawn
    /// in `labelColor` for exactly as long as it is one. With no pointer the label
    /// describes the page, and describing the page means the effective stop: on
    /// google.com, which reported too little prose to rebuild, a rail reading
    /// "Reader" was the control naming a stop the page never reached.
    ///
    /// `(held)` when the request is above the ceiling, because a level the user
    /// asked for is not erased by one page that could not honour it — the pin is
    /// still standing and applies again on the next document. One word is all the
    /// label has room for — see ``LevelRailView/labelWidth`` — so the reason lives
    /// in the tooltip, beside the same reason the struck stops give.
    static func label(level: PageLevel, ceiling: PageLevel, hovered: PageLevel?) -> String {
        if let hovered { return hovered.title }
        let stop = effective(level: level, ceiling: ceiling)
        return level > ceiling ? "\(stop.title) (held)" : stop.title
    }

    /// The whole tooltip: the stop under the pointer, or the page.
    ///
    /// A stop the page cannot reach answers with the reason and nothing else. The
    /// user is asking why it is struck out, and burying that under a description of
    /// a level they cannot have would be answering a question they did not ask.
    static func tooltip(
        hovered: PageLevel?,
        level: PageLevel,
        ceiling: PageLevel,
        ceilingReason: String?,
        preference: SitePreference,
        automatic: PageLevel
    ) -> String? {
        if let hovered, hovered > ceiling { return ceilingReason }

        let stop = hovered ?? effective(level: level, ceiling: ceiling)
        var blocks = ["\(stop.title) — \(stop.summary)"]
        // Resting on a page that could not honour the request. The label had room
        // for "(held)" and no more, so this is where the two halves of the honest
        // answer are stated: what is on screen, and why the request is not it.
        if hovered == nil, level > ceiling {
            blocks.append(
                ["\(level.title) is not in effect on this page.", ceilingReason]
                    .compactMap { $0 }
                    .joined(separator: " ")
            )
        }
        blocks.append(standing(preference: preference, automatic: automatic))
        blocks.append("Less ⌥⌘[  ·  More ⌥⌘]")
        return blocks.joined(separator: "\n\n")
    }

    /// The slider's value, for VoiceOver.
    ///
    /// The level alone was the same string whether it was a pin or the page's own
    /// answer, which is the sighted user's complaint in the one place they cannot
    /// see the hollow ring at all.
    ///
    /// It names the effective stop for the same reason the label does, and then the
    /// request, because the inert dot that carries "asked for, not in force" on
    /// screen is the one mark VoiceOver cannot read at all.
    static func accessibilityValue(
        level: PageLevel,
        ceiling: PageLevel,
        preference: SitePreference
    ) -> String {
        let stop = effective(level: level, ceiling: ceiling)
        let standing =
            switch preference {
            case .auto: "automatic"
            case .pinned(let pin): "always \(pin.title) on this site"
            case .ceiling(let cap): "never above \(cap.title) on this site"
            }
        guard level > ceiling else { return "\(stop.title), \(standing)" }
        return "\(stop.title), \(standing), \(level.title) not in effect on this page"
    }

    /// The detail menu's first item.
    ///
    /// Named rather than bare, because "Automatic" is the default and a default the
    /// user cannot read the value of is a setting they have to guess at. This is
    /// the site's automatic answer and deliberately not the rail's, which is capped
    /// by what one document turned out to be — the pins in the same menu are
    /// site-scope for the same reason.
    static func automaticMenuTitle(_ automatic: PageLevel) -> String {
        "Automatic (\(automatic.title))"
    }
}

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
    /// What this site is set to. Drawn only in words — the ring already carries the
    /// override visually, and a second glyph for the same fact would be two marks
    /// the user has to learn to tell apart.
    private var preference: SitePreference = .auto

    private var hovered: PageLevel?

    private let label = NSTextField(labelWithString: "")

    /// What the label is showing. The wiring between ``LevelRailCopy`` and the one
    /// string on screen is otherwise no more observable than `draw(_:)` is, and it
    /// is the half that was wrong: the sentence was right and the word was not.
    var displayedTitle: String { label.stringValue }

    // Geometry. The rail has to earn its ~110pt against the breadcrumb, which is
    // the toolbar's most valuable tenant, so the dots are tight and the label
    // carries the meaning.
    private let dotSize: CGFloat = 8
    /// Size of the current stop, which is drawn larger so the eye lands on it first.
    private let activeDotSize: CGFloat = 12
    private let dotSpacing: CGFloat = 22
    /// Extra gap before the last stop. This is the consent boundary made visible.
    private let thresholdGap: CGFloat = 12
    /// Wide enough for the longest thing the label can say, which is no longer a
    /// bare level name: `Reader (held)` needs 71pt and the old 64 truncated it to
    /// `Reader (hel…`. A control that gets cut off mid-word answering "what is this
    /// page at" is barely better than one that answers wrong. Held to the font
    /// beside it by ``LevelRailCopy`` and a test that measures every string.
    static let labelWidth: CGFloat = 72
    static let labelFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    private let railInset: CGFloat = 7

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        label.font = Self.labelFont
        label.textColor = .secondaryLabelColor
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: Self.labelWidth),
            widthAnchor.constraint(equalToConstant: railWidth + 4 + Self.labelWidth),
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
        ceilingReason: String?,
        preference: SitePreference
    ) {
        self.level = level
        self.automatic = automatic
        self.ceiling = ceiling
        self.ceilingReason = ceilingReason
        self.preference = preference
        apply()
    }

    private func apply() {
        // The label previews whatever the pointer is over, so a stop can be read
        // before it is chosen — five dots cannot say "Calm" on their own, and a
        // control whose options are only legible after you pick one is a guess.
        // With nothing under the pointer it names the page instead of the request;
        // see ``LevelRailCopy/label(level:ceiling:hovered:)``.
        label.stringValue = LevelRailCopy.label(level: level, ceiling: ceiling, hovered: hovered)
        label.textColor = hovered == nil ? .secondaryLabelColor : .labelColor

        toolTip = LevelRailCopy.tooltip(
            hovered: hovered,
            level: level,
            ceiling: ceiling,
            ceilingReason: ceilingReason,
            preference: preference,
            automatic: automatic
        )
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
        hover(stop(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        hover(nil)
    }

    /// Put the pointer on a stop, or take it off the rail.
    ///
    /// One door, because the alternative for a test is an `NSEvent` positioned in a
    /// window it does not have — and what the pointer changes is the label and the
    /// tooltip, which are the two things worth asserting on.
    func hover(_ stop: PageLevel?) {
        guard stop != hovered else { return }
        hovered = stop
        apply()
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { "Page level" }
    override func accessibilityValue() -> Any? {
        LevelRailCopy.accessibilityValue(level: level, ceiling: ceiling, preference: preference)
    }
}
