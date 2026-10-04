import AppKit
import SwiftUI
import ZenticKit

/// Settings › Permissions: one list per permission, the sites with a
/// decision of their own, and what every other website gets.
struct PermissionsSettings: View {
    @State private var permission: SitePermission? = .camera

    var body: some View {
        HStack(spacing: 0) {
            List(SitePermission.allCases, selection: $permission) { permission in
                Label {
                    Text(permission.title)
                } icon: {
                    PermissionTile(permission: permission, size: 20)
                }
                .tag(permission)
            }
            .listStyle(.sidebar)
            .scrollDisabled(true)
            .frame(width: 176)

            Divider()

            PermissionDetail(permission: permission ?? .camera)
                .id(permission)
        }
        .frame(height: 440)
    }
}

private struct PermissionDetail: View {
    let permission: SitePermission
    @State private var store = SitePermissionStore.shared
    @State private var search = ""
    @State private var selection: Set<String> = []

    private var sites: [(site: String, decision: PermissionDecision)] {
        let all = store.book.sites(for: permission)
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty ? all : all.filter { $0.site.contains(query) }
    }

    var body: some View {
        let all = store.book.sites(for: permission)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                PermissionTile(permission: permission, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(permission.title).font(.title3.weight(.semibold))
                    Text(permission.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if all.isEmpty {
                ContentUnavailableView {
                    Label("No Websites Yet", systemImage: permission.symbol)
                } description: {
                    Text("When you answer a website, or change it from the page menu, it appears here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
            } else {
                SearchField(text: $search, prompt: "Search \(all.count) website\(all.count == 1 ? "" : "s")")
                List(selection: $selection) {
                    ForEach(sites, id: \.site) { entry in
                        SiteDecisionRow(permission: permission, site: entry.site, decision: entry.decision) {
                            store.set($0, permission, for: entry.site)
                        }
                        .tag(entry.site)
                        .contextMenu {
                            Button("Remove", role: .destructive) { remove([entry.site]) }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .onDeleteCommand { remove(selection) }
                .overlay {
                    if sites.isEmpty {
                        ContentUnavailableView.search(text: search)
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Remove") { remove(selection) }
                    .disabled(selection.isEmpty)
                    .help("Forget the selected websites’ decisions; they get the default again")
                Spacer()
                Text("Other websites")
                    .foregroundStyle(.secondary)
                Picker(
                    "Other websites",
                    selection: Binding(
                        get: { store.book.defaultDecision(for: permission) },
                        set: { store.setDefault($0, for: permission) })
                ) {
                    ForEach(permission.choices) { Text(permission.label($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(16)
    }

    private func remove(_ sites: Set<String>) {
        for site in sites { store.set(nil, permission, for: site) }
        selection.subtract(sites)
    }
}

private struct SiteDecisionRow: View {
    let permission: SitePermission
    let site: String
    let decision: PermissionDecision
    var choose: @MainActor @Sendable (PermissionDecision) -> Void

    var body: some View {
        HStack(spacing: 10) {
            SiteIcon(image: Favicons.shared.cached(for: URL(string: "https://\(site)")), size: 16)
            Text(site)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Picker(site, selection: Binding(get: { decision }, set: choose)) {
                ForEach(permission.choices) { Text(permission.label($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// AppKit's search field: the magnifier, the clear button and Escape to
/// clear, which a plain text field has none of.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.controlSize = .regular
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = prompt
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
