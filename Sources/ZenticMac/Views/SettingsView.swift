import SwiftUI
import ZenticKit

struct SettingsView: View {
    var body: some View {
        TabView {
            SwiftUI.Tab("General", systemImage: "gearshape") { GeneralSettings() }
            SwiftUI.Tab("Intelligence", systemImage: "wand.and.sparkles") { IntelligenceSettings() }
            SwiftUI.Tab("Sites", systemImage: "globe") { SitesSettings() }
        }
        .frame(width: 560)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @State private var refreshing = false
    @State private var refreshResult: String?

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                Picker("New sites open in", selection: Binding(get: { app.defaultMode }, set: { app.defaultMode = $0 })) {
                    ForEach([SiteMode.original, .clean, .minimal]) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text(app.defaultMode.subtitle + ". You can change any site from the control at the left of the address bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Search with", selection: $app.searchEngine) {
                    ForEach(URLGuess.SearchEngine.allCases) { Text($0.title).tag($0) }
                }
            }

            Section("Appearance") {
                Picker("Appearance", selection: $app.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Translucency") {
                    Slider(value: $app.translucency, in: 0...1) {
                        EmptyView()
                    } minimumValueLabel: {
                        Image(systemName: "circle.fill").font(.caption2)
                    } maximumValueLabel: {
                        Image(systemName: "circle.dotted").font(.caption)
                    }
                    .frame(width: 200)
                }
                Text("Each space has its own colour. Right-click a space at the bottom of the sidebar to change it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show Bookmarks", isOn: $app.showsBookmarks)
                Text("Adds a Bookmarks menu (⇧⌘D to add, ⌥⌘B to show), bookmarks in the address bar’s suggestions, and import from Safari, Chrome or Firefox.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Content Blocking") {
                LabeledContent("Filter lists") {
                    HStack {
                        if let refreshResult {
                            Text(refreshResult).foregroundStyle(.secondary).font(.callout)
                        }
                        Button(refreshing ? "Updating…" : "Update Now") { refresh() }
                            .disabled(refreshing)
                    }
                }
                Text("EasyList, EasyPrivacy, cookie notices and annoyances, compiled into Safari’s content blocker. Lists update in the background.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }

    private func refresh() {
        refreshing = true
        refreshResult = nil
        Task {
            defer { refreshing = false }
            do {
                let report = try await Blocking.engine.refresh(force: true)
                refreshResult = "\(report.rulesCompiled.formatted()) rules"
            } catch {
                refreshResult = "Couldn’t update"
            }
        }
    }
}

private struct IntelligenceSettings: View {
    @Environment(AppModel.self) private var app
    @State private var key = ""
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle, checking, ok, failed(String)
    }

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                if app.hasAPIKey {
                    LabeledContent("OpenAI API key") {
                        HStack(spacing: 8) {
                            Text(APIKeyStore.redacted(.openAI) ?? "Saved")
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                            Button("Remove", role: .destructive) {
                                app.removeAPIKey()
                                status = .idle
                            }
                        }
                    }
                } else {
                    LabeledContent("OpenAI API key") {
                        HStack(spacing: 8) {
                            SecureField("sk-…", text: $key)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                                .onSubmit(save)
                            Button("Save", action: save)
                                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || status == .checking)
                        }
                    }
                }
                HStack {
                    statusView
                    Spacer()
                    if app.hasAPIKey {
                        Button("Test Connection") { test() }
                            .disabled(status == .checking)
                    }
                }
            } footer: {
                Text("Your key is stored in the macOS Keychain on this Mac and sent only to OpenAI, only when you design a custom version. Pages are never sent anywhere otherwise.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Model", text: $app.model, prompt: Text(OpenAIDesigner.defaultModel))
                Text("Any chat model your key can use. Faster models make previews quicker; larger ones write more ambitious designs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 360)
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .ok:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        status = .checking
        Task {
            do {
                try await OpenAIDesigner(apiKey: trimmed, model: app.model).verify()
                try app.saveAPIKey(trimmed)
                key = ""
                status = .ok
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func test() {
        status = .checking
        Task {
            do {
                try await app.designer().verify()
                status = .ok
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }
}

private struct SitesSettings: View {
    @Environment(AppModel.self) private var app
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if app.sites.isEmpty {
                ContentUnavailableView(
                    "No Site Settings",
                    systemImage: "globe",
                    description: Text("Sites you change from the address bar appear here."))
                    .frame(height: 360)
            } else {
                List(selection: $selection) {
                    ForEach(app.sites, id: \.key) { site in
                        SiteRow(key: site.key, settings: site.settings)
                            .tag(site.key)
                            .contextMenu {
                                if site.settings.custom != nil {
                                    Button("Remove Custom Version") { app.removeCustom(forKey: site.key) }
                                }
                                Button("Reset to Default", role: .destructive) { app.forgetSite(site.key) }
                            }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(height: 340)
                .onDeleteCommand {
                    if let selection { app.forgetSite(selection) }
                }

                HStack {
                    Button("Reset to Default") {
                        if let selection { app.forgetSite(selection) }
                    }
                    .disabled(selection == nil)
                    Spacer()
                    Text("\(app.sites.count) site\(app.sites.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .padding(12)
            }
        }
        .padding(.top, 8)
    }
}

private struct SiteRow: View {
    let key: String
    let settings: SiteSettings

    var body: some View {
        HStack(spacing: 10) {
            SiteIcon(image: Favicons.shared.cached(for: URL(string: "https://\(key)")), size: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(key).font(.body.weight(.medium))
                if let custom = settings.custom {
                    Text(custom.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Label(settings.mode.title, systemImage: settings.mode.symbol)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}
