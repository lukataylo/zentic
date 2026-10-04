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
/// a transparent, full-size titlebar over the tinted glass frame.
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
            TrafficLights.window = window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

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

/// Hides the close/minimise/zoom buttons along with a collapsed sidebar, so
/// the page gets every pixel; they come back when the sidebar does.
@MainActor
enum TrafficLights {
    /// Set when the window appears; applies whatever was asked for before.
    static weak var window: NSWindow? {
        didSet { setHidden(hidden) }
    }
    private static var hidden = false

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
}
