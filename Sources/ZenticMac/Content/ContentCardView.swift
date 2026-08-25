import AppKit
import WebKit

/// The rounded card the page lives in.
///
/// Three layers, back to front: the web view, a snapshot placeholder shown while a
/// suspended tab reloads, and an empty-state prompt for a tab with no URL yet.
/// The placeholder is the visible payoff of suspension — without it, switching to a
/// suspended tab flashes white, which is exactly the tell that would give the trick
/// away.
final class ContentCardView: ChromeView {
    var onAddressRequested: (() -> Void)?

    /// Clips the page to the card's rounded corners.
    ///
    /// A separate view because the card itself must *not* clip: it carries the
    /// shadow that lifts it off the glass, and `masksToBounds` would cut the shadow
    /// off at the very edge it is drawn from.
    private let clip = ChromeView(frame: .zero)
    private let host = NSView()
    private let placeholder = NSImageView()
    private let startPage = NSStackView()
    /// The tab currently on top. Weak: the tab controller owns its web view, and a
    /// suspended tab's must be free to deallocate.
    private weak var currentWebView: WKWebView?
    private var placeholderTimeout: Task<Void, Never>?
    private var fadeOut: Task<Void, Never>?
    private let fadeDuration: TimeInterval = 0.12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        layer?.cornerRadius = Chrome.contentRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        layer?.borderWidth = Chrome.glassStrokeWidth
        layer?.shadowRadius = Chrome.glassShadowRadius
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        clip.layer?.cornerRadius = Chrome.contentRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.translatesAutoresizingMaskIntoConstraints = false

        host.translatesAutoresizingMaskIntoConstraints = false

        placeholder.imageScaling = .scaleProportionallyUpOrDown
        placeholder.imageAlignment = .alignTop
        placeholder.isHidden = true
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        buildStartPage()

        addSubview(clip)
        clip.addSubview(host)
        clip.addSubview(placeholder)
        clip.addSubview(startPage)

        NSLayoutConstraint.activate([
            clip.topAnchor.constraint(equalTo: topAnchor),
            clip.leadingAnchor.constraint(equalTo: leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: trailingAnchor),
            clip.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for subview in [host, placeholder, startPage] {
            NSLayoutConstraint.activate([
                subview.topAnchor.constraint(equalTo: clip.topAnchor),
                subview.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
                subview.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            ])
        }

        applyLayerColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateLayerColors() {
        // Translucent. See ``Glass/pageFill(dark:)`` for why this stopped being
        // opaque. It only shows where nothing paints over it — a site with its own
        // background still covers it completely, which is the correct outcome:
        // making other people's pages see-through would be a rendering bug, not a
        // feature.
        clip.layer?.backgroundColor = Glass.pageFill(dark: isDarkAppearance).cgColor
        layer?.backgroundColor = Glass.pageFill(dark: isDarkAppearance).cgColor
        // The edge and the shadow separate the card from the tint behind it. They
        // matter more now than they did when the card was opaque: a translucent
        // card with no edge has nothing to distinguish it from the chrome.
        layer?.borderColor = Glass.stroke(dark: isDarkAppearance).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = Chrome.glassShadowOpacity
    }

    override func layout() {
        super.layout()
        // Explicit rather than derived from the layer's shape each frame: an
        // implicit shadow path lags a live window resize and shows as a bright seam.
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: layer?.cornerRadius ?? Chrome.contentRadius,
            cornerHeight: layer?.cornerRadius ?? Chrome.contentRadius,
            transform: nil
        )
    }

    private func buildStartPage() {
        let title = NSTextField(labelWithString: "Zentic")
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        title.textColor = .tertiaryLabelColor

        let hint = NSTextField(labelWithString: "⌘L to type an address · ⌘K for anything else")
        hint.font = .systemFont(ofSize: 12.5)
        hint.textColor = .quaternaryLabelColor

        let button = NSButton(
            title: "Enter an address",
            target: self,
            action: #selector(requestAddress)
        )
        button.bezelStyle = .rounded

        startPage.orientation = .vertical
        startPage.alignment = .centerX
        startPage.spacing = 10
        startPage.translatesAutoresizingMaskIntoConstraints = false
        startPage.addView(title, in: .center)
        startPage.addView(hint, in: .center)
        startPage.addView(button, in: .center)
        startPage.isHidden = true
    }

    @objc private func requestAddress() { onAddressRequested?() }

    /// Bring a tab's web view to the front, optionally behind a snapshot.
    ///
    /// The outgoing web view is deliberately **left in the hierarchy**, merely
    /// covered. `WKWebView.takeSnapshot` requires the view to be in a window, so
    /// removing it here would mean every suspension captured nothing — the tab the
    /// user just left is precisely the one that needs a placeholder. The caller
    /// removes it via ``discardCoveredWebViews()`` once its snapshot is safe.
    func present(webView: WKWebView, placeholder image: NSImage?) {
        if webView.superview !== host {
            host.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: host.topAnchor),
                webView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }

        // Reordered by assigning `subviews` rather than re-adding: passing an
        // existing subview to `addSubview(_:positioned:relativeTo:)` takes it out of
        // the hierarchy first, which drops its constraints.
        var ordered = host.subviews.filter { $0 !== webView }
        ordered.append(webView)
        host.subviews = ordered

        currentWebView = webView
        window?.makeFirstResponder(webView)
        show(placeholder: image)
    }

    /// Detach every web view except the frontmost one.
    func discardCoveredWebViews() {
        for subview in host.subviews where subview !== currentWebView {
            subview.removeFromSuperview()
        }
    }

