import SwiftUI
import ZenticKit

/// An app in the favourites grid: its glyph, with a badge of the sites it is
/// built from. Apps live with the favourites because, like them, they belong to
/// every space.
struct AppTile: View {
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var scheme
    let app: GeneratedApp
    let active: Bool
    @State private var hovering = false

    var body: some View {
        let stale = Apps.shared.isStale(app)
        Button {
            browser.open(app)
        } label: {
            AppGlyph(app: app, size: 26)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(active ? 0.22 : 0.06), lineWidth: 1)
                }
                .overlay(alignment: .bottomTrailing) {
                    SourceBadge(origins: app.sources, stale: stale)
                        // Overhanging the corner, so it reads as attached to the
                        // tile rather than crowding the glyph inside it.
                        .offset(x: 3, y: 3)
                }
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(TilePressStyle())
        .help(help(stale: stale))
        .accessibilityLabel("\(app.name), app from \(hosts)" + (stale ? ", not updated today" : ""))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button("Open") { browser.open(app) }
            Button("Revise App…") { LibraryActions.revise(app, in: browser) }
            Button(Apps.shared.icons[app.id] == nil ? "Draw an Icon" : "Draw a New Icon") { Apps.shared.drawIcon(for: app) }
                .disabled(!AppModel.shared.hasAPIKey || Apps.shared.drawingIcons.contains(app.id))
            if app.versionCount > 1 {
                Divider()
                Text("Version \(app.currentVersion) of \(app.versionCount)")
                Button("Previous Version") { Task { await Apps.shared.showVersion(app.currentVersion - 1, of: app) } }
                    .disabled(app.currentVersion <= 1)
                Button("Newer Version") { Task { await Apps.shared.showVersion(app.currentVersion + 1, of: app) } }
                    .disabled(app.currentVersion >= app.versionCount)
            }
            Divider()
            Button("Delete App…", role: .destructive) { LibraryActions.delete(app, in: browser) }
        }
    }

    private var hosts: String {
        ListFormatter.localizedString(byJoining: app.sources.compactMap { URL(string: $0).map(URLGuess.displayHost) })
    }

    private func help(stale: Bool) -> String {
        "\(app.name)\nFrom \(hosts)" + (stale ? "\nNothing new from these sites in a day — open one to refresh." : "")
    }

    private var fill: Color {
        let dark = scheme == .dark
        if active { return .white.opacity(dark ? 0.20 : 0.85) }
        return .white.opacity(dark ? (hovering ? 0.13 : 0.08) : (hovering ? 0.6 : 0.42))
    }
}

/// The app being designed, in the grid where it will land: a quiet placeholder
/// with the time so far, or what went wrong.
struct GeneratingTile: View {
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var scheme
    let generation: Apps.Generation

    var body: some View {
        Button {
            if browser.appComposer == nil {
                browser.appComposer = AppComposerState(
                    mode: generation.revising.map { .revise(appID: $0) } ?? .create, selected: Set(generation.origins))
            }
        } label: {
            Group {
                if case .failed = generation.phase {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.orange)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(scheme == .dark ? 0.05 : 0.3))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .contextMenu {
            if generation.phase == .working {
                Button("Stop Making This App") { Apps.shared.cancelGeneration() }
            } else {
                Button("Dismiss") { Apps.shared.dismissFailure() }
            }
        }
    }

    private var help: String {
        switch generation.phase {
        case .working: generation.revising == nil ? "Designing an app…" : "Revising an app…"
        case .failed(let message): "The app couldn’t be made: \(message)"
        }
    }
}

/// Up to two source icons, overlapping, then `+n`. Faded when every source is
/// stale — state, never a count of anything (invariant 8): the badge says which
/// sites feed the app and whether they have been seen lately, both true facts
/// the user can act on.
struct SourceBadge: View {
    let origins: [String]
    let stale: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: -5) {
            ForEach(origins.prefix(2), id: \.self) { origin in
                BadgeIcon(origin: origin)
                    // Stale dims the sites, not the badge: a faded badge reads as
                    // disabled, and lets the glyph show through it.
                    .opacity(stale ? 0.45 : 1)
            }
            if origins.count > 2 {
                Text("+\(origins.count - 2)")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 7)
            }
        }
        .padding(2)
        .padding(.trailing, origins.count > 2 ? 3 : 0)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.white.opacity(scheme == .dark ? 0.12 : 0.6), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

private struct BadgeIcon: View {
    let origin: String
    @State private var icon: NSImage?

    var body: some View {
        // Rounded squares, not circles: favicons are drawn to a square, and a
        // circle crop clips their letterforms.
        SiteIcon(image: icon, size: 13)
            .task(id: origin) {
                guard let url = URL(string: origin) else { return }
                icon = Favicons.shared.cached(for: url)
                if icon == nil { icon = await Favicons.shared.icon(for: url, declared: nil) }
            }
    }
}

private struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// An app's face: the icon drawn for it, or — until there is one, or if there
/// never will be — its symbol. While an icon is being drawn the symbol pulses.
struct AppGlyph: View {
    let app: GeneratedApp
    var size: CGFloat
    @Bindable private var apps = Apps.shared

    var body: some View {
        if let icon = apps.icons[app.id] {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
        } else {
            Image(systemName: app.symbol)
                .font(.system(size: size * 0.66, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary)
                .symbolEffect(.pulse, isActive: apps.drawingIcons.contains(app.id))
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Notice

/// A short, self-dismissing note at the bottom of the window, for outcomes the
/// user would otherwise have to infer: "keeping a database of x.com", "your app
/// is ready". Never stacked: a new one replaces the one on screen.
struct Notice: Identifiable, Equatable {
    enum Action: Equatable {
        case newApp
        case openApp(String)
    }
    let id = UUID()
    var title: String
    var detail: String?
    var symbol: String = "checkmark.circle"
    var action: Action?
}

struct NoticeView: View {
    @Environment(Browser.self) private var browser
    let notice: Notice

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: notice.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor.gradient)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.system(size: 13, weight: .semibold))
                if let detail = notice.detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let action = notice.action {
                Button(title(for: action)) { perform(action) }
                    .controlSize(.small)
            }
            Button {
                browser.notice = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 520)
        .panelGlass(in: .rect(cornerRadius: 18))
        .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 8)
        .accessibilityElement(children: .contain)
        .task(id: notice.id) {
            try? await Task.sleep(for: .seconds(8))
            if browser.notice?.id == notice.id { browser.notice = nil }
        }
    }

    private func title(for action: Notice.Action) -> String {
        switch action {
        case .newApp: "New App…"
        case .openApp: "Open"
        }
    }

    private func perform(_ action: Notice.Action) {
        browser.notice = nil
        switch action {
        case .newApp: LibraryActions.newApp(in: browser)
        case .openApp(let id): if let app = Apps.shared.app(id) { browser.open(app) }
        }
    }
}
