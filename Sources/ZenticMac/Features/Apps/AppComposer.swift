import SwiftUI
import ZenticKit

/// What the app composer is doing: making a new app, or revising one.
struct AppComposerState: Equatable {
    enum Mode: Equatable {
        case create
        case revise(appID: String)
    }
    var mode: Mode
    var draft = ""
    /// Origins ticked. Starts with the current page's site when it is a source,
    /// or the only source there is.
    var selected: Set<String>
}

/// Where the user describes an app over their sources.
///
/// Floats over the bottom of the page like the custom-version composer, in the
/// same glass. Its most important line is the disclosure: generating sends the
/// user's own records to OpenAI, and this says exactly what goes, every time,
/// before anything does. If that sentence and `AppBrief` ever disagree, the
/// sentence is the bug.
struct AppComposer: View {
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    @Bindable var apps = Apps.shared
    @Binding var state: AppComposerState
    @FocusState private var focused: Bool

    private var revising: GeneratedApp? {
        if case .revise(let id) = state.mode { return apps.app(id) }
        return nil
    }

    private var isWorking: Bool { apps.generation?.phase == .working }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !app.hasAPIKey {
                KeyEntry()
            } else if apps.sources.isEmpty {
                NoSources()
            } else {
                if let revising, !revising.prompts.isEmpty, !isWorking { earlier(revising.prompts) }
                status
                if !isWorking { sourcePicker }
                input
                disclosure
            }
        }
        .padding(14)
        .frame(maxWidth: 640)
        .panelGlass(in: .rect(cornerRadius: 26))
        .shadow(color: .black.opacity(0.18), radius: 30, x: 0, y: 10)
        .onAppear { focused = true }
        .onExitCommand { close() }
        .animation(.smooth(duration: 0.28), value: apps.generation)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: revising.map { $0.symbol } ?? "square.grid.2x2")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor.gradient)
            Text(revising.map { "Revise \($0.name)" } ?? "New App")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(isWorking ? "Close — the app keeps being made and appears in your sidebar (Esc)" : "Close (Esc)")
            .accessibilityLabel("Close")
        }
    }

    private func earlier(_ prompts: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("You asked for")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            ForEach(Array(prompts.suffix(3).enumerated()), id: \.offset) { _, prompt in
                Text("“\(prompt)”")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch apps.generation?.phase {
        case .working:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: apps.generation?.started ?? .now, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(apps.generation?.started ?? .now))
                    Text("\(revising == nil ? "Designing your app" : "Revising") … \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer()
                Text("You can close this; it keeps going.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Button("Stop") { apps.cancelGeneration() }
                    .controlSize(.small)
            }
            .padding(.vertical, 2)
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if message == DesignError.badKey.localizedDescription || message == DesignError.noKey.localizedDescription {
                    SettingsLink { Text("Settings…") }.controlSize(.small)
                }
            }
        case nil:
            if state.draft.isEmpty && revising == nil {
                FlowLayout(spacing: 6) {
                    ForEach(suggestions, id: \.label) { suggestion in
                        Button(suggestion.label) {
                            state.draft = suggestion.prompt
                            focused = true
                        }
                        .buttonStyle(ChipStyle())
                        .help(suggestion.prompt)
                    }
                }
            }
        }
    }

    /// Only suggestions the user's sources can actually satisfy.
    private var suggestions: [(label: String, prompt: String)] {
        let hasX = apps.sources.contains { ["https://x.com", "https://twitter.com"].contains($0.origin) }
        var out: [(String, String)] = []
        if hasX {
            out.append((
                "Replies inbox",
                "A calm inbox of everyone replying to or mentioning me on X, newest first, grouped by conversation, with one-click reply and like."))
        }
        out.append((
            "Morning paper",
            "A morning newspaper: a serif masthead with today’s date, two columns, the posts and links shared in the last 24 hours, grouped by the site they link to."))
        out.append((
            "Compact digest",
            "A compact digest: one line per item, grouped by source, with a search field and keyboard navigation."))
        return out
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sources")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            FlowLayout(spacing: 6) {
                ForEach(apps.sources) { source in
                    SourceChip(source: source, count: apps.recordCounts[source.origin] ?? 0, isOn: state.selected.contains(source.origin)) {
                        if state.selected.contains(source.origin) { state.selected.remove(source.origin) } else { state.selected.insert(source.origin) }
                    }
                }
            }
        }
    }

    private var input: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $state.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...6)
                .focused($focused)
                .disabled(isWorking)
                .onSubmit(submit)
                .padding(.vertical, 8)
                .padding(.leading, 12)
                .accessibilityLabel(revising == nil ? "Describe the app" : "What should change")

            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(canSubmit ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.secondary.opacity(0.35))))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .padding(4)
            .help(revising == nil ? "Make the App (↩)" : "Revise (↩)")
            .accessibilityLabel(revising == nil ? "Make the app" : "Revise")
        }
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
    }

    private var disclosure: some View {
        Label {
            Text(disclosureText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var disclosureText: String {
        (revising == nil
            ? "Sent to OpenAI with your key: this request, "
            : "Sent to OpenAI with your key: this request, your earlier requests, the app’s current code, ")
            + "the record format, each ticked source’s name, size and kinds of record, and its "
            + "\(LibraryBudget.appSampleRecords) newest records (text cut to \(LibraryBudget.appSampleTextLength) characters, "
            + "images left out)."
            + (revising == nil && app.drawsAppIcons
                ? " Its name and your request also go to OpenAI’s image model to draw its icon." : "")
            + " The app itself runs sealed off — no network, no model — and opens only links you click."
    }

    private var placeholder: String {
        revising == nil ? "What should it show, how should it look, and what can you do from it?" : "What should change?"
    }

    private var canSubmit: Bool {
        !isWorking && !state.selected.isEmpty && !state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        let prompt = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let origins = apps.sources.map(\.origin).filter(state.selected.contains)
        apps.dismissFailure()
        apps.generate(prompt: prompt, sources: origins, revising: revising) { [weak browser] made in
            guard let browser else { return }
            // Opened only if this window is still waiting on it; otherwise the
            // tile appearing in the sidebar is the news.
            if browser.appComposer != nil {
                browser.appComposer = nil
                browser.open(made)
            } else {
                browser.notice = Notice(
                    title: "“\(made.name)” is ready", detail: "It’s in your sidebar.", symbol: made.symbol, action: .openApp(made.id))
            }
        }
        state.draft = ""
    }

    private func close() {
        apps.dismissFailure()
        browser.appComposer = nil
    }
}

/// A source to tick: its icon, its name, and how much is in it.
private struct SourceChip: View {
    let source: Source
    let count: Int
    let isOn: Bool
    var toggle: () -> Void
    @State private var icon: NSImage?

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                SiteIcon(image: icon, size: 14)
                Text(source.title)
                    .font(.system(size: 12, weight: .medium))
                Text(count == 0 ? "empty" : count.formatted())
                    .font(.system(size: 10.5))
                    .foregroundStyle(isOn ? Color.white.opacity(0.8) : Color.secondary)
                    .monospacedDigit()
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(Capsule().fill(isOn ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(0.07))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(Self.detail(source: source, count: count))
        .accessibilityLabel("\(source.title), \(Self.detail(source: source, count: count))")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .task(id: source.origin) {
            guard let url = URL(string: source.origin) else { return }
            icon = Favicons.shared.cached(for: url)
            if icon == nil { icon = await Favicons.shared.icon(for: url, declared: nil) }
        }
    }

    /// Facts only: how much is stored, how it stays fresh, when it last changed.
    static func detail(source: Source, count: Int) -> String {
        guard count > 0 else {
            return source.refresh == .browse ? "Empty — open it and scroll to fill it" : "Empty — refreshes in the background"
        }
        var parts = [count.formatted() + (count == 1 ? " record" : " records")]
        if let last = source.lastCapturedAt { parts.append("updated " + last.formatted(.relative(presentation: .named))) }
        switch source.refresh {
        case .browse: parts.append("updates as you browse")
        case .background: parts.append("also refreshed signed out")
        case .session: parts.append("kept up to date in the background")
        }
        return parts.joined(separator: " · ")
    }
}

/// No sources yet: what one is, and the one-click way to add the site on screen.
private struct NoSources: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apps are built from sites you keep a database of — your timeline, a news site, a forum. Zentic records what those sites show you as you browse, on this Mac.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let tab = browser.selectedTab, SiteKey.isWeb(tab.url), let url = tab.url {
                Button("Keep a Database of \(tab.displayHost)") {
                    browser.appComposer = nil
                    Task { await LibraryActions.addSource(url: url, title: tab.title, in: browser, reloading: tab) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Text("Open a site, then choose Page › Keep a Database of This Site.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct ChipStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.10 : 0.06)))
            .onHover { hovering = $0 }
    }
}

/// The actions that start or stop keeping a database of a site, shared by the
/// menu, the site's popover and the composer.
@MainActor
enum LibraryActions {
    static func addSource(url: URL, title: String, in browser: Browser, reloading tab: Tab?) async {
        guard !browser.isPrivate else { return }
        await Apps.shared.addSource(url: url, title: title)
        // The recorder is installed at document start, so this page cannot be
        // recorded retroactively. Reloading is the honest way to begin.
        tab?.reload()
        let host = URLGuess.displayHost(url)
        var detail = "What \(host) shows you as you browse is saved on this Mac. Nothing is fetched on your behalf."
        let origin = Apps.originKey(url).flatMap(Apps.shared.source)
        if origin?.recipe == nil {
            // Invariant 7: say what learning the site's format sends, when it does.
            detail += AppModel.shared.hasAPIKey
                ? " To learn its format, Zentic sends OpenAI the shape of its data — field names and types, never the content."
                : " Add an OpenAI key in Settings so Zentic can learn its format; until then pages are kept but apps can’t read them yet."
        }
        browser.notice = Notice(title: "Keeping a database of \(host)", detail: detail, symbol: "tray.and.arrow.down", action: .newApp)
    }

    static func removeSource(_ origin: String, in browser: Browser) {
        guard let window = browser.window else { return }
        let apps = Apps.shared
        let count = apps.recordCounts[origin] ?? 0
        let users = apps.apps.filter { $0.sources.contains(origin) }.map(\.name).sorted()
        let alert = NSAlert()
        alert.messageText = "Stop keeping a database of \(URL(string: origin).map(URLGuess.displayHost) ?? origin)?"
        var detail = "Zentic stops recording it and deletes the \(count.formatted()) \(count == 1 ? "record" : "records") saved from it."
        if !users.isEmpty { detail += " \(ListFormatter.localizedString(byJoining: users)) will show nothing from it." }
        alert.informativeText = detail
        alert.addButton(withTitle: "Stop and Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in await apps.removeSource(origin) }
        }
    }

    /// Change how a source stays fresh. Turning on signed-in background visits
    /// asks first, in plain words, because it is the one choice here that could
    /// cost the user their account on that site.
    static func setRefresh(_ refresh: Source.Refresh, for origin: String, over window: NSWindow?) {
        let apps = Apps.shared
        guard refresh == .session else {
            Task { await apps.setRefresh(refresh, for: origin) }
            return
        }
        let host = URL(string: origin).map(URLGuess.displayHost) ?? origin
        let alert = NSAlert()
        alert.messageText = "Keep \(host) up to date while you’re away?"
        alert.informativeText = """
            Zentic will open \(host) in the background with your account, about every 45 minutes \
            and no more than \(LibraryBudget.sessionVisitsPerDay) times a day, scroll a few screens \
            like someone reading, and save what loads. It never clicks, types or posts.

            Some sites treat automated visits to an account as against their terms, and can \
            limit or lock accounts that make them. Turn this on only if you accept that risk \
            for \(host).
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Keep It Up to Date")
        let decide: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertSecondButtonReturn else { return }
            Task { @MainActor in await apps.setRefresh(.session, for: origin) }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: decide) } else { decide(alert.runModal()) }
    }

    static func newApp(in browser: Browser) {
        let apps = Apps.shared
        let current = Apps.originKey(browser.selectedTab?.url)
        let selected: Set<String> =
            current.map { origin in apps.sources.contains { $0.origin == origin } ? [origin] : [] }
            ?? (apps.sources.count == 1 ? [apps.sources[0].origin] : [])
        browser.appComposer = AppComposerState(
            mode: .create, selected: selected.isEmpty && apps.sources.count == 1 ? [apps.sources[0].origin] : selected)
    }

    static func revise(_ app: GeneratedApp, in browser: Browser) {
        browser.appComposer = AppComposerState(mode: .revise(appID: app.id), selected: Set(app.sources))
    }

    static func delete(_ app: GeneratedApp, in browser: Browser) {
        guard let window = browser.window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(app.name)”?"
        alert.informativeText = "Every version of the app is deleted. This can’t be undone. Its sources and their records are kept."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in await Apps.shared.delete(app) }
        }
    }
}
