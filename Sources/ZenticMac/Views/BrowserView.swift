import SwiftUI
import ZenticKit

/// The window: a tinted, translucent frame holding the sidebar and the page.
struct BrowserView: View {
    @Environment(Browser.self) private var browser
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            WindowBackground(tint: app.tint)

            HStack(spacing: 0) {
                if browser.sidebarVisible {
                    Sidebar()
                        .frame(width: browser.sidebarWidth)
                        .overlay(alignment: .trailing) { SidebarResizeHandle() }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                // With the sidebar gone the traffic lights hide too (see
                // `TrafficLights`), so the toolbar takes the whole row.
                ContentCard()
                    .padding(.vertical, 8)
                    .padding(.trailing, 8)
                    .padding(.leading, browser.sidebarVisible ? 0 : 8)
            }

            if !browser.sidebarVisible {
                SidebarPeek()
            }
        }
        .ignoresSafeArea()
        .background(WindowConfigurator())
        .animation(.smooth(duration: 0.32), value: browser.sidebarVisible)
        .onChange(of: browser.sidebarVisible || browser.sidebarPeeking, initial: true) { _, shown in
            TrafficLights.setHidden(!shown)
        }
    }
}

/// Behind-window blur washed with the user's tint, like Arc's space colour.
struct WindowBackground: View {
    var tint: SidebarTint
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // The desktop, blurred: what makes the frame read as glass.
            // `.fullScreenUI`: the sidebar materials are nearly opaque in light
            // mode and hide the desktop entirely, which is not glass.
            VisualEffect(material: .fullScreenUI)
            LinearGradient(
                colors: tint.colors(dark: scheme == .dark),
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            // Translucency 0 is a fairly dense wash, 1 nearly clear glass; the
            // whole range shows the desktop through. Never fully clear: the
            // sidebar's text needs something to sit on.
            .opacity(0.6 - app.translucency * 0.48)
        }
        .ignoresSafeArea()
    }
}

/// Drag the sidebar's trailing edge to resize it.
private struct SidebarResizeHandle: View {
    @Environment(Browser.self) private var browser
    @State private var start: Double?

    var body: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .trailing))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let origin = start ?? browser.sidebarWidth
                        start = origin
                        browser.sidebarWidth = min(max(origin + value.translation.width, 200), 420)
                    }
                    .onEnded { _ in start = nil }
            )
            .offset(x: 4)
    }
}

/// With the sidebar hidden, resting the pointer on the window's leading edge
/// slides it in over the page, and moving away puts it back.
private struct SidebarPeek: View {
    @Environment(Browser.self) private var browser
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: 10)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { withAnimation(.smooth(duration: 0.28)) { browser.sidebarPeeking = true } }
                }

            if browser.sidebarPeeking {
                // Slides in exactly where the docked sidebar lives — flush with
                // the window's edge, the same glass, the traffic lights in their
                // usual place — and casts a shadow over the page it covers.
                let shape = UnevenRoundedRectangle(
                    topLeadingRadius: 0, bottomLeadingRadius: 0,
                    bottomTrailingRadius: Metrics.cardRadius, topTrailingRadius: Metrics.cardRadius,
                    style: .continuous)
                Sidebar()
                    .frame(width: browser.sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .background {
                        ZStack {
                            VisualEffect(material: .sidebar, blending: .behindWindow)
                            WindowBackground(tint: app.tint)
                        }
                        .clipShape(shape)
                    }
                    .overlay { shape.stroke(Color.white.opacity(0.18), lineWidth: 0.5) }
                    .shadow(color: .black.opacity(0.25), radius: 18, x: 6, y: 0)
                    .onHover { inside in
                        if !inside { withAnimation(.smooth(duration: 0.28)) { browser.sidebarPeeking = false } }
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
    }
}
