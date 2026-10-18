import SwiftUI
import UniformTypeIdentifiers
import ZenticKit

/// Favourites, then the current space's pinned and open tabs, on the tinted
/// window frame — Arc's arrangement. Spaces page sideways beneath the
/// favourites, which belong to every space.
struct Sidebar: View {
    @Environment(Browser.self) private var browser
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // The traffic lights sit here. The strip moves the window, as a
            // titlebar would.
            WindowDragArea()
                .frame(height: 40)
                .overlay(alignment: .trailing) {
                    if browser.isPrivate {
                        PrivateBadge().padding(.trailing, 12)
                    }
                }

            if !app.favorites.isEmpty || !Apps.shared.apps.isEmpty || Apps.shared.generation != nil {
                FavoritesGrid()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }

            SpacePages()

            SidebarFooter()
        }
        .animation(
            reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.88),
            value: browser.spaceID
        )
        .background {
            if browser.spaces.count > 1 {
                SpaceSwipeArea { direction in browser.switchSpace(by: direction == .next ? 1 : -1) }
            }
        }
    }
}

// MARK: - Spaces

/// Every space side by side, slid so the current one shows: switching moves
/// the list the way the swipe went, and each space keeps its own scroll
/// position. With Reduce Motion, a crossfade instead.
private struct SpacePages: View {
    @Environment(Browser.self) private var browser
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion || browser.spaces.count == 1 {
            SpacePage(space: browser.space)
                .id(browser.spaceID)
                .transition(.opacity)
        } else {
            let width = browser.sidebarWidth
            let index = browser.spaces.firstIndex { $0 === browser.space } ?? 0
            HStack(alignment: .top, spacing: 0) {
                ForEach(browser.spaces) { space in
                    let current = space === browser.space
                    SpacePage(space: space)
                        .frame(width: width)
                        .opacity(current ? 1 : 0)
                        .allowsHitTesting(current)
                        .accessibilityHidden(!current)
                }
            }
            .offset(x: -CGFloat(index) * width)
            .frame(width: width, alignment: .leading)
            .clipped()
        }
    }
}

private struct SpacePage: View {
    @Environment(Browser.self) private var browser
    let space: Space
    @State private var dragging: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if !browser.isPrivate {
                SpaceHeader(space: space, dragging: $dragging)
            } else {
                Spacer().frame(height: 6)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(space.pinned) { tab in
                        row(tab)
                    }
                    if !space.pinned.isEmpty {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 6)
                    }
                    NewTabRow()
                    ForEach(space.tabs) { tab in
                        row(tab)
                    }
                    if space.allTabs.isEmpty && !browser.isPrivate {
                        EmptySpaceHint(space: space)
                    }
                    // The visible space only: every space's page is laid out side by side.
                    if !browser.isPrivate && space === browser.space {
                        OtherDevicesSection()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .animation(.smooth(duration: 0.25), value: space.allTabs.map(\.id))
            }
            .scrollIndicators(.never)
            .onDrop(of: [.text], isTargeted: nil) { _ in
                dragging = nil
                return true
            }
        }
    }

    private func row(_ tab: Tab) -> some View {
        TabRow(tab: tab, selected: tab.id == space.selectedID)
            .opacity(dragging == tab.id ? 0.35 : 1)
            .onDrag {
                dragging = tab.id
                return NSItemProvider(object: tab.id.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: TabDropDelegate(target: tab.id, browser: browser, dragging: $dragging))
    }
}

