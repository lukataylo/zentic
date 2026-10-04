import AppKit
import SwiftUI

/// Behind-window vibrancy: what the sidebar and window frame are made of.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        // Always live. By default AppKit flattens vibrancy to an opaque grey
        // whenever the window isn't key (Settings open, another app in front),
        // and the glass frame would visibly switch off.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// Reaches the hosting `NSWindow` to set what SwiftUI scene modifiers cannot:
/// a transparent, full-size titlebar with the traffic lights seated on the
/// toolbar's row.
struct WindowConfigurator: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        let view = ConfiguratorView()
        view.onWindow = { window in
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = false
            window.tabbingMode = .disallowed
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.setFrameAutosaveName("ZenticBrowserWindow")
            context.coordinator.observe(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var tokens: [NSObjectProtocol] = []

        func observe(_ window: NSWindow) {
            tokens.forEach(NotificationCenter.default.removeObserver)
            let center = NotificationCenter.default
            tokens = []

            // AppKit lays the titlebar out again on every resize and on leaving
            // full screen, so the traffic lights are re-seated each time.
            for name in [
                NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didEndLiveResizeNotification,
            ] {
                tokens.append(
                    center.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                        MainActor.assumeIsolated { window.map(TrafficLights.seat) }
                    })
            }
            TrafficLights.seat(window)
            DispatchQueue.main.async { TrafficLights.seat(window) }
        }
    }

    final class ConfiguratorView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// A view that drags the window, and zooms it on double-click — the titlebar's
/// two jobs, for regions that stand in for a titlebar.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                // Respect the user's "double-click a window's title bar to" setting.
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                switch action {
                case "Minimize": window?.performMiniaturize(nil)
                case "None": break
                default: window?.performZoom(nil)
                }
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}

extension View {
    /// Glass for panels that hold text the user reads or types — the command
    /// bar, the composer.
    ///
    /// Liquid Glass cannot sample a web view: page content is drawn by
    /// WebKit's own process, so over a page `glassEffect` alone renders all but
    /// invisible and the site's text runs straight through. ``GlassSurface``
    /// draws the body of the glass itself; the system glass on top still
    /// gives the sheen, the press response and the morphing between shapes.
    func panelGlass<S: Shape>(in shape: S) -> some View {
        background(GlassSurface(shape: shape, strength: .panel))
            .glassEffect(.regular, in: shape)
    }

    /// The floating toolbar's surface. See ``panelGlass(in:)``.
    func chromeGlass<S: Shape>(in shape: S, interactive: Bool = true) -> some View {
        background(GlassSurface(shape: shape, strength: .chrome))
            .glassEffect(.regular.interactive(interactive), in: shape)
    }
}

/// A hand-drawn pane of frosted glass: a translucent body, a bright rim
/// catching light from above, a hairline edge so it never dissolves into a
/// white page, and a soft shadow lifting it off the content.
struct GlassSurface<S: Shape>: View {
    enum Strength { case chrome, panel }
    let shape: S
    let strength: Strength
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let body: Color =
            dark
            ? Color(red: 0.13, green: 0.13, blue: 0.15).opacity(strength == .panel ? 0.95 : 0.9)
            : Color(red: 0.965, green: 0.965, blue: 0.975).opacity(strength == .panel ? 0.96 : 0.92)
        shape
            .fill(body)
            .overlay {
                // Light from above: a rim that is bright at the top edge and
                // fades out, the detail that makes a flat fill read as glass.
                shape.stroke(
                    LinearGradient(
                        colors: [.white.opacity(dark ? 0.22 : 0.95), .white.opacity(dark ? 0.04 : 0.35)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
                .padding(0.5)
            }
            .overlay {
                shape.stroke(Color.black.opacity(dark ? 0.5 : 0.10), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(dark ? 0.45 : 0.13), radius: strength == .panel ? 22 : 10, x: 0, y: strength == .panel ? 10 : 3)
            .shadow(color: .black.opacity(dark ? 0.3 : 0.06), radius: 1, x: 0, y: 0.5)
    }
}

/// Moves the close/minimise/zoom buttons down so they sit on the same line as
/// the floating toolbar's buttons, as in Arc and Dia, instead of hugging the
/// window's top edge above them.
@MainActor
enum TrafficLights {
    /// Distance from the window's top edge to the buttons' centre: the card's
    /// 8pt inset plus half the toolbar row (9pt top padding + 34pt buttons).
    static let centreY: CGFloat = 8 + 9 + 17
    static let leading: CGFloat = 20

    private static weak var window: NSWindow?
    private static var hidden = false

    /// Hide the buttons with the sidebar, so a collapsed sidebar gives the
    /// page every pixel; they come back with it when it slides in.
    static func setHidden(_ hide: Bool) {
        hidden = hide
        guard let window else { return }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                button.animator().alphaValue = hide ? 0 : 1
            }
            button.isEnabled = !hide
        }
    }

    static func seat(_ window: NSWindow) {
        self.window = window
        guard !window.styleMask.contains(.fullScreen),
            let close = window.standardWindowButton(.closeButton),
            let mini = window.standardWindowButton(.miniaturizeButton),
            let zoom = window.standardWindowButton(.zoomButton),
            let titlebar = close.superview,
            let container = titlebar.superview
        else { return }

        // Make the titlebar tall enough to hold the buttons at their new
        // height; otherwise they are clipped by it.
        let height = centreY * 2
        var frame = container.frame
        frame.size.height = height
        frame.origin.y = window.frame.height - height
        container.frame = frame
        titlebar.frame = container.bounds

        let spacing = mini.frame.minX - close.frame.minX
        for (index, button) in [close, mini, zoom].enumerated() {
            button.setFrameOrigin(
                NSPoint(
                    x: leading + CGFloat(index) * spacing,
                    y: (height - button.frame.height) / 2))
            button.alphaValue = hidden ? 0 : 1
        }
    }
}
