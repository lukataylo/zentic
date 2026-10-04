import SwiftUI
import ZenticKit

/// The user's other Macs and what each has open, below the space's own tabs.
/// Not there at all without anything to show — no iCloud, sync off, or no
/// other Mac with tabs open — so it never sits empty in the sidebar.
struct OtherDevicesSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("otherDevicesCollapsed", store: DataDirectory.defaults) private var collapsed = false
    /// Macs folded away, by id; kept here rather than in each row so switching
    /// spaces (which rebuilds the section) does not unfold them.
    @AppStorage("otherDevicesFolded", store: DataDirectory.defaults) private var foldedIDs = ""
    private var sync: TabSync { .shared }

    var body: some View {
        if !sync.devices.isEmpty {
            VStack(spacing: 2) {
                header
                if !collapsed {
                    ForEach(sync.devices) { device in
                        DeviceGroup(device: device, expanded: expandedBinding(for: device.id))
                    }
                    .transition(reveal)
                }
            }
            .padding(.top, 14)
            .transition(.opacity)
        }
    }

    private var header: some View {
        Button {
            withAnimation(animation) { collapsed.toggle() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "icloud")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("Other Devices")
                    .font(.system(size: 11.5, weight: .semibold))
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show tabs from your other Macs" : "Hide tabs from your other Macs")
        .accessibilityLabel("Other Devices")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(.isHeader)
    }

    private func expandedBinding(for id: String) -> Binding<Bool> {
        Binding {
            !foldedIDs.split(separator: "\n").contains(Substring(id))
        } set: { expanded in
            var ids = foldedIDs.split(separator: "\n").map(String.init).filter { $0 != id }
            // Only Macs still listed, so ids of long-gone ones do not pile up.
            ids = ids.filter { folded in sync.devices.contains { $0.id == folded } }
            if !expanded { ids.append(id) }
            foldedIDs = ids.joined(separator: "\n")
        }
    }

    private var animation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.86)
    }

    private var reveal: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }
}

/// One Mac: its name, then its tabs, a few at first.
private struct DeviceGroup: View {
    @Environment(Browser.self) private var browser
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let device: SyncedDevice
    @Binding var expanded: Bool
    @State private var showsAll = false
    @State private var hovering = false

    /// Enough to recognise what is open there without the list swallowing
    /// the sidebar.
    private static let preview = 6

    var body: some View {
        VStack(spacing: 1) {
            deviceRow
            if expanded {
                VStack(spacing: 1) {
                    ForEach(Array(visibleSpaces.enumerated()), id: \.offset) { _, space in
                        if device.spaces.count > 1 {
                            SpaceCaption(space: space)
                        }
                        ForEach(space.pinned, id: \.url) { tab in
                            SyncedTabRow(tab: tab, pinned: true)
                        }
                        ForEach(space.tabs, id: \.url) { tab in
                            SyncedTabRow(tab: tab, pinned: false)
                        }
                    }
                    if hiddenCount > 0 {
                        Button {
                            withAnimation(.smooth(duration: 0.25)) { showsAll = true }
                        } label: {
                            Text("Show \(hiddenCount) More")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 36)
                                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .contextMenu { menu }
    }

    private var deviceRow: some View {
        Button {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.86)) {
                expanded.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: device.kind.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.bounce, options: .nonRepeating, value: freshness)
                    .frame(width: 16)
                Text(device.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(device.modified, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(Text("\(device.name) — ^[\(device.tabCount) tab](inflect: true)"))
        .accessibilityLabel(Text("\(device.name), ^[\(device.tabCount) tab](inflect: true)"))
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows or hides the tabs open on this Mac")
    }

    @ViewBuilder
    private var menu: some View {
        Button("Open All in New Space") { browser.openAll(from: device) }
            .disabled(browser.isPrivate)
        Divider()
        Button(expanded ? "Collapse" : "Expand") { expanded.toggle() }
    }

    /// The spaces, pinned tabs first in each, cut to the preview until
    /// "Show More".
    private var visibleSpaces: [SyncedDevice.Space] {
        var budget = showsAll ? Int.max : Self.preview
        return device.spaces.compactMap { space in
            guard budget > 0 else { return nil }
            let pinned = Array(space.pinned.prefix(budget))
            let tabs = Array(space.tabs.prefix(budget - pinned.count))
            budget -= pinned.count + tabs.count
            return SyncedDevice.Space(name: space.name, icon: space.icon, pinned: pinned, tabs: tabs)
        }
    }

    /// Bounces the Mac's icon when its tabs arrive anew; still with Reduce Motion.
    private var freshness: Date? { reduceMotion ? nil : device.modified }

    private var hiddenCount: Int { showsAll ? 0 : max(device.tabCount - Self.preview, 0) }
}

/// The space a group of tabs is in on the other Mac, when it has several.
private struct SpaceCaption: View {
    let space: SyncedDevice.Space

    var body: some View {
        HStack(spacing: 5) {
            SpaceIcon(icon: space.icon, size: 9)
            Text(space.name)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.tertiary)
        .padding(.leading, 36)
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct SyncedTabRow: View {
    @Environment(Browser.self) private var browser
    let tab: SyncedDevice.Tab
    let pinned: Bool
    @State private var hovering = false
    @State private var icon: NSImage?

    var body: some View {
        Button {
            browser.open(tab)
        } label: {
            HStack(spacing: 9) {
                SiteIcon(image: icon, size: 14)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.primary.opacity(hovering ? 0.95 : 0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(35))
                        .help("Pinned on that Mac")
                }
            }
            .padding(.leading, 36)
            .padding(.trailing, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(tab.url.absoluteString)
        // Only an icon already on this Mac: asking each site for one would
        // tell it about a visit made somewhere else.
        .task(id: tab.url) { icon = Favicons.shared.cached(for: tab.url) }
        .contextMenu {
            Button("Open") { browser.open(tab) }
            Divider()
            Button("Copy Link") { copy(tab.url) }
        }
        .accessibilityLabel(pinned ? "\(title), pinned" : title)
        .accessibilityHint("Opens in a tab on this Mac")
    }

    private var title: String { tab.title.isEmpty ? URLGuess.displayHost(tab.url) : tab.title }
}
