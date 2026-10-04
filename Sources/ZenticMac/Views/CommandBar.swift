import SwiftUI
import ZenticKit

/// ⌘T and ⌘L: type an address, a search, or the name of something already open.
struct CommandBar: View {
    @Environment(Browser.self) private var browser
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool
    @State private var highlighted = 0
    /// Computed when the text changes, not on every redraw — hovering a row
    /// redraws, and scoring thousands of history entries per frame shows.
    @State private var results: [Result] = []

    var body: some View {
        @Bindable var browser = browser
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: browser.commandBar.opensNewTab ? "plus.magnifyingglass" : "magnifyingglass")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    TextField(
                        browser.commandBar.opensNewTab ? "Search or enter address" : "Go to address or search",
                        text: $browser.commandBar.text
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 19, weight: .regular))
                    .focused($focused)
                    .onSubmit { open(results[safe: highlighted], forceNewTab: false) }
                    .onKeyPress(.downArrow) {
                        highlighted = min(highlighted + 1, max(results.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        highlighted = max(highlighted - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        open(results[safe: highlighted], forceNewTab: true)
                        return .handled
                    }
                }
                .padding(.horizontal, 18)
                .frame(height: 58)

                if !results.isEmpty {
                    Divider().opacity(0.5)
                    VStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            SuggestionRow(result: result, highlighted: index == highlighted)
                                .onTapGesture { open(result, forceNewTab: false) }
                                .onHover { if $0 { highlighted = index } }
                        }
                    }
                    .padding(6)
                }
            }
            .frame(maxWidth: 660)
            .panelGlass(in: .rect(cornerRadius: 26))
            .shadow(color: .black.opacity(0.25), radius: 40, x: 0, y: 18)
            .padding(.top, 70)
            .padding(.horizontal, 24)
        }
        .onAppear {
            focused = true
            highlighted = 0
            results = suggestions
        }
        .onChange(of: browser.commandBar.text) {
            highlighted = 0
            results = suggestions
        }
        .onExitCommand { dismiss() }
    }

    // MARK: - Results

    struct Result: Identifiable {
        enum Kind { case go(URL), search(URL), tab(Tab), favorite(Favorite), history(HistoryEntry) }
        let id: String
        let kind: Kind
        let title: String
        let subtitle: String
        let icon: NSImage?
        let symbol: String
        let trailing: String?
    }

    private var suggestions: [Result] {
        let text = browser.commandBar.text.trimmingCharacters(in: .whitespaces)
        var results: [Result] = []
        if text.isEmpty {
            if browser.commandBar.opensNewTab {
                for favorite in app.favorites.prefix(5) {
                    results.append(
                        Result(
                            id: "f" + favorite.id.uuidString, kind: .favorite(favorite), title: favorite.title,
                            subtitle: URLGuess.displayHost(favorite.url), icon: Favicons.shared.cached(for: favorite.url),
                            symbol: "star", trailing: nil))
                }
            }
            return results
        }

        if let url = URLGuess.resolve(text, engine: app.searchEngine) {
            let isSearch = URLGuess.isSearch(url, engine: app.searchEngine)
            results.append(
                Result(
                    id: "go", kind: isSearch ? .search(url) : .go(url),
                    title: isSearch ? text : URLGuess.displayHost(url) + (url.path.count > 1 ? url.path : ""),
                    subtitle: isSearch ? "Search \(app.searchEngine.title)" : "Open",
                    icon: isSearch ? nil : Favicons.shared.cached(for: url),
                    symbol: isSearch ? "magnifyingglass" : "globe", trailing: "↩"))
        }

        let q = text.lowercased()
        // Every space of this window, the current one first.
        let spaces = [browser.space] + browser.spaces.filter { $0 !== browser.space }
        for space in spaces {
            for tab in space.allTabs where tab !== browser.selectedTab || browser.commandBar.opensNewTab {
                guard tab.title.lowercased().contains(q) || tab.displayHost.lowercased().contains(q) else { continue }
                let elsewhere = space !== browser.space
                results.append(
                    Result(
                        id: "t" + tab.id.uuidString, kind: .tab(tab), title: tab.title.isEmpty ? tab.displayHost : tab.title,
                        subtitle: elsewhere ? "\(space.name) · \(tab.displayHost)" : tab.displayHost, icon: tab.icon,
                        symbol: "square.on.square", trailing: elsewhere ? "Switch to \(space.name)" : "Switch to Tab"))
                if results.count >= 4 { break }
            }
            if results.count >= 4 { break }
        }

        let seen = Set(results.compactMap { r -> String? in
            if case .tab(let t) = r.kind { return t.url?.absoluteString }
            return nil
        })
        for entry in app.searchHistory(text, limit: 8) where !seen.contains(entry.url.absoluteString) {
            results.append(
                Result(
                    id: "h" + entry.url.absoluteString, kind: .history(entry),
                    title: entry.title.isEmpty ? URLGuess.displayHost(entry.url) : entry.title,
                    subtitle: entry.url.absoluteString.replacingOccurrences(of: "https://", with: ""),
                    icon: Favicons.shared.cached(for: entry.url), symbol: "clock", trailing: nil))
            if results.count >= 8 { break }
        }
        return results
    }

    private func open(_ result: Result?, forceNewTab: Bool) {
        guard let result else { return }
        let newTab = browser.commandBar.opensNewTab || forceNewTab
        switch result.kind {
        case .go(let url), .search(let url):
            newTab ? _ = browser.openTab(url, after: browser.selectedTab) : browser.selectedTab?.load(url)
        case .tab(let tab):
            browser.select(tab)
        case .favorite(let favorite):
            browser.open(favorite)
        case .history(let entry):
            newTab ? _ = browser.openTab(entry.url, after: browser.selectedTab) : browser.selectedTab?.load(entry.url)
        }
        dismiss()
    }

    private func dismiss() {
        browser.commandBar.isPresented = false
        browser.commandBar.text = ""
    }
}

private struct SuggestionRow: View {
    let result: CommandBar.Result
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = result.icon {
                    SiteIcon(image: icon, size: 18)
                } else {
                    Image(systemName: result.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(highlighted ? Color.white : Color.secondary)
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                Text(result.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(highlighted ? Color.white.opacity(0.75) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let trailing = result.trailing {
                Text(trailing)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(highlighted ? Color.white.opacity(0.8) : Color.secondary.opacity(0.7))
            }
        }
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(highlighted ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.clear))
        }
        .contentShape(Rectangle())
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