    private func show(placeholder image: NSImage?) {
        placeholderTimeout?.cancel()
        fadeOut?.cancel()
        placeholder.alphaValue = 1
        placeholder.image = image
        placeholder.isHidden = image == nil
        guard image != nil else { return }

        // A hard ceiling, for the same reason the reader has one: a placeholder that
        // outlives its load is indistinguishable from a frozen page.
        placeholderTimeout = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_400))
            guard !Task.isCancelled else { return }
            self?.hidePlaceholder()
        }
    }

    func hidePlaceholder() {
        placeholderTimeout?.cancel()
        placeholderTimeout = nil
        guard !placeholder.isHidden else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
            placeholder.animator().alphaValue = 0
        }
        // Teardown rides on a task rather than the animation's completion handler:
        // that handler is `@Sendable`, so under strict concurrency it cannot touch
        // main-actor view state at all.
        fadeOut = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.12))
            guard !Task.isCancelled, let self else { return }
            self.placeholder.isHidden = true
            self.placeholder.alphaValue = 1
            self.placeholder.image = nil
        }
    }

    func setStartPageVisible(_ visible: Bool) {
        startPage.isHidden = !visible
        if visible { hidePlaceholder() }
    }

    func setCornersRounded(_ rounded: Bool) {
        layer?.cornerRadius = rounded ? Chrome.contentRadius : 0
        clip.layer?.cornerRadius = rounded ? Chrome.contentRadius : 0
        // Focus mode runs the page to every edge, where a border and a shadow would
        // be a line and a smudge against the screen edge rather than depth.
        layer?.borderWidth = rounded ? Chrome.glassStrokeWidth : 0
        layer?.shadowOpacity = rounded ? Chrome.glassShadowOpacity : 0
        needsLayout = true
    }
}

/// The per-space tint: a vertical gradient over the window's vibrancy.
///
/// Partial alpha, not a solid fill — the whole point is that the desktop shows
/// through, which is what stops a coloured sidebar looking like painted plastic.
final class TintView: ChromeView {
    private let gradient = CAGradientLayer()
    private let bloom = CAGradientLayer()
    private var color: NSColor = .systemIndigo
    private var strength: TintStrength = .clear

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        gradient.startPoint = CGPoint(x: 0.15, y: 1)  // top-left-ish
        gradient.endPoint = CGPoint(x: 0.85, y: 0)
        layer?.addSublayer(gradient)

        // A soft light source in the top-left corner. Real glass is not evenly
        // coloured — it catches light somewhere — and a flat gradient is what makes
        // a tinted panel read as painted plastic instead.
        bloom.type = .radial
        bloom.startPoint = CGPoint(x: 0.1, y: 1.05)
        bloom.endPoint = CGPoint(x: 1.25, y: -0.35)
        layer?.addSublayer(bloom)

        applyLayerColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setTint(_ color: NSColor) {
        self.color = color
        applyLayerColors()
    }

    /// How much colour sits over the vibrancy. See ``TintStrength``.
    func setStrength(_ strength: TintStrength) {
        self.strength = strength
        applyLayerColors()
    }

    override func layout() {
        super.layout()
        gradient.frame = bounds
        bloom.frame = bounds
    }

    override func updateLayerColors() {
        let isDark = isDarkAppearance
        let alpha = strength.alpha(dark: isDark)
        gradient.colors = [
            color.shifted(hue: -0.03, brightness: 0.06).withAlphaComponent(alpha.top).cgColor,
            color.shifted(hue: 0.05, brightness: -0.04).withAlphaComponent(alpha.bottom).cgColor,
        ]
        bloom.colors = [
            NSColor.white.withAlphaComponent(isDark ? 0.06 : 0.30).cgColor,
            NSColor.clear.cgColor,
        ]
        bloom.locations = [0, 0.75]
    }
}

/// How heavily a space's colour is laid over the window's vibrancy.
///
/// The tint used to be fixed at an alpha high enough to read as a solid colour,
/// which defeated the vibrancy underneath it — the desktop could not show through,
/// so the sidebar looked like a painted panel rather than a pane of glass. These
/// are the presets, lightest first; `frosted` is the old behaviour, kept for anyone
/// who wants the colour to dominate.
enum TintStrength: String, CaseIterable, Codable {
    /// The default: barely there, so the desktop reads clearly through the sidebar.
    case clear
    /// Enough colour to identify the space, still obviously glass.
    case glass
    /// Colour-forward, vibrancy still visible.
    case tinted
    /// The original heavy wash.
    case frosted

    var title: String {
        switch self {
        case .clear: "Clear"
        case .glass: "Glass"
        case .tinted: "Tinted"
        case .frosted: "Frosted"
        }
    }

    /// Dark mode needs consistently less: the same alpha over a dark vibrancy
    /// reads as a muddy wash rather than a colour.
    func alpha(dark: Bool) -> (top: CGFloat, bottom: CGFloat) {
        switch self {
        case .clear: dark ? (0.10, 0.04) : (0.14, 0.06)
        case .glass: dark ? (0.18, 0.08) : (0.24, 0.10)
        case .tinted: dark ? (0.26, 0.12) : (0.33, 0.15)
        case .frosted: dark ? (0.34, 0.16) : (0.42, 0.20)
        }
    }
}

/// The draggable edge between sidebar and content.
final class SidebarResizeHandle: NSView {
    /// New sidebar width, in window coordinates from the leading edge.
    var onDrag: ((CGFloat) -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil).x)
    }

    /// Transparent to hit-testing except on its own narrow strip, so it does not eat
    /// clicks meant for the sidebar's rows or the page.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : super.hitTest(point)
    }
}
