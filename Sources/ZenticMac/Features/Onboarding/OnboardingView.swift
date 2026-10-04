import AppKit
import SwiftUI
import ZenticKit

/// Three or four short pages: what Zentic is, the four versions of a site,
/// making it the default browser, and (optionally) a key for Custom.
struct OnboardingView: View {
    var done: () -> Void

    enum Page: CaseIterable {
        case welcome, modes, defaultBrowser, custom

        /// The wash of colour behind each page.
        var tint: Color {
            switch self {
            case .welcome: .indigo
            case .modes: .accentColor
            case .defaultBrowser: .teal
            case .custom: .purple
            }
        }
    }

    /// Without an app bundle there is no default to become, and a page whose
    /// only button cannot work is left out rather than shown dead.
    private let pages: [Page] = Page.allCases.filter {
        $0 != .defaultBrowser || DefaultBrowser.shared.status != .unavailable
    }
    @State private var index = 0
    @State private var forward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var page: Page { pages[index] }
    private var isLast: Bool { index == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                content(for: page)
                    .id(page)
                    .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44)
            .padding(.top, 36)

            footer
        }
        .frame(width: 620, height: 540)
        .background(alignment: .top) {
            // A soft glow of the page's colour from above; crossfades as the
            // pages change.
            RadialGradient(colors: [page.tint.opacity(0.22), .clear], center: .top, startRadius: 0, endRadius: 420)
                .frame(height: 420)
                .id(page)
                .transition(.opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onExitCommand(perform: done)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            DefaultBrowser.shared.refresh()
        }
    }

    @ViewBuilder
    private func content(for page: Page) -> some View {
        switch page {
        case .welcome: WelcomePage()
        case .modes: ModesPage()
        case .defaultBrowser: DefaultBrowserPage()
        case .custom: CustomPage()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            PageDots(count: pages.count, current: index)
            Spacer()
            if index > 0 {
                Button("Back") { go(by: -1) }
                    .controlSize(.large)
                    .transition(.opacity)
            }
            Button(isLast ? "Start Browsing" : "Continue") {
                isLast ? done() : go(by: 1)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .animation(.smooth(duration: 0.2), value: index)
    }

    private func go(by step: Int) {
        // Direction first, on its own: the page leaving takes its transition
        // from its last render, so it must already know which way to go.
        forward = step > 0
        Task { @MainActor in
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.48, dampingFraction: 0.84)) {
                index = min(max(index + step, 0), pages.count - 1)
            }
        }
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let shift: CGFloat = 56
        return .asymmetric(
            insertion: .offset(x: forward ? shift : -shift).combined(with: .opacity),
            removal: .offset(x: forward ? -shift : shift).combined(with: .opacity))
    }
}

// MARK: - Pages

/// The shared shape of a page: a hero, a title, a sentence, then whatever
/// the page asks of the user.
private struct PageLayout<Hero: View, Body: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var hero: Hero
    @ViewBuilder var content: Body

    var body: some View {
        VStack(spacing: 0) {
            // One height for every hero, so the titles do not jump between pages.
            hero
                .frame(height: 112)
                .accessibilityHidden(true)
                .padding(.bottom, 16)
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 8)
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
            content
                .padding(.top, 26)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// A rounded tile of colour with a white symbol, which plays its effect once
/// as the page arrives.
private struct HeroSymbol: View {
    let symbol: String
    let colors: [Color]
    @State private var arrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                .symbolEffect(.bounce.up.byLayer, options: .nonRepeating, value: arrived)
        }
        .frame(width: 84, height: 84)
        .shadow(color: colors[0].opacity(0.4), radius: 16, y: 8)
        .task {
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(260))
            arrived = true
        }
    }
}

