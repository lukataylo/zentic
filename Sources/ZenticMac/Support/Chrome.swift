import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Chrome design tokens.
///
/// The Swift half of the "one token set" rule: the reader's tokens live in CSS,
/// the browser's live here, and the two are kept visually aligned so the page and
/// the window read as one product. Nothing here is a magic number at a call site.
enum Chrome {
    static let sidebarDefaultWidth: CGFloat = 260
    static let sidebarMinWidth: CGFloat = 200
    static let sidebarMaxWidth: CGFloat = 420

    /// Clears the traffic lights, which AppKit draws at the window's top-left —
    /// i.e. inside the sidebar, which is the whole point of the Arc layout.
    static let trafficLightInset: CGFloat = 52

    static let sidebarHorizontalPadding: CGFloat = 10
    static let rowHeight: CGFloat = 30
    static let rowRadius: CGFloat = 8
    /// Selected-tab pill. Slightly rounder than an unselected hover fill, which is
    /// what makes it read as a raised card rather than a highlight.
    static let selectedRowRadius: CGFloat = 10
    static let rowIconSize: CGFloat = 16
    static let groupIndent: CGFloat = 16

    static let pinTileSize: CGFloat = 44
    static let pinColumns = 4
    static let pinGridSpacing: CGFloat = 6
    static let pinRadius: CGFloat = 10

    static let toolbarHeight: CGFloat = 38
    static let findBarHeight: CGFloat = 34
    static let contentRadius: CGFloat = 10
    /// Gap between the content card and the window edge, so the space tint shows
    /// around it.
    static let contentInset: CGFloat = 8

    static let sectionSpacing: CGFloat = 8
    static let animationDuration: TimeInterval = 0.16

    // MARK: - Glass

    /// Corner radius for a floating glass panel. Larger than a row's, because a
    /// panel that overlaps the page needs to read as a separate pane of glass.
    static let glassRadius: CGFloat = 14
    /// Hairline edge. A device pixel, not a point — a 1pt border on Retina reads as
    /// a drawn line, and the whole effect depends on the edge being a *refraction*.
    static let glassStrokeWidth: CGFloat = 0.5
    /// Soft and wide, not dark and tight. The shadow is there to prove a surface
    /// floats above what it covers; anything heavier reads as a drop-shadow effect
    /// rather than depth, which is the difference between glass and a sticker.
    static let glassShadowRadius: CGFloat = 14
    static let glassShadowOpacity: Float = 0.10

    /// Reveal animation for auto-hidden chrome. Slower than ``animationDuration``:
    /// a panel sliding in over the page is a spatial move and reads as abrupt if it
    /// matches the speed of a colour change.
    static let revealDuration: TimeInterval = 0.22
    /// How long a revealed panel waits after the pointer leaves before hiding.
    /// Without it, clipping a corner of the panel on the way to the page snaps it
    /// shut mid-gesture.
    static let revealHideDelay: TimeInterval = 0.35
    /// Width of the invisible strip that triggers a reveal.
    static let revealHotZone: CGFloat = 6
}

/// The glass palette.
///
/// Glassmorphism is four things over a blur: a translucent fill, a hairline edge
/// lighter than the fill, a specular highlight along the top, and a shadow that
/// proves the surface is above what it covers. Values differ by appearance because
/// the effect inverts: light glass is white-over-content, dark glass is
/// white-over-dark at much lower alpha, and using the light alphas in dark mode
/// produces the milky grey that gives cheap imitations away.
enum Glass {
    static func fill(dark: Bool) -> NSColor {
        dark
            ? NSColor.white.withAlphaComponent(0.055)
            : NSColor.white.withAlphaComponent(0.42)
    }

    /// Edge, top-lit. Brighter than the fill, which is what makes it an edge and
    /// not a border.
    static func stroke(dark: Bool) -> NSColor {
        dark
            ? NSColor.white.withAlphaComponent(0.13)
            : NSColor.white.withAlphaComponent(0.62)
    }

    /// The specular run along the top edge, brightest at the top and gone within a
    /// few points.
    static func highlight(dark: Bool) -> NSColor {
        dark
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.white.withAlphaComponent(0.55)
    }

    /// Fill for a small surface that sits *on* the glass rather than being glass —
    /// a selected tab pill, a pin tile, the address field.
    static func raisedFill(dark: Bool) -> NSColor {
        dark
            ? NSColor.white.withAlphaComponent(0.14)
            : NSColor.white.withAlphaComponent(0.72)
    }

    /// Hover state for the same surfaces.
    static func hoverFill(dark: Bool) -> NSColor {
        dark
            ? NSColor.white.withAlphaComponent(0.07)
            : NSColor.white.withAlphaComponent(0.34)
    }
}

