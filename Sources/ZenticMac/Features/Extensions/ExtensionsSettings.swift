import AppKit
import SwiftUI
import WebKit
import ZenticKit

/// Settings › Extensions: every Safari extension installed on this Mac, each
/// with a switch, and its details — websites, permissions, private windows,
/// shortcuts — a click away.
struct ExtensionsSettings: View {
    @State private var details: Details?
    @State private var looking = true
    @State private var loadError: String?

    struct Details: Identifiable { let id: String }

    var body: some View {
        let extensions = Extensions.shared
        let listings = extensions.listings
        Form {
            if listings.isEmpty {
                Section {
                    if looking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Looking for extensions…").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        ContentUnavailableView {
                            Label("No Extensions", systemImage: "puzzlepiece.extension")
                        } description: {
                            Text("Zentic runs the same extensions as Safari. Get one from the App Store, open its app once, and it appears here.")
                        }
                        .frame(minHeight: 180)
                    }
                }
            } else {
                Section {
                    ForEach(listings) { listing in
                        ExtensionRow(listing: listing) { details = Details(id: listing.id) }
                    }
                } footer: {
                    Text("An extension you turn on gets a button beside the address bar, and runs only on the websites you allow.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent {
                    Button("Choose Folder…", action: loadUnpacked)
                } label: {
                    Text("Load Unpacked Extension")
                    Text("For developers: run an extension straight from its folder, with no app around it.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 480)
        .task {
            await extensions.lookForInstalled()
            looking = false
        }
        .sheet(item: $details) { ExtensionDetail(id: $0.id) }
        .alert(
            "Couldn’t Load the Extension", isPresented: Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(loadError ?? "")
        }
    }

    private func loadUnpacked() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Load"
        panel.message = "Choose the folder that contains the extension’s manifest.json."
        Task {
            let response = if let window = NSApp.keyWindow { await panel.beginSheetModal(for: window) } else { panel.runModal() }
            guard response == .OK, let url = panel.url else { return }
            do {
                try await Extensions.shared.addFolder(url)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}

private struct ExtensionRow: View {
    let listing: Extensions.Listing
    var showDetails: () -> Void

    var body: some View {
        let extensions = Extensions.shared
        let name = extensions.name(listing.id)
        let failure = extensions.failures[listing.id]
        HStack(spacing: 12) {
            ExtensionIcon(id: listing.id, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.body.weight(.medium))
                    if listing.isFolder { DeveloperTag() }
                }
                if let failure {
                    Text(failure).font(.caption).foregroundStyle(.orange).lineLimit(1)
                } else {
                    Text(extensions.byline(listing.id))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Button(action: showDetails) {
                Image(systemName: "info.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Details")
            .accessibilityLabel("\(name) details")
            Toggle(
                "Turn on \(name)",
                isOn: Binding(
                    get: { extensions.record(listing.id)?.isEnabled == true },
                    set: { extensions.setEnabled($0, listing.id) })
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            // One that can't be read can't be turned on, but one left on
            // when its app went away must still be turned off.
            .disabled(extensions.parsed[listing.id] == nil && extensions.record(listing.id)?.isEnabled != true)
            // SwiftUI's switch offers assistive apps no press action here;
            // without one, VoiceOver could read it but not flip it.
            .accessibilityAction {
                extensions.setEnabled(extensions.record(listing.id)?.isEnabled != true, listing.id)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DeveloperTag: View {
    var body: some View {
        Text("Developer")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
    }
}

// MARK: - Details

private struct ExtensionDetail: View {
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemoval = false

    var body: some View {
        let extensions = Extensions.shared
        let name = extensions.name(id)
        let webExtension = extensions.parsed[id]
        let record = extensions.record(id)
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 14) {
                        ExtensionIcon(id: id, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).font(.title3.weight(.semibold))
                            Text(extensions.byline(id)).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle(
                            "On",
                            isOn: Binding(get: { record?.isEnabled == true }, set: { extensions.setEnabled($0, id) })
                        )
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(webExtension == nil && record?.isEnabled != true)
                        .accessibilityLabel("Turn on \(name)")
                        .accessibilityAction { extensions.setEnabled(record?.isEnabled != true, id) }
                    }
                    if let description = webExtension?.displayDescription, !description.isEmpty {
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let failure = extensions.failures[id] {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                if webExtension != nil {
                    WebsitesSection(id: id)
                    PermissionsSection(id: id)
                    Section {
                        Toggle(
                            "Allow in Private Windows",
                            isOn: Binding(
                                get: { record?.allowsPrivateWindows == true },
                                set: { extensions.setAllowsPrivateWindows($0, id) })
                        )
                        .disabled(record?.isEnabled != true)
                    } footer: {
                        Text("Extensions stay out of private windows unless you let them in. One you allow can see and change the pages you visit privately.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ShortcutsSection(id: id)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack(spacing: 10) {
                Button("Remove from Zentic…", role: .destructive) { confirmingRemoval = true }
                    .disabled(record == nil)
                if case .folder(let path)? = record?.source {
                    Button("Reload") { Task { await extensions.reload(id) } }
                        .help("Read the extension from its folder again")
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
                    }
                }
                Spacer()
                if extensions.isRunning(id), webExtension?.hasOptionsPage == true {
                    Button("Options…") {
                        extensions.openOptions(id)
                        dismiss()
                    }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 520, height: 500)
        .alert("Remove “\(name)” from Zentic?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive) {
                Task { await extensions.remove(id) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                record.map { if case .folder = $0.source { true } else { false } } == true
                    ? "Zentic forgets the folder and deletes what the extension stored. The folder itself is left alone."
                    : "It’s turned off, and its settings and the data it stored in Zentic are deleted. The app stays installed, and you can turn the extension on again later.")
        }
    }
}

private struct WebsitesSection: View {
    let id: String
    @State private var newSite = ""
    @State private var problem: String?

    var body: some View {
        let extensions = Extensions.shared
        let access = extensions.siteAccess(id)
        if access != .none {
            Section {
                Picker(
                    "Allow on",
                    selection: Binding(get: { access == .allSites }, set: { extensions.setAllSites($0, id) })
                ) {
                    Text("Websites You Allow").tag(false)
                    Text("All Websites").tag(true)
                }
                if case .whenClicked(let sites) = access {
                    ForEach(sites, id: \.self) { site in
                        HStack(spacing: 10) {
                            SiteIcon(image: Favicons.shared.cached(for: URL(string: "https://\(site)")), size: 16)
                            Text(site)
                            Spacer()
                            Button {
                                withAnimation(.smooth(duration: 0.25)) { extensions.disallow(site: site, id) }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Stop allowing on \(site)")
                            .accessibilityLabel("Stop allowing on \(site)")
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    HStack(spacing: 8) {
                        TextField("Add a website", text: $newSite, prompt: Text("example.com"))
                            .labelsHidden()
                            .onSubmit(add)
                            .onChange(of: newSite) { problem = nil }
                        Button("Allow", action: add)
                            .disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let problem {
                        Text(problem).font(.callout).foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Websites")
            } footer: {
                Text(
                    access == .allSites
                        ? "It can read and change every website it asks for, including what you type into them."
                        : "Its button shows a dot on websites it would like to use. Click the button there to allow that site for a day, or for good."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func add() {
        let extensions = Extensions.shared
        guard let pattern = SitePattern.forSite(newSite) else {
            problem = "That doesn’t look like a website address."
            return
        }
        guard extensions.asksFor(site: pattern, id) else {
            problem = "\(extensions.name(id)) doesn’t ask to run there."
            return
        }
        withAnimation(.smooth(duration: 0.25)) { extensions.allow(site: pattern, id) }
        newSite = ""
    }
}

private struct PermissionsSection: View {
    let id: String

    var body: some View {
        let requested = Extensions.shared.parsed[id]?.requestedPermissions ?? []
        // Several permissions read the same to a person ("storage" and
        // "unlimitedStorage"); list each sentence once.
        var seen = Set<String>()
        let lines = requested.map(\.summary).sorted { $0.text < $1.text }.filter { seen.insert($0.text).inserted }
        Section {
            if lines.isEmpty {
                Text("Nothing beyond the websites above.").foregroundStyle(.secondary)
            }
            ForEach(lines, id: \.text) { line in
                Label {
                    Text(line.text)
                } icon: {
                    Image(systemName: line.symbol).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("It Can")
        } footer: {
            if requested.contains(.nativeMessaging) {
                Text("Zentic can’t connect an extension to its app yet, so anything that needs the app — unlocking with Touch ID, say — won’t work here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ShortcutsSection: View {
    let id: String

    var body: some View {
        let commands = shortcuts
        if !commands.isEmpty {
            Section {
                ForEach(commands, id: \.title) { command in
                    LabeledContent(command.title) {
                        HStack(spacing: 6) {
                            if command.taken {
                                Text("Used by Zentic")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(ExtensionShortcuts.text(for: command.chord))
                                .font(.callout.monospaced())
                                .strikethrough(command.taken)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: .rect(cornerRadius: 5, style: .continuous))
                        }
                    }
                }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("Where an extension’s shortcut is one Zentic already uses, Zentic’s wins.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var shortcuts: [(title: String, chord: KeyChord, taken: Bool)] {
        let extensions = Extensions.shared
        // A context that is not running still reads the manifest's commands.
        guard let context = extensions.contexts[id] ?? extensions.parsed[id].map(WKWebExtensionContext.init(for:))
        else { return [] }
        return context.commands.compactMap { command in
            guard let chord = command.chord else { return nil }
            let title = command.id == "_execute_browser_action" || command.id == "_execute_action"
                ? "Open \(extensions.name(id))" : command.title
            return (title, chord, ExtensionShortcuts.menu(NSApp.mainMenu, uses: chord))
        }
    }
}

extension Extensions {
    /// "Version 2.1 · from Bitwarden", or where a folder extension lives.
    func byline(_ id: String) -> String {
        let version = parsed[id]?.displayVersion.map { "Version \($0)" }
        let origin: String? =
            if case .folder(let path)? = record(id)?.source {
                (path as NSString).abbreviatingWithTildeInPath
            } else {
                installed.first { "app:\($0.bundleID)" == id }.map { "from \($0.appName)" }
            }
        return [version, origin].compactMap(\.self).joined(separator: " · ")
    }
}

extension WKWebExtension.Permission {
    /// What the permission lets an extension do, in words a person would use.
    var summary: (text: String, symbol: String) {
        switch self {
        case .activeTab: ("Read and change the page you’re on when you click its button", "cursorarrow.click")
        case .alarms: ("Run tasks on a schedule", "alarm")
        case .clipboardWrite: ("Copy text to your clipboard", "doc.on.clipboard")
        case .contextMenus, .menus: ("Add items to menus", "contextualmenu.and.cursorarrow")
        case .cookies: ("Read and change cookies", "tray.full")
        case .declarativeNetRequest, .declarativeNetRequestWithHostAccess:
            ("Block or redirect what websites load", "hand.raised")
        case .declarativeNetRequestFeedback: ("See what it blocked", "list.bullet.rectangle")
        case .nativeMessaging: ("Talk to its app on this Mac", "app.connected.to.app.below.fill")
        case .scripting: ("Run scripts on websites it can access", "chevron.left.forwardslash.chevron.right")
        case .storage, .unlimitedStorage: ("Keep its own data on this Mac", "internaldrive")
        case .tabs: ("See the titles and addresses of your tabs", "square.on.square")
        case .webNavigation: ("See when you go to a new page", "arrow.triangle.turn.up.right.circle")
        case .webRequest: ("See the requests websites make", "network")
        default: (rawValue, "puzzlepiece.extension")
        }
    }
}
