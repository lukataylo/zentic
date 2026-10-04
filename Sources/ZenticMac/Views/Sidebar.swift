import SwiftUI
import UniformTypeIdentifiers
import ZenticKit

/// Favourites, then tabs, on the tinted window frame — Arc's arrangement.
struct Sidebar: View {
    @Environment(Browser.self) private var browser
    @Environment(AppModel.self) private var app
    @State private var dragging: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // The traffic lights sit here. The strip moves the window, as a
            // titlebar would.
            WindowDragArea()
                .frame(height: 40)

            if !app.favorites.isEmpty {
                FavoritesGrid()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 2) {
                    NewTabRow()
                    ForEach(browser.tabs) { tab in
                        TabRow(tab: tab, selected: tab.id == browser.selectedID)
                            .opacity(dragging == tab.id ? 0.35 : 1)
                            .onDrag {
                                dragging = tab.id
                                return NSItemProvider(object: tab.id.uuidString as NSString)
                            }
                            .onDrop(
                                of: [.text],
                                delegate: TabDropDelegate(target: tab.id, browser: browser, dragging: $dragging))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .animation(.smooth(duration: 0.25), value: browser.tabs.map(\.id))
            }
            .scrollIndicators(.never)
            .onDrop(of: [.text], isTargeted: nil) { _ in
                dragging = nil
                return true
            }

            SidebarFooter()
        }
    }
}

// MARK: - Favourites

private struct FavoritesGrid: View {
    @Environment(Browser.self) private var browser
    @Environment(AppModel.self) private var app

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 52, maximum: 120), spacing: 8)]
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(app.favorites) { favorite in
                FavoriteTile(favorite: favorite, active: browser.selectedTab?.siteKey == SiteKey.for(favorite.url))
            }
        }
        .onDrop(of: [.text], isTargeted: nil) { providers in
            // Drop a tab onto the grid to make it a favourite.
            _ = providers.first?.loadObject(ofClass: NSString.self) { object, _ in
                guard let string = object as? String, let id = UUID(uuidString: string) else { return }
                Task { @MainActor in
                    guard let tab = browser.tabs.first(where: { $0.id == id }), let url = tab.url else { return }
                    app.addFavorite(url: url, title: tab.title)
                }
            }
            return true
        }
    }
}

private struct FavoriteTile: View {
    @Environment(Browser.self) private var browser
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let favorite: Favorite
    let active: Bool
    @State private var hovering = false
    @State private var icon: NSImage?

    var body: some View {
        Button {
            browser.open(favorite)
        } label: {
            SiteIcon(image: icon, size: 20)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(fill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(active ? 0.22 : 0.06), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .help(favorite.title)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button("Open in New Tab") { browser.openTab(favorite.url) }
            Button("Copy Link") { copy(favorite.url) }
            Divider()
            Button("Remove from Favorites", role: .destructive) { app.removeFavorite(favorite.id) }
        }
        .task(id: favorite.url) {
            icon = Favicons.shared.cached(for: favorite.url)
            if icon == nil { icon = await Favicons.shared.icon(for: favorite.url, declared: nil) }
        }
    }

    private var fill: Color {
        let dark = scheme == .dark
        if active { return .white.opacity(dark ? 0.20 : 0.85) }
        return .white.opacity(dark ? (hovering ? 0.13 : 0.08) : (hovering ? 0.6 : 0.42))
    }
}

// MARK: - Tabs

private struct NewTabRow: View {
    @Environment(Browser.self) private var browser
    @State private var hovering = false

    var body: some View {
        Button {
            browser.commandBar.opensNewTab = true
            browser.commandBar.text = ""
            browser.commandBar.isPresented = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 16)
                Text("New Tab")
                    .font(.system(size: 13))
                Spacer()
                Text("⌘T")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct TabRow: View {
    @Environment(Browser.self) private var browser
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let tab: Tab
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if tab.isLoading && tab.icon == nil {
                    ProgressView().controlSize(.mini)
                } else {
                    SiteIcon(image: tab.icon, size: 16)
                        .opacity(tab.isLoading ? 0.55 : 1)
                }
            }
            .frame(width: 16, height: 16)

            Text(title)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Color.primary.opacity(selected ? 1 : 0.88))

            Spacer(minLength: 4)

            if tab.mode == .custom || tab.mode == .minimal, !hovering {
                Image(systemName: tab.mode.symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help(tab.mode.title)
            }

            if hovering {
                Button {
                    browser.close(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(0.0001)))
                        .contentShape(Circle())
                }
                .buttonStyle(CloseButtonStyle())
                .help("Close Tab (⌘W)")
                .transition(.opacity)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .frame(height: 34)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(scheme == .dark ? 0.15 : 0.82))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(scheme == .dark ? 0.14 : 0.5), lineWidth: 0.75)
                    }
                    .shadow(color: .black.opacity(scheme == .dark ? 0.2 : 0.06), radius: 3, x: 0, y: 1)
            } else if hovering {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { browser.select(tab) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(tab.url?.absoluteString ?? title)
        .contextMenu {
            Button("Copy Link") { if let url = tab.url { copy(url) } }
                .disabled(tab.url == nil)
            Button("Duplicate") { browser.duplicate(tab) }
            Button(app.isFavorite(tab.url) ? "Remove from Favorites" : "Add to Favorites") {
                if let existing = app.favorites.first(where: { SiteKey.for($0.url) == tab.siteKey }) {
                    app.removeFavorite(existing.id)
                } else if let url = tab.url {
                    app.addFavorite(url: url, title: tab.title)
                }
            }
            .disabled(!SiteKey.isWeb(tab.url))
            Divider()
            Button("Close Tab") { browser.close(tab) }
            Button("Close Tabs Below") { browser.closeBelow(tab) }
            Button("Close Other Tabs") { browser.closeOthers(than: tab) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private var title: String {
        if !tab.title.isEmpty { return tab.title }
        if !tab.displayHost.isEmpty { return tab.displayHost }
        return "New Tab"
    }
}

private struct TabDropDelegate: DropDelegate {
    let target: UUID
    let browser: Browser
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.smooth(duration: 0.22)) {
            let from = browser.tabs.firstIndex { $0.id == dragging } ?? 0
            let to = browser.tabs.firstIndex { $0.id == target } ?? 0
            // Moving down lands after the target; moving up lands before it.
            if from < to {
                let after = browser.tabs.indices.contains(to + 1) ? browser.tabs[to + 1].id : nil
                browser.move(dragging, before: after)
            } else {
                browser.move(dragging, before: target)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

// MARK: - Footer

private struct SidebarFooter: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        HStack(spacing: 8) {
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help("Settings (⌘,)")

            Spacer()

            Button {
                browser.commandBar.opensNewTab = true
                browser.commandBar.text = ""
                browser.commandBar.isPresented = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help("New Tab (⌘T)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Styles

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct CloseButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.09 : 0)))
            .onHover { hovering = $0 }
    }
}

func copy(_ url: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([url as NSURL])
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
}