private struct WelcomePage: View {
    @State private var arrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PageLayout(
            title: "Welcome to Zentic",
            subtitle: "The clean version of every page is the page you land on."
        ) {
            icon
                .scaleEffect(arrived || reduceMotion ? 1 : 0.86)
                .opacity(arrived || reduceMotion ? 1 : 0)
                .onAppear {
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.62).delay(0.08)) { arrived = true }
                }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                Point(symbol: "shield.lefthalf.filled", tint: .blue,
                      text: "Ads, trackers and cookie walls gone before the page appears.")
                Point(symbol: "square.stack.3d.up", tint: .indigo,
                      text: "Every site remembered in the version you like best.")
                Point(symbol: "lock", tint: .green,
                      text: "No account, no telemetry, nothing sent without asking.")
            }
            .frame(maxWidth: 460)
        }
    }

    /// The app's own icon when running as Zentic.app; `swift run` has none.
    @ViewBuilder private var icon: some View {
        if Bundle.main.bundleURL.pathExtension == "app", let image = NSApp.applicationIconImage {
            Image(nsImage: image)
                .resizable()
                .frame(width: 112, height: 112)
                .shadow(color: .indigo.opacity(0.25), radius: 18, y: 8)
        } else {
            HeroSymbol(symbol: "circle.lefthalf.filled", colors: [.indigo, Color(red: 0.24, green: 0.2, blue: 0.62)])
        }
    }

    private struct Point: View {
        let symbol: String
        let tint: Color
        let text: String

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint.gradient)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ModesPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        PageLayout(
            title: "Every site, your way",
            subtitle: "Each site keeps the version you choose. Pick one for sites you haven’t visited yet."
        ) {
            HeroSymbol(symbol: "circle.lefthalf.filled", colors: [Color(red: 0.25, green: 0.52, blue: 1), .indigo])
        } content: {
            VStack(spacing: 12) {
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        card(.original)
                        card(.clean)
                    }
                    GridRow {
                        card(.minimal)
                        card(.custom)
                    }
                }
                Text("Change any site later from the control beside the address bar, or with ⌥⌘1 to ⌥⌘4.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 520)
        }
    }

    private func card(_ mode: SiteMode) -> some View {
        // Custom is a site's own design, written on request; it cannot be the
        // version for sites that have none yet.
        ModeCard(mode: mode, selected: app.defaultMode == mode, selectable: mode != .custom) {
            withAnimation(.smooth(duration: 0.22)) { app.defaultMode = mode }
        }
    }
}

private struct ModeCard: View {
    let mode: SiteMode
    let selected: Bool
    let selectable: Bool
    var choose: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button(action: choose) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(0.07)))
                    Image(systemName: mode.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.8))
                        .symbolEffect(.bounce, options: .nonRepeating, value: selected)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(mode.title)
                            .font(.system(size: 13.5, weight: .semibold))
                        if !selectable {
                            Text("Per site")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                        }
                    }
                    Text(mode.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white, Color.accentColor)
                    .opacity(selected ? 1 : 0)
                    .scaleEffect(selected ? 1 : 0.5)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
            .background {
                shape.fill(
                    selected ? Color.accentColor.opacity(0.12)
                        : Color.primary.opacity(hovering && selectable ? 0.07 : 0.04))
            }
            .overlay {
                shape.strokeBorder(
                    selected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08),
                    lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel("\(mode.title): \(mode.subtitle)")
        .accessibilityHint(selectable ? "Opens new sites in \(mode.title)" : "Designed for one site at a time, with Design Your Version")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct DefaultBrowserPage: View {
    @State private var celebrate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let model = DefaultBrowser.shared
        let isDefault = model.status == .isDefault
        PageLayout(
            title: "Make Zentic your browser",
            subtitle: "Links you open from Mail, Messages and every other app will open here, already clean."
        ) {
            HeroSymbol(
                symbol: isDefault ? "checkmark" : "link",
                colors: [Color(red: 0.16, green: 0.72, blue: 0.70), Color(red: 0.10, green: 0.45, blue: 0.70)]
            )
            .contentTransition(.symbolEffect(.replace))
        } content: {
            VStack(spacing: 12) {
                if isDefault {
                    Label {
                        Text("Zentic is your default browser")
                            .font(.headline)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, .green)
                            .symbolEffect(.bounce, options: .nonRepeating, value: celebrate)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.green.opacity(0.12)))
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                    .onAppear { if !reduceMotion { celebrate = true } }
                } else {
                    Button {
                        Task { await model.makeDefault() }
                    } label: {
                        Label(model.isAsking ? "Waiting for macOS…" : "Make Default Browser", systemImage: "arrow.up.forward.app")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.extraLarge)
                    .disabled(model.isAsking)
                    .transition(.opacity)
                    Text("macOS will ask you to confirm. You can change it any time in System Settings › Desktop & Dock.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
            }
            .animation(reduceMotion ? .default : .spring(response: 0.45, dampingFraction: 0.7), value: isDefault)
        }
        .onAppear { model.refresh() }
    }
}

private struct CustomPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        PageLayout(
            title: "Design your own version",
            subtitle: "Say what you want — “hide the comments, set it in a serif” — and that site stays that way. Optional."
        ) {
            HeroSymbol(
                symbol: "wand.and.sparkles",
                colors: [Color(red: 0.62, green: 0.36, blue: 0.95), Color(red: 0.90, green: 0.36, blue: 0.62)])
        } content: {
            Group {
                if app.hasAPIKey {
                    Label {
                        Text("Your OpenAI key is saved")
                            .font(.headline)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, .green)
                    }
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        KeyEntry()
                        Text("No key? Skip this — you can add one later in Settings › Intelligence.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .frame(width: 440)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                            .strokeBorder(Color.primary.opacity(0.08))
                    }
                    .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.75), value: app.hasAPIKey)
        }
    }
}

/// Where you are in the tour: the current page a longer capsule.
private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.2)))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: current)
        .accessibilityElement()
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}
