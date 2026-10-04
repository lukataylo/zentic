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
    var hoverReveal: Bool
    @Namespace private var glass

    private var collapsed: Bool {
        guard let tab else { return false }
        return tab.chromeCollapsed && !hoverReveal && !browser.modePickerPresented
            && !tab.design.isPresented && !browser.commandBar.isPresented && !browser.findBar.isPresented
            && !browser.editingAddress
            && tab.permissions.current == nil
            && Downloads.shared.presentedIn != browser.id
            && !Extensions.shared.prompts.contains { $0.window == browser.id }
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

                    if let tab, tab.permissions.isCapturing {
                        CaptureIndicator(permissions: tab.permissions)
                            .glassEffectID("capture", in: glass)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                    if DownloadsButton.isShown(in: browser) {
                        DownloadsButton()
                            .glassEffectID("downloads", in: glass)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                    ExtensionToolbarItems(tab: tab)
                }
                .padding(.leading, 10)
                .padding(.trailing, 10)
                .padding(.top, 9)
            }
        }
        .animation(.smooth(duration: 0.38, extraBounce: 0.04), value: collapsed)
        .animation(.smooth(duration: 0.25), value: tab?.canGoForward)
        .animation(.smooth(duration: 0.3), value: tab?.permissions.isCapturing)
        .animation(.smooth(duration: 0.3, extraBounce: 0.1), value: DownloadsButton.isShown(in: browser))
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
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    private var drifted: Bool { Rechecks.shared.drift(for: tab) != nil }

    var body: some View {
        @Bindable var browser = browser
        HStack(spacing: 0) {
            Button {
                browser.modePickerPresented.toggle()
            } label: {
                ModeGlyph(mode: tab?.mode ?? .clean, previewing: tab?.previewing != nil, drifted: drifted)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(drifted ? "This site has changed since you kept your version (⌥⌘0)" : "Choose how this site looks (⌥⌘0)")
            .accessibilityLabel("Site version")
            .accessibilityValue((tab?.mode ?? .clean).title + (drifted ? ", needs repair" : ""))
            .disabled(!SiteKey.isWeb(tab?.url))
            .anchorPreference(key: SiteControlAnchor.self, value: .bounds) { $0 }
            .popover(isPresented: $browser.modePickerPresented, arrowEdge: .bottom) {
                if let tab { ModePicker(tab: tab) }
            }

            if browser.editingAddress {
                // Edited in place: the toolbar is already open, so a panel
                // over the page would only cover what the user is looking at.
                TextField("Search or enter address", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($fieldFocused)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .onSubmit {
                        browser.go(draft, newTab: false)
                        browser.editingAddress = false
                    }
                    .onExitCommand { browser.editingAddress = false }
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused { browser.editingAddress = false }
                    }
                    .onAppear {
                        draft = tab?.url?.absoluteString ?? ""
                        fieldFocused = true
                    }
                    .accessibilityLabel("Address")
            } else {
            // The whole pill edits the address, but the badge beside the
            // site's name is a button of its own. A button inside a button's
            // label gives the click to whichever AppKit picks, so the address
            // sits over the pill's button instead, letting clicks through to
            // it everywhere except the badge.
            ZStack {
                Button {
                    browser.editAddress()
                } label: {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab?.url?.absoluteString ?? "")
                .accessibilityLabel(tab?.displayHost.isEmpty == false ? tab!.displayHost : "Search or enter address")

                HStack(spacing: 5) {
                    if let tab { ConnectionBadge(tab: tab) }
                    Group {
                        if browser.isPrivate {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color(red: 0.55, green: 0.5, blue: 1))
                                .accessibilityLabel("Private")
                        }
                        Text(tab?.displayHost.isEmpty == false ? tab!.displayHost : "Search or enter address")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(tab?.displayHost.isEmpty == false ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityHidden(true)
                    }
                    .allowsHitTesting(false)
                }
                .padding(.horizontal, 8)
            }
            }

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
    @Environment(Browser.self) private var browser
    let tab: Tab?

    var body: some View {
        // Scrolled down the page, the address is a lookup away.
        Button {
            browser.showCommandBar(newTab: false)
        } label: {
            HStack(spacing: 6) {
                ModeGlyph(mode: tab?.mode ?? .clean, previewing: false, drifted: Rechecks.shared.drift(for: tab) != nil, size: 10)
                Text(tab?.displayHost ?? "")
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                if let tab, tab.permissions.isCapturing { CaptureGlyphs(permissions: tab.permissions, size: 10) }
                DownloadsPillRing()
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
    /// The site changed under its kept version: a small amber dot, nothing louder.
    var drifted = false
    var size: CGFloat = 12.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: previewing ? "wand.and.sparkles" : mode == .clean ? "slider.horizontal.3" : mode.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.pulse, options: .repeating, isActive: previewing)
            .overlay(alignment: .topTrailing) {
                if drifted {
                    DriftDot(size: size * 0.46)
                        .offset(x: size * 0.42, y: -size * 0.32)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.2).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.6), value: drifted)
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