extension NSView {
    /// True when this view is currently drawing in a dark appearance.
    var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// A frosted panel: blur, translucent fill, hairline edge, specular top, shadow.
///
/// Backed by a real `NSVisualEffectView`, so it is only used for the two large
/// surfaces that float over the page. Everything smaller gets ``Glass/raisedFill``
/// over the blur that is already behind it — see the note on ``Chrome`` glass
/// tokens for why that distinction is load-bearing rather than fussy.
final class GlassPanel: NSVisualEffectView {
    private let highlight = CAGradientLayer()

    /// - Parameter withinWindow: `true` for a panel that floats over the page, which
    ///   must blur the *window's* content; `false` for one that blurs the desktop.
    init(withinWindow: Bool) {
        super.init(frame: .zero)
        material = withinWindow ? .hudWindow : .sidebar
        blendingMode = withinWindow ? .withinWindow : .behindWindow
        state = .followsWindowActiveState
        wantsLayer = true

        maskImage = nil
        layer?.cornerRadius = Chrome.glassRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Chrome.glassStrokeWidth
        // The shadow has to escape the bounds, so the panel cannot clip itself. Its
        // corner radius still applies to the blur, because `NSVisualEffectView`
        // masks its own material to the layer's shape.
        layer?.masksToBounds = false
        layer?.shadowRadius = Chrome.glassShadowRadius
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        highlight.startPoint = CGPoint(x: 0.5, y: 1)
        highlight.endPoint = CGPoint(x: 0.5, y: 0)
        highlight.cornerRadius = Chrome.glassRadius
        highlight.cornerCurve = .continuous
        layer?.addSublayer(highlight)

        apply()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        // The specular run occupies the top few points only; below that it is clear.
        highlight.frame = bounds
        // Kept in sync explicitly: an implicitly animated shadow path lags a resize
        // by a frame and shows as a bright seam down the moving edge.
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: Chrome.glassRadius,
            cornerHeight: Chrome.glassRadius,
            transform: nil
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { apply() }
    }

    private func apply() {
        let dark = isDarkAppearance
        layer?.backgroundColor = Glass.fill(dark: dark).cgColor
        layer?.borderColor = Glass.stroke(dark: dark).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = Chrome.glassShadowOpacity
        let top = Glass.highlight(dark: dark).cgColor
        highlight.colors = [top, NSColor.clear.cgColor]
        // A short run: the highlight is spent within the top ~8% of the panel.
        highlight.locations = [0, 0.08]
    }
}

extension NSColor {
    /// Parse `#rrggbb`. Returns nil rather than a guess, so a bad tint falls back
    /// to the default rather than silently rendering black.
    convenience init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Rotate hue and lift brightness, for the second stop of a space gradient.
    func shifted(hue: CGFloat, brightness: CGFloat) -> NSColor {
        guard let base = usingColorSpace(.sRGB) else { return self }
        var h = base.hueComponent + hue
        h -= h.rounded(.down)
        return NSColor(
            hue: h,
            saturation: min(1, base.saturationComponent),
            brightness: min(1, max(0, base.brightnessComponent + brightness)),
            alpha: base.alphaComponent
        )
    }
}

extension NSImage {
    /// JPEG for a suspended tab's snapshot.
    ///
    /// JPEG, not PNG: a page screenshot is photographic, and PNG at 1200×800 runs
    /// to several megabytes per tab — thirty of those in the store is a real cost
    /// for something only ever shown for a few hundred milliseconds.
    /// Encoded straight from the backing `CGImage`.
    ///
    /// The obvious version — `tiffRepresentation` into an `NSBitmapImageRep` — costs
    /// two full uncompressed copies of the image before any compression happens, and
    /// both are autoreleased. Snapshots are taken from an async task, where no
    /// run loop drains the pool, so those copies accumulate: measured at roughly
    /// 8MB of permanent growth per tab suspended. Going via `CGImageDestination`
    /// allocates neither, and the explicit pool bounds what is left.
    func jpegData(quality: CGFloat) -> Data? {
        autoreleasepool {
            var rect = CGRect(origin: .zero, size: size)
            guard let image = cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                return nil
            }
            let output = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    output,
                    UTType.jpeg.identifier as CFString,
                    1,
                    nil
                )
            else { return nil }
            CGImageDestinationAddImage(
                destination,
                image,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else { return nil }
            return output as Data
        }
    }
}

/// Base class for layer-backed chrome.
///
/// `CGColor` is a *resolved* colour, so a layer painted with one does not follow
/// light/dark mode — the classic AppKit-with-layers bug. Subclasses put their layer
/// colour assignments in ``updateLayerColors()``, which runs once at init and again
/// on every appearance change, with the correct appearance already current.
class ChromeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func updateLayerColors() {}

    /// Call at the end of a subclass initialiser, once its outlets exist.
    final func applyLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { updateLayerColors() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLayerColors()
    }
}