/// The space's name above its tabs. Drop a tab here to pin it.
private struct SpaceHeader: View {
    @Environment(Browser.self) private var browser
    let space: Space
    @Binding var dragging: UUID?
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 7) {
            SpaceIcon(icon: space.icon, size: 11)
                .foregroundStyle(space.tint.accent.gradient)
            Text(space.name)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Rectangle()
                .fill(Color.primary.opacity(targeted ? 0.3 : 0.08))
                .frame(height: 1)
            if hovering {
                Button {
                    browser.spaceDraft = SpaceDraft(editing: space)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Edit Space…")
                .transition(.opacity)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .frame(height: 28)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .onTapGesture(count: 2) { browser.spaceDraft = SpaceDraft(editing: space) }
        .contextMenu {
            Button("Edit Space…") { browser.spaceDraft = SpaceDraft(editing: space) }
            Button("New Space…") { browser.spaceDraft = SpaceDraft(newIn: browser) }
        }
        .onDrop(of: [.text], isTargeted: $targeted) { _ in
            if let dragging { withAnimation(.smooth(duration: 0.25)) { browser.pinByDrop(dragging) } }
            dragging = nil
            return true
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A space with nothing in it yet.
private struct EmptySpaceHint: View {
    let space: Space

    var body: some View {
        VStack(spacing: 6) {
            SpaceIcon(icon: space.icon, size: 22)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text("Nothing open in \(space.name)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Open a tab with ⌘T, or drag one here to pin it.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The private window's mark in the sidebar's title strip.
private struct PrivateBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 10, weight: .semibold))
            Text("Private")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(.white.opacity(0.1)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .help("Nothing from this window is saved: no history, no tabs, no cookies once it closes.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Private window")
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
            // Apps after the favourites: places of the user's own making.
            ForEach(Apps.shared.apps) { made in
                AppTile(app: made, active: browser.selectedTab?.appID == made.id)
            }
            if let generation = Apps.shared.generation, generation.revising == nil {
                GeneratingTile(generation: generation)
            }
        }
        .onDrop(of: [.text], isTargeted: nil) { providers in
            // Drop a tab onto the grid to make it a favourite.
            _ = providers.first?.loadObject(ofClass: NSString.self) { object, _ in
                guard let string = object as? String, let id = UUID(uuidString: string) else { return }
                Task { @MainActor in
                    guard let tab = browser.allTabs.first(where: { $0.id == id }), let url = tab.url else { return }
                    app.addFavorite(url: url, title: tab.title, from: browser)
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
        .accessibilityLabel(favorite.title)
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
            browser.showCommandBar(newTab: true)
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
    @State private var confirmingRemove = false

    /// A pinned tab with no page loaded is asleep; it is drawn quieter.
    private var asleep: Bool { tab.isPinned && !tab.isRealized && !selected }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if let made = Apps.shared.app(tab.appID) {
                    AppGlyph(app: made, size: 16)
                } else if tab.isLoading && tab.icon == nil {
                    ProgressView().controlSize(.mini)
                } else {
                    SiteIcon(image: tab.icon, size: 16)
                        .opacity(tab.isLoading ? 0.55 : 1)
                }
            }
            .frame(width: 16, height: 16)
            .saturation(asleep ? 0.4 : 1)

            Text(title)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Color.primary.opacity(selected ? 1 : asleep ? 0.6 : 0.88))

            Spacer(minLength: 4)

            TabPermissionBadge(permissions: tab.permissions)

            if tab.mode == .custom || tab.mode == .minimal, !hovering {
                Image(systemName: tab.mode.symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help(tab.mode.title)
            }

            if hovering && (!tab.isPinned || !asleep) {
                Button {
                    withAnimation(.smooth(duration: 0.25)) { browser.close(tab) }
                } label: {
                    // A pinned tab is not closed but put to sleep: a minus, as Arc.
                    Image(systemName: tab.isPinned ? "minus" : "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(0.0001)))
                        .contentShape(Circle())
                }
                .buttonStyle(CloseButtonStyle())
                .help(tab.isPinned ? "Unload Pinned Tab (⌘W) — it stays pinned" : "Close Tab (⌘W)")
                .accessibilityLabel(tab.isPinned ? "Unload pinned tab" : "Close tab")
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
        .contextMenu { menu }
        .confirmationDialog("Remove “\(title)” from pinned tabs?", isPresented: $confirmingRemove) {
            Button("Remove Pinned Tab", role: .destructive) {
                withAnimation(.smooth(duration: 0.25)) {
                    browser.unpin(tab)
                    browser.close(tab)
                }
            }
        } message: {
            Text("It will be closed. You can pin a page again from its tab’s menu.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.isPinned ? "\(title), pinned" : title)
        .accessibilityIdentifier("sidebar.tab")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: tab.isPinned ? "Unload" : "Close") { browser.close(tab) }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Copy Link") { if let url = tab.url { copy(url) } }
            .disabled(tab.url == nil)
        Button("Duplicate") { browser.duplicate(tab) }
        Button(app.isFavorite(tab.url) ? "Remove from Favorites" : "Add to Favorites") {
            if let existing = app.favorites.first(where: { SiteKey.for($0.url) == tab.siteKey }) {
                app.removeFavorite(existing.id)
            } else if let url = tab.url {
                app.addFavorite(url: url, title: tab.title, from: browser)
            }
        }
        .disabled(!SiteKey.isWeb(tab.url) || browser.isPrivate)
        Divider()
        if !browser.isPrivate {
            if tab.isPinned {
                Button("Unpin Tab") { withAnimation(.smooth(duration: 0.25)) { browser.unpin(tab) } }
                if let pinnedURL = tab.pinnedURL, tab.url != pinnedURL {
                    Button("Go Back to Pinned Page") { tab.load(pinnedURL) }
                    Button("Pin This Page Instead") {
                        tab.pinnedURL = tab.url
                        browser.tabDidChange(tab)
                    }
                }
            } else {
                Button("Pin Tab") { withAnimation(.smooth(duration: 0.25)) { browser.pin(tab) } }
            }
        }
        if browser.spaces.count > 1 {
            Menu("Move to Space") {
                ForEach(browser.spaces.filter { !$0.contains(tab) }) { space in
                    Button {
                        withAnimation(.smooth(duration: 0.25)) { browser.move(tab, to: space) }
                    } label: {
                        Label { Text(space.name) } icon: { SpaceIcon(icon: space.icon) }
                    }
                }
            }
        }
        Button("Move to New Window") { browser.moveToNewWindow(tab) }
            .disabled(browser.allTabs.count == 1)
        ExtensionTabMenuItems(tab: tab)
        Divider()
        if tab.isPinned {
            Button("Unload Pinned Tab") { browser.close(tab) }
            Button("Remove Pinned Tab…") { confirmingRemove = true }
        } else {
            Button("Close Tab") { browser.close(tab) }
            Button("Close Tabs Below") { browser.closeBelow(tab) }
            Button("Close Other Tabs") { browser.closeOthers(than: tab) }
        }
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
        withAnimation(.smooth(duration: 0.22)) { browser.move(dragging, onto: target) }
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
        HStack(spacing: 6) {
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")

            if browser.isPrivate {
                Spacer()
            } else {
                SpaceSwitcher()
            }

            Button {
                browser.showCommandBar(newTab: true)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help("New Tab (⌘T)")
            .accessibilityLabel("New Tab")
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
