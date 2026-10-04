import AppKit
import SwiftUI
import ZenticKit

/// ⌘Y: everything visited, by day, searchable. Opens pages in the browser
/// window in front.
struct HistoryWindow: View {
    static let id = "history"

    @Environment(AppModel.self) private var app
    @State private var query = ""
    /// Regrouped when history or the search changes — not on every redraw,
    /// which selection and hover cause.
    @State private var days: [HistoryDay] = []
    @State private var selection: Set<URL> = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        content
            .frame(minWidth: 520, minHeight: 360)
            .navigationTitle("History")
            .searchable(text: $query, placement: .toolbar, prompt: "Search History")
            .searchFocused($searchFocused)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear History…", systemImage: "trash") { ClearHistoryAlert.run() }
                        .help("Clear the last hour, today, or all history")
                        .disabled(!app.historyLoaded || app.historyEntries.isEmpty)
                }
            }
            .focusedSceneValue(\.historySearch, HistorySearch { searchFocused = true })
            .onChange(of: app.historyRevision, initial: true) { regroup() }
            .onChange(of: query) { regroup() }
    }

    @ViewBuilder
    private var content: some View {
        if !app.historyLoaded {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if days.isEmpty {
            if query.isEmpty {
                ContentUnavailableView {
                    Label("No History", systemImage: "clock")
                } description: {
                    Text("Pages you visit appear here, by day. Private windows are never recorded.")
                }
            } else {
                ContentUnavailableView.search(text: query)
            }
        } else {
            List(selection: $selection) {
                ForEach(days) { day in
                    Section {
                        ForEach(day.entries, id: \.url) { entry in
                            HistoryRow(entry: entry).tag(entry.url).listRowSeparator(.hidden)
                        }
                    } header: {
                        DayHeader(day: day) { delete(day.entries.map(\.url)) }
                    }
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: URL.self) { urls in
                menu(for: urls)
            } primaryAction: { urls in
                open(urls, newTab: urls.count > 1)
            }
            .onKeyPress(.return, phases: .down) { press in
                // Return is the primary action; ⌘Return opens in new tabs.
                guard press.modifiers.contains(.command), !selection.isEmpty else { return .ignored }
                open(selection, newTab: true)
                return .handled
            }
            .onDeleteCommand { delete(selection) }
        }
    }

    @ViewBuilder
    private func menu(for urls: Set<URL>) -> some View {
        if !urls.isEmpty {
            Button(urls.count == 1 ? "Open" : "Open \(urls.count) Pages in New Tabs") { open(urls, newTab: urls.count > 1) }
            if urls.count == 1 {
                Button("Open in New Tab") { open(urls, newTab: true) }
            }
            Divider()
            Button(urls.count == 1 ? "Copy Link" : "Copy Links") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sorted(urls).map(\.absoluteString).joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button(urls.count == 1 ? "Delete" : "Delete \(urls.count) Pages", role: .destructive) { delete(urls) }
        }
    }

    private func regroup() {
        days = HistoryDay.group(app.historyEntries, matching: query, calendar: .current)
        // Deleted, or filtered out of sight: a hidden selection would be
        // deleted by the next ⌫ without the user seeing what.
        let visible = Set(days.flatMap { $0.entries.map(\.url) })
        selection.formIntersection(visible)
    }

    /// In the order shown, so new tabs open the way the list reads.
    private func sorted(_ urls: Set<URL>) -> [URL] {
        days.flatMap(\.entries).map(\.url).filter(urls.contains)
    }

    private func open(_ urls: Set<URL>, newTab: Bool) {
        for url in sorted(urls) { Windows.shared.open(url, inNewTab: newTab) }
    }

    private func delete(_ urls: some Collection<URL>) {
        guard !urls.isEmpty else { return }
        withAnimation(.smooth(duration: 0.25)) { app.removeHistory(urls) }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            SiteIcon(image: Favicons.shared.cached(for: entry.url), size: 16)
            Text(entry.title.isEmpty ? URLGuess.displayHost(entry.url) : entry.title)
                .lineLimit(1)
                .layoutPriority(1)
            Text(URLGuess.displayHost(entry.url))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(entry.lastVisit, format: .dateTime.hour().minute())
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .help(entry.url.absoluteString)
        .accessibilityElement(children: .combine)
    }
}

/// "Today", "Yesterday", or the date, with the day's count — and a way to
/// delete the whole day, shown on hover and always offered to VoiceOver.
private struct DayHeader: View {
    let day: HistoryDay
    var delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Text(day.entries.count.formatted())
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .opacity(hovering ? 1 : 0)
                .help("Delete every visit from \(title)")
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contextMenu {
            Button("Delete All from \(title)", role: .destructive, action: delete)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(day.entries.count) pages")
        .accessibilityAddTraits(.isHeader)
        .accessibilityAction(named: "Delete All from \(title)", delete)
    }

    private var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day.day) { return "Today" }
        if calendar.isDateInYesterday(day.day) { return "Yesterday" }
        let sameYear = calendar.isDate(day.day, equalTo: .now, toGranularity: .year)
        return sameYear
            ? day.day.formatted(.dateTime.weekday(.wide).day().month(.wide))
            : day.day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}

/// ⌘F in the History window: the Find command focuses the search field.
struct HistorySearch {
    var focus: () -> Void
}

extension FocusedValues {
    @Entry var historySearch: HistorySearch?
}

/// History › Clear History…: Safari's alert, with its choice of span.
@MainActor
enum ClearHistoryAlert {
    private static let rangeKey = "clearHistoryRange"

    static func run() {
        let defaults = DataDirectory.defaults
        let alert = NSAlert()
        alert.messageText = "Clear History"
        alert.informativeText =
            "Removes the pages you visited from History and from the address bar’s suggestions, and the icons kept for their sites. Cookies, website data, open tabs and favourites are kept."
        alert.alertStyle = .warning

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for range in HistoryRange.allCases {
            popup.addItem(withTitle: range.title)
            popup.lastItem?.representedObject = range.rawValue
        }
        let remembered = defaults.string(forKey: rangeKey).flatMap(HistoryRange.init) ?? .today
        popup.selectItem(at: HistoryRange.allCases.firstIndex(of: remembered) ?? 1)
        popup.setAccessibilityLabel("Clear")
        let label = NSTextField(labelWithString: "Clear:")
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        row.frame = NSRect(x: 0, y: 0, width: 260, height: 26)
        alert.accessoryView = row

        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn,
                let raw = popup.selectedItem?.representedObject as? String, let range = HistoryRange(rawValue: raw)
            else { return }
            defaults.set(range.rawValue, forKey: rangeKey)
            AppModel.shared.clearHistory(range)
        }
        if let window = NSApp.keyWindow, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
