import SwiftUI

/// The row of space icons at the bottom of the sidebar, Arc's pager: the
/// current space lit, the others dimmed, a "+" on hover to make another.
/// Collapses to dots when there are too many icons to fit.
struct SpaceSwitcher: View {
    @Environment(Browser.self) private var browser
    @State private var hovering = false
    @State private var deleting: Space?

    /// Beyond this many, icons become dots.
    private static let iconLimit = 6

    var body: some View {
        let compact = browser.spaces.count > Self.iconLimit
        HStack(spacing: compact ? 2 : 1) {
            ForEach(Array(browser.spaces.enumerated()), id: \.element.id) { index, space in
                SpaceButton(space: space, index: index, compact: compact, current: space === browser.space) {
                    deleting = space
                }
            }
            if hovering {
                Button {
                    browser.spaceDraft = SpaceDraft(newIn: browser)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 24, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New Space…")
                .accessibilityLabel("New Space")
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.smooth(duration: 0.2)) { hovering = inside } }
        .contextMenu {
            Button("New Space…") { browser.spaceDraft = SpaceDraft(newIn: browser) }
        }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete Space", role: .destructive) {
                if let deleting { withAnimation(.smooth(duration: 0.3)) { browser.deleteSpace(deleting) } }
            }
        } message: {
            let count = deleting?.allTabs.count ?? 0
            Text(count == 0 ? "This space has no tabs." : "Its \(count) tab\(count == 1 ? "" : "s"), pinned ones included, will be closed.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spaces")
        .accessibilityAdjustableAction { direction in
            browser.switchSpace(by: direction == .increment ? 1 : -1)
        }
    }
}

private struct SpaceButton: View {
    @Environment(Browser.self) private var browser
    let space: Space
    let index: Int
    let compact: Bool
    let current: Bool
    var requestDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            browser.switchTo(space)
        } label: {
            Group {
                if compact {
                    Circle()
                        .frame(width: current ? 7 : 5, height: current ? 7 : 5)
                } else {
                    SpaceIcon(icon: space.icon, size: 12.5)
                        .symbolEffect(.bounce, value: current)
                        .foregroundStyle(current ? AnyShapeStyle(space.tint.accent.gradient) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.6 : 0.38)))
                }
            }
            .frame(width: compact ? 14 : 26, height: 26)
            .background {
                if current && !compact {
                    Circle()
                        .fill(space.tint.accent.opacity(0.16))
                        .frame(width: 26, height: 26)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .foregroundStyle(compact && current ? AnyShapeStyle(space.tint.accent) : AnyShapeStyle(Color.primary.opacity(current ? 0.9 : hovering ? 0.6 : 0.38)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: current)
        .help(index < 9 ? "\(space.name) (⌃\(index + 1))" : space.name)
        .contextMenu {
            Button("Edit Space…") { browser.spaceDraft = SpaceDraft(editing: space) }
            Divider()
            Button("Move Left") { withAnimation(.smooth(duration: 0.25)) { browser.moveSpace(space, by: -1) } }
                .disabled(index == 0)
            Button("Move Right") { withAnimation(.smooth(duration: 0.25)) { browser.moveSpace(space, by: 1) } }
                .disabled(index == browser.spaces.count - 1)
            Divider()
            Button("New Space…") { browser.spaceDraft = SpaceDraft(newIn: browser) }
            Button("Delete Space…", role: .destructive) {
                if space.allTabs.isEmpty { withAnimation(.smooth(duration: 0.3)) { browser.deleteSpace(space) } } else { requestDelete() }
            }
            .disabled(browser.spaces.count < 2)
        }
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
    }
}
