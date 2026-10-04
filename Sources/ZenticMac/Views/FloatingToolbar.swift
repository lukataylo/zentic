import SwiftUI
import ZenticKit

/// The controls that float over the top of the page.
///
/// At the top of a page they are a full bar of glass. Scroll down and they
/// fold into a small pill naming the site, giving the page the whole card;
/// scroll up, hover the top edge, or click the pill, and they open again.
struct FloatingToolbar: View {
    @Environment(Browser.self) private var browser
    let tab: Tab?
    var leadingClearance: CGFloat
    var hoverReveal: Bool
    @Namespace private var glass

    private var collapsed: Bool {
        guard let tab else { return false }
        return tab.chromeCollapsed && !hoverReveal && !browser.modePickerPresented
            && !tab.design.isPresented && !browser.commandBar.isPresented && !browser.findBar.isPresented
    }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            if collapsed {
                CompactPill(tab: tab)
                    .glassEffectID("address", in: glass)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 8) {
                    ToolbarCircleButton(symbol: "sidebar.left", help: "Show or hide the sidebar (⌃⌘S)") {
                        withAnimation(.smooth(duration: 0.32)) {
                            browser.sidebarVisible.toggle()
                            browser.sidebarPeeking = false
                        }
                    }
                    .glassEffectID("sidebar", in: glass)

                    ToolbarCircleButton(symbol: "chevron.left", help: "Back (⌘[)") { tab?.goBack() }
                        .disabled(tab?.canGoBack != true)
                        .glassEffectID("back", in: glass)

                    if tab?.canGoForward == true {
                        ToolbarCircleButton(symbol: "chevron.right", help: "Forward (⌘])") { tab?.goForward() }
                            .glassEffectID("forward", in: glass)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }

                    AddressPill(tab: tab)
                        .glassEffectID("address", in: glass)
                }
                .padding(.leading, 10 + leadingClearance)
                .padding(.trailing, 10)
                .padding(.top, 9)
            }
        }
        .animation(.smooth(duration: 0.38, extraBounce: 0.04), value: collapsed)
        .animation(.smooth(duration: 0.25), value: tab?.canGoForward)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

struct ToolbarCircleButton: View {
    let symbol: String
    let help: String
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.5))
        .chromeGlass(in: Circle(), interactive: isEnabled)
        .help(help)
    }
}

/// The address field at rest: the mode control, the site, reload.
private struct AddressPill: View {
    @Environment(Browser.self) private var browser
    let tab: Tab?
    @State private var hovering = false

    var body: some View {
        @Bindable var browser = browser
        HStack(spacing: 0) {
            Button {
                browser.modePickerPresented.toggle()
            } label: {
                ModeGlyph(mode: tab?.mode ?? .clean, previewing: tab?.previewing != nil)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose how this site looks (⌥⌘D)")
            .disabled(!SiteKey.isWeb(tab?.url))
            .popover(isPresented: $browser.modePickerPresented, arrowEdge: .bottom) {
                if let tab { ModePicker(tab: tab) }
            }

            Button {
                browser.commandBar.opensNewTab = false
                browser.commandBar.text = tab?.url?.absoluteString ?? ""
                browser.commandBar.isPresented = true
            } label: {
                HStack(spacing: 5) {
                    if let tab, tab.url?.scheme == "http" {
                        Image(systemName: "lock.slash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                            .help("This connection is not secure")
                    }
                    Text(tab?.displayHost.isEmpty == false ? tab!.displayHost : "Search or enter address")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(tab?.displayHost.isEmpty == false ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab?.url?.absoluteString ?? "")

            Button {
                if tab?.isLoading == true { tab?.stop() } else { tab?.reload() }
            } label: {
                Image(systemName: tab?.isLoading == true ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering || tab?.isLoading == true ? 1 : 0)
            .help(tab?.isLoading == true ? "Stop (⌘.)" : "Reload (⌘R)")
        }
        .padding(.horizontal, 2)
        .overlay(alignment: .bottom) { ProgressLine(tab: tab) }
        .clipShape(Capsule())
        .chromeGlass(in: Capsule(), interactive: false)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// A hairline along the bottom of the address pill while a page loads.
private struct ProgressLine: View {
    let tab: Tab?

    var body: some View {
        GeometryReader { proxy in
            let loading = tab?.isLoading == true
            Capsule()
                .fill(Color.accentColor.gradient)
                .frame(width: max(proxy.size.width * (loading ? max(tab?.progress ?? 0, 0.08) : 1), 0), height: 2)
                .opacity(loading ? 1 : 0)
                .animation(.smooth(duration: 0.3), value: tab?.progress)
                .animation(.easeOut(duration: loading ? 0.1 : 0.6).delay(loading ? 0 : 0.15), value: loading)
        }
        .frame(height: 2)
        .padding(.horizontal, 14)
        .allowsHitTesting(false)
    }
}

/// The folded toolbar: just the site, on a small pill. Click to unfold.
private struct CompactPill: View {
    let tab: Tab?

    var body: some View {
        Button {
            tab?.chromeCollapsed = false
        } label: {
            HStack(spacing: 6) {
                ModeGlyph(mode: tab?.mode ?? .clean, previewing: false, size: 10)
                Text(tab?.displayHost ?? "")
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .chromeGlass(in: Capsule())
        .help(tab?.url?.absoluteString ?? "")
    }
}

/// The current mode's symbol. Tinted when Zentic is changing the page's look,
/// so the user can see at a glance that what they are reading is not the
/// site's own design.
struct ModeGlyph: View {
    let mode: SiteMode
    var previewing: Bool
    var size: CGFloat = 12.5

    var body: some View {
        Image(systemName: previewing ? "wand.and.sparkles" : mode == .clean ? "slider.horizontal.3" : mode.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.pulse, options: .repeating, isActive: previewing)
    }

    private var tint: AnyShapeStyle {
        switch mode {
        case _ where previewing: AnyShapeStyle(Color.purple.gradient)
        case .original: AnyShapeStyle(.secondary)
        case .clean: AnyShapeStyle(.primary)
        case .minimal: AnyShapeStyle(Color.accentColor)
        case .custom: AnyShapeStyle(Color.purple.gradient)
        }
    }
}
