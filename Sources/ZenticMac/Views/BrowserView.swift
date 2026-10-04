import SwiftUI
import ZenticKit

/// The window: a tinted, translucent frame holding the sidebar and the page.
struct BrowserView: View {
    @Environment(Browser.self) private var browser
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var isFullScreen = false

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
                ContentCard(leadingClearance: 0)
                    .padding(.vertical, 8)
                    .padding(.trailing, 8)
                    .padding(.leading, browser.sidebarVisible ? 0 : 8)
            }

            if !browser.sidebarVisible {
                SidebarPeek()
            }
        }
        .ignoresSafeArea()
        .background(WindowConfigurator(isFullScreen: $isFullScreen))
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
            // Translucency 0 is a solid wash; 1 is nearly clear glass. Never
            // fully clear — the sidebar's text needs something to sit on.
            .opacity(0.92 - app.translucency * (scheme == .dark ? 0.62 : 0.66))
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
                Sidebar(isFloating: true)
                    .frame(width: browser.sidebarWidth)
                    .background {
                        ZStack {
                            VisualEffect(material: .hudWindow)
                            WindowBackground(tint: app.tint).opacity(0.9)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.12))
                    }
                    .shadow(color: .black.opacity(0.3), radius: 24, x: 0, y: 8)
                    .padding(.vertical, 8)
                    .padding(.leading, 6)
                    .onHover { inside in
                        if !inside { withAnimation(.smooth(duration: 0.28)) { browser.sidebarPeeking = false } }
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
    }
}
