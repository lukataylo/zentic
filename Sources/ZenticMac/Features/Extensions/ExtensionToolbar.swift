import SwiftUI
import WebKit
import ZenticKit

/// Extensions' buttons, to the right of the address: small glass circles,
/// and once there are more than three, a puzzle-piece menu for the rest.
struct ExtensionToolbarItems: View {
    @Environment(Browser.self) private var browser
    let tab: Tab?

    /// Three sit beside the address without squeezing it at the window's
    /// narrowest; past that, two stay and the rest fold into the menu.
    private let limit = 3

    var body: some View {
        let items = Extensions.shared.toolbarItems(privateWindow: browser.isPrivate)
        let folds = items.count > limit
        let shown = folds ? Array(items.prefix(limit - 1)) : items
        HStack(spacing: 8) {
            ForEach(shown) { item in
                ExtensionButton(item: item, tab: tab)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            if folds {
                ExtensionOverflow(items: Array(items.dropFirst(limit - 1)), tab: tab)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3, extraBounce: 0.08), value: items.map(\.id))
    }
}

private struct ExtensionButton: View {
    @Environment(Browser.self) private var browser
    @Environment(\.openSettings) private var openSettings
    let item: Extensions.ToolbarItem
    let tab: Tab?

    var body: some View {
        let extensions = Extensions.shared
        let _ = extensions.actionRevision
        let action = item.context.action(for: tab.map(extensions.events.tab(for:)))
        let name = item.context.webExtension.displayName ?? "Extension"
        let wantsAccess = extensions.wantsAccess(item.context, to: tab)
        let badge = action?.badgeText ?? ""

        Button {
            extensions.click(item.id, in: browser)
        } label: {
            ActionIcon(image: action?.icon(for: CGSize(width: 18, height: 18)))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .chromeGlass(in: Circle())
        .opacity(action?.isEnabled == false ? 0.45 : 1)
        .overlay(alignment: .topTrailing) {
            if !badge.isEmpty {
                Badge(text: badge, unread: action?.hasUnreadBadgeText == true)
                    .offset(x: 5, y: -3)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if wantsAccess {
                AccessDot()
                    .offset(x: 1, y: 1)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: badge)
        .animation(.smooth(duration: 0.25), value: wantsAccess)
        .background(ExtensionAnchor(item: item.id, browser: browser.id))
        .help(wantsAccess ? "\(action?.label ?? name) — wants access to this website" : action?.label ?? name)
        .accessibilityLabel(action?.label ?? name)
        .accessibilityValue(badge)
        .accessibilityHint(wantsAccess ? "Wants access to this website" : "")
        .contextMenu {
            ExtensionMenu(item: item, tab: tab, action: action) { openSettings() }
        }
        .popover(item: PromptBinding.for([item.id], in: browser), arrowEdge: .bottom) { prompt in
            ExtensionPromptView(prompt: prompt)
        }
    }
}

/// The extensions that did not fit, in a menu behind a puzzle piece. A dot
/// on the piece says one of them has news.
private struct ExtensionOverflow: View {
    @Environment(Browser.self) private var browser
    @Environment(\.openSettings) private var openSettings
    let items: [Extensions.ToolbarItem]
    let tab: Tab?

    var body: some View {
        let extensions = Extensions.shared
        let _ = extensions.actionRevision
        let tabAdapter = tab.map(extensions.events.tab(for:))
        let news = items.contains { item in
            item.context.action(for: tabAdapter)?.hasUnreadBadgeText == true || extensions.wantsAccess(item.context, to: tab)
        }
        Menu {
            ForEach(items) { item in
                let action = item.context.action(for: tabAdapter)
                let badge = action?.badgeText ?? ""
                Button {
                    extensions.click(item.id, in: browser)
                } label: {
                    Label {
                        Text(action?.label ?? item.context.webExtension.displayName ?? "Extension")
                        if !badge.isEmpty { Text(badge) }
                    } icon: {
                        Image(nsImage: action?.icon(for: CGSize(width: 16, height: 16)) ?? NSImage())
                    }
                }
                .disabled(action?.isEnabled == false)
            }
            Divider()
            Button("Manage Extensions…") { openSettings() }
        } label: {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .chromeGlass(in: Circle())
        .overlay(alignment: .topTrailing) {
            if news {
                Circle().fill(Color.accentColor).frame(width: 8, height: 8).offset(x: -1, y: 2)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: news)
        .background(ExtensionAnchor(item: ExtensionAnchors.overflow, browser: browser.id))
        .help("More extensions")
        .accessibilityLabel("More extensions")
        .popover(item: PromptBinding.for(items.map(\.id), in: browser), arrowEdge: .bottom) { prompt in
            ExtensionPromptView(prompt: prompt)
        }
    }
}

/// The right-click menu on an extension's button: what the extension adds
/// there itself, then this site, its options and turning it off.
private struct ExtensionMenu: View {
    let item: Extensions.ToolbarItem
    let tab: Tab?
    let action: WKWebExtension.Action?
    var manage: () -> Void

    var body: some View {
        let extensions = Extensions.shared
        let name = item.context.webExtension.displayName ?? "Extension"
        if let action, !action.menuItems.isEmpty {
            ForEach(Array(action.menuItems.enumerated()), id: \.offset) { _, menuItem in
                BridgedMenuItem(item: menuItem)
            }
            Divider()
        }
        if let url = tab?.url, let pattern = SitePattern.forSite(url.absoluteString),
            extensions.siteAccess(item.id) != .allSites, extensions.asksFor(site: pattern, item.id)
        {
            let host = URLGuess.displayHost(url)
            if case .whenClicked(let sites) = extensions.siteAccess(item.id), sites.contains(SitePattern.site(of: pattern) ?? "") {
                Button("Stop Allowing on \(host)") { extensions.disallow(site: SitePattern.site(of: pattern) ?? host, item.id) }
            } else {
                Button("Always Allow on \(host)") {
                    extensions.allow(site: pattern, item.id, privately: tab?.browser?.isPrivate == true)
                    if item.context.hasInjectedContent(for: url) { tab?.reload() }
                }
            }
        }
        if item.context.optionsPageURL != nil {
            Button("\(name) Options…") { extensions.openOptions(item.id) }
        }
        Button("Manage Extensions…", action: manage)
        Divider()
        Button("Turn Off \(name)") { extensions.setEnabled(false, item.id) }
    }
}

/// An `NSMenuItem` from an extension, as a SwiftUI menu entry that performs
/// the item's own action.
private struct BridgedMenuItem: View {
    let item: NSMenuItem

    var body: some View {
        if item.isSeparatorItem {
            Divider()
        } else if let submenu = item.submenu {
            Menu(item.title) {
                ForEach(Array(submenu.items.enumerated()), id: \.offset) { _, child in BridgedMenuItem(item: child) }
            }
        } else if !item.isHidden {
            Button(item.title) {
                if let selector = item.action { NSApp.sendAction(selector, to: item.target, from: item) }
            }
            .disabled(!item.isEnabled)
        }
    }
}

/// The extension's own toolbar image, or a quiet puzzle piece when it has none.
private struct ActionIcon: View {
    let image: NSImage?

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

/// An extension's badge — a count, a word. Coloured until the popup has been
/// opened (WebKit's "unread"), then a quieter grey.
private struct Badge: View {
    let text: String
    let unread: Bool

    var body: some View {
        Text(text.count > 4 ? String(text.prefix(3)) + "…" : text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .contentTransition(.numericText())
            .padding(.horizontal, 4)
            .frame(minWidth: 15, minHeight: 15)
            .background(Capsule().fill(unread ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.gray)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
            .accessibilityHidden(true)
    }
}

/// The extension would like to run on this page.
private struct AccessDot: View {
    var body: some View {
        Circle()
            .fill(Color.orange.gradient)
            .frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// Records the button's view, for a popup to point at it.
private struct ExtensionAnchor: NSViewRepresentable {
    let item: String
    let browser: UUID

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Extensions.shared.anchors.set(view, for: item, in: browser)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        Extensions.shared.anchors.set(view, for: item, in: browser)
    }
}

/// The oldest question for one of `ids` in this window, as a popover binding.
/// Closing the popover without choosing declines.
@MainActor
private enum PromptBinding {
    static func `for`(_ ids: [String], in browser: Browser) -> Binding<ExtensionPrompt?> {
        let extensions = Extensions.shared
        let current = extensions.prompts.first { ids.contains($0.extensionID) && $0.window == browser.id }
        return Binding(
            get: { current },
            set: { if $0 == nil, let current { extensions.dismiss(current) } })
    }
}

// MARK: - The question

/// What an extension is asking for, and the three answers.
struct ExtensionPromptView: View {
    let prompt: ExtensionPrompt
    @Environment(Browser.self) private var browser

    private var name: String { Extensions.shared.name(prompt.extensionID) }

    private var sites: [String] {
        prompt.asks.compactMap { if case .site(let host) = $0 { host } else { nil } }
    }

    private var permissions: [WKWebExtension.Permission] {
        prompt.asks.compactMap { if case .permission(let permission) = $0 { permission } else { nil } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ExtensionIcon(id: prompt.extensionID, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !permissions.isEmpty || sites.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(permissions, id: \.self) { permission in
                        Label(permission.summary.text, systemImage: permission.summary.symbol)
                    }
                    if sites.count > 1 {
                        ForEach(sites, id: \.self) { Label($0, systemImage: "globe") }
                    }
                }
                .font(.callout)
                .labelStyle(PromptLabelStyle())
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10, style: .continuous))
            }

            VStack(spacing: 8) {
                Button {
                    Extensions.shared.answer(prompt, .always)
                } label: {
                    Text(browser.isPrivate && !sites.isEmpty ? "Allow" : "Always Allow").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                Button {
                    Extensions.shared.answer(prompt, .oneDay)
                } label: {
                    Text("Allow for One Day").frame(maxWidth: .infinity)
                }
                Button {
                    Extensions.shared.answer(prompt, .deny)
                } label: {
                    Text(prompt.isClick ? "Not Now" : "Don’t Allow").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)
            }
            .controlSize(.large)

            if browser.isPrivate && !sites.isEmpty {
                Text("This is a private window, so Zentic forgets this answer when you quit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 320)
    }

    private var title: String {
        if !permissions.isEmpty { return "“\(name)” would like more access" }
        if sites.count == 1 { return "Allow “\(name)” on \(sites[0])?" }
        return "Allow “\(name)” on \(sites.count) websites?"
    }

    private var detail: String {
        if !permissions.isEmpty { return "It’s asking to be able to:" }
        return sites.count == 1
            ? "It will be able to read and change this website’s pages, including what you type into them."
            : "It will be able to read and change these websites’ pages, including what you type into them."
    }
}

private struct PromptLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon
                .foregroundStyle(.secondary)
                .frame(width: 18)
            configuration.title
        }
    }
}

/// An extension's icon, at any size, on a soft tile when it has none.
struct ExtensionIcon: View {
    let id: String
    var size: CGFloat = 32

    var body: some View {
        if let image = Extensions.shared.parsed[id]?.icon(for: CGSize(width: size, height: size)) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(.quaternary)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
        }
    }
}
