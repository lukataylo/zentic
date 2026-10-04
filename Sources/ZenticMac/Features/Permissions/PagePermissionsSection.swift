import SwiftUI
import ZenticKit

/// The site's permissions, folded into one row of the page menu and opened
/// in place — one click from the page, without a trip to Settings.
struct PagePermissionsSection: View {
    @Environment(Browser.self) private var browser
    let tab: Tab
    /// Sticky, like a Finder disclosure triangle.
    @AppStorage("pagePermissionsExpanded", store: DataDirectory.defaults) private var expanded = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let site = tab.siteKey {
            let scope = browser.permissions
            let book = scope.book
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 11) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                            .overlay {
                                Image(systemName: "hand.raised.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.primary.opacity(0.8))
                            }
                            .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Permissions").font(.system(size: 13, weight: .semibold))
                            Text(summary(book, site: site))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(hovering ? Color.primary.opacity(0.05) : .clear)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .accessibilityLabel("Permissions")
                .accessibilityValue(summary(book, site: site))
                .accessibilityHint(expanded ? "Hides this site’s permissions" : "Shows this site’s permissions")

                if expanded {
                    VStack(spacing: 2) {
                        ForEach(SitePermission.allCases) { permission in
                            PermissionRow(
                                permission: permission,
                                decision: book.decision(permission, for: site),
                                isOwn: book.decision(permission, explicitlyFor: site) != nil
                            ) { decision in
                                scope.set(decision, permission, for: site)
                                // Auto-play is fixed when a page loads; show
                                // the change rather than promise it.
                                if permission == .autoplay { tab.reload() }
                            }
                        }
                        if scope.hasOwnDecisions(for: site) {
                            HStack {
                                Spacer()
                                Button("Reset to Defaults") { scope.forget(site) }
                                    .buttonStyle(.borderless)
                                    .font(.system(size: 12))
                            }
                            .padding(.horizontal, 10)
                            .padding(.top, 4)
                        }
                    }
                    .padding(.leading, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    /// What this site does differently from the defaults, grouped by verdict
    /// so it fits on one line: "Camera, Mic blocked · Downloads allowed".
    private func summary(_ book: PermissionBook, site: String) -> String {
        var groups: [PermissionDecision: [String]] = [:]
        var autoplay: String?
        for permission in SitePermission.allCases {
            guard let decision = book.decision(permission, explicitlyFor: site),
                decision != book.defaultDecision(for: permission)
            else { continue }
            if permission == .autoplay { autoplay = permission.label(decision) } else { groups[decision, default: []].append(permission.shortTitle) }
        }
        let parts =
            [(PermissionDecision.allow, "allowed"), (.deny, "blocked"), (.ask, "ask")].compactMap { decision, verb in
                groups[decision].map { "\($0.joined(separator: ", ")) \(verb)" }
            } + [autoplay].compactMap { $0 }
        return parts.isEmpty ? "Using your defaults" : parts.joined(separator: " · ")
    }
}

private struct PermissionRow: View {
    let permission: SitePermission
    let decision: PermissionDecision
    /// Set for this site, rather than inherited from the default.
    let isOwn: Bool
    var choose: @MainActor @Sendable (PermissionDecision) -> Void

    var body: some View {
        HStack(spacing: 10) {
            PermissionTile(permission: permission, size: 20)
            Text(permission.title)
                .font(.system(size: 12.5))
            Spacer(minLength: 6)
            Picker(permission.title, selection: Binding(get: { decision }, set: choose)) {
                ForEach(permission.choices) { Text(permission.label($0)).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .controlSize(.small)
            .opacity(isOwn ? 1 : 0.75)
            .help(isOwn ? "Set for this site" : "Your default for other websites")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}
