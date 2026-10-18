import SwiftUI
import ZenticKit

/// The site's popover: whether Zentic keeps a database of this site, and what is
/// in it. Under the modes, because it is a choice about the site like they are —
/// but not one of them: recording changes nothing on screen.
struct LibrarySection: View {
    @Environment(Browser.self) private var browser
    let tab: Tab
    @Bindable private var apps = Apps.shared

    var body: some View {
        if let origin = Apps.originKey(tab.url) {
            let source = apps.source(origin)
            VStack(alignment: .leading, spacing: 8) {
                Divider().padding(.vertical, 6)
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(source == nil ? AnyShapeStyle(Color.primary.opacity(0.07)) : AnyShapeStyle(Color.accentColor.gradient))
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(source == nil ? Color.primary.opacity(0.8) : .white)
                    }
                    .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep a database of this site")
                            .font(.system(size: 13, weight: .semibold))
                        Text(source.map { detail(for: $0, count: apps.recordCounts[origin] ?? 0) }
                            ?? "Save what it shows you as you browse, on this Mac, for apps you make.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Toggle(
                        "Keep a database of this site",
                        isOn: Binding(
                            get: { source != nil },
                            set: { on in
                                if on, let url = tab.url {
                                    browser.modePickerPresented = false
                                    Task { await LibraryActions.addSource(url: url, title: tab.title, in: browser, reloading: tab) }
                                } else if !on {
                                    browser.modePickerPresented = false
                                    LibraryActions.removeSource(origin, in: browser)
                                }
                            })
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                .padding(.horizontal, 8)

                if let source {
                    HStack(spacing: 8) {
                        RefreshPicker(source: source) { refresh in
                            browser.modePickerPresented = false
                            LibraryActions.setRefresh(refresh, for: origin, over: browser.window)
                        }
                        Spacer()
                        Button("New App…") {
                            browser.modePickerPresented = false
                            LibraryActions.newApp(in: browser)
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
    }

    private func detail(for source: Source, count: Int) -> String {
        guard count > 0 else {
            return source.recipe == nil && !AppModel.shared.hasAPIKey
                ? "Saving pages. Add an OpenAI key in Settings so Zentic can learn this site’s format."
                : "Nothing yet — scroll around and what you see is saved here."
        }
        var text = count.formatted() + (count == 1 ? " record" : " records")
        if let last = source.lastCapturedAt { text += " · updated " + last.formatted(.relative(presentation: .named)) }
        if source.refresh == .session { text += " · kept up to date in the background" }
        return text
    }
}

/// Settings › Library: every source and app in one place, and the model apps
/// are designed with.
struct LibrarySettings: View {
    @Environment(AppModel.self) private var app
    @Bindable private var apps = Apps.shared

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                if apps.sources.isEmpty {
                    Text("No sources yet. On any site, choose Page › Keep a Database of This Site.")
                        .foregroundStyle(.secondary)
                }
                ForEach(apps.sources) { source in
                    SourceSettingsRow(source: source, count: apps.recordCounts[source.origin] ?? 0)
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("What these sites show you is saved on this Mac as you browse — never on a site you haven’t added, and never in a private window. Signed-in sites update only while you use them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Apps") {
                if apps.apps.isEmpty {
                    Text("No apps yet. Choose Page › New App… to describe one.")
                        .foregroundStyle(.secondary)
                }
                ForEach(apps.apps) { made in
                    HStack(spacing: 10) {
                        Image(systemName: made.symbol)
                            .symbolRenderingMode(.hierarchical)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(made.name)
                            Text("Version \(made.currentVersion) · from \(made.sources.compactMap { URL(string: $0).map(URLGuess.displayHost) }.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Delete", role: .destructive) { Task { await apps.delete(made) } }
                            .buttonStyle(.borderless)
                    }
                }
            }

            Section {
                Toggle("Draw an icon for each new app", isOn: $app.drawsAppIcons)
                TextField("Image model", text: $app.imageModel, prompt: Text(OpenAILibrarian.defaultImageModel))
                    .disabled(!app.drawsAppIcons)
                Text("OpenAI’s image model draws a new app’s icon from its name and your request — never from your data. One image per app; right-click an app to draw another.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("App model", text: $app.appModel, prompt: Text(OpenAILibrarian.defaultAppModel))
                Text("The model that designs apps. A whole app is worth the strongest model’s wait; custom versions use the model on the Intelligence tab, which also learns new sites’ formats.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
    }
}

private struct SourceSettingsRow: View {
    let source: Source
    let count: Int
    @State private var icon: NSImage?
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 10) {
            SiteIcon(image: icon, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.title)
                Text("\(count.formatted()) \(count == 1 ? "record" : "records")" + (source.lastCapturedAt.map { " · updated " + $0.formatted(.relative(presentation: .named)) } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            RefreshPicker(source: source) { refresh in
                LibraryActions.setRefresh(refresh, for: source.origin, over: NSApp.keyWindow)
            }
            Button("Remove…", role: .destructive) { confirming = true }
                .buttonStyle(.borderless)
        }
        .task(id: source.origin) {
            guard let url = URL(string: source.origin) else { return }
            icon = Favicons.shared.cached(for: url)
            if icon == nil { icon = await Favicons.shared.icon(for: url, declared: nil) }
        }
        .confirmationDialog("Stop keeping a database of \(source.title)?", isPresented: $confirming) {
            Button("Stop and Delete \(count.formatted()) Records", role: .destructive) {
                Task { await Apps.shared.removeSource(source.origin) }
            }
        } message: {
            Text("Apps that read it will show nothing from it.")
        }
    }
}

/// How a source stays fresh: only as the user browses (the default), also
/// signed out in the background, or also signed in in the background — the last
/// behind a warning, chosen per source, never for all of them at once.
struct RefreshPicker: View {
    let source: Source
    var choose: (Source.Refresh) -> Void

    var body: some View {
        Picker(
            "Updates",
            selection: Binding(get: { source.refresh }, set: { value in if value != source.refresh { choose(value) } })
        ) {
            Text("As you browse").tag(Source.Refresh.browse)
            Text("Also in the background, signed out").tag(Source.Refresh.background)
            Text("Also in the background, signed in…").tag(Source.Refresh.session)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .controlSize(.small)
        .help(help)
    }

    private var help: String {
        switch source.refresh {
        case .browse: "Updates only while you browse it."
        case .background: "Also checks the site’s front page every 30 minutes in a throwaway window with no cookies."
        case .session: "Also opens it with your account about every 45 minutes, scrolls a little, and saves what loads. Never clicks or posts."
        }
    }
}
