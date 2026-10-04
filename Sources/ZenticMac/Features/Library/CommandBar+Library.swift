import SwiftUI
import ZenticKit

/// History, Downloads and Bookmarks, reachable by name from ⌘T and ⌘L.
enum LibraryPanel: String, CaseIterable {
    case history, downloads, bookmarks

    var title: String {
        switch self {
        case .history: "Show All History"
        case .downloads: "Show Downloads"
        case .bookmarks: "Show Bookmarks"
        }
    }

    var symbol: String {
        switch self {
        case .history: "clock"
        case .downloads: "arrow.down.circle"
        case .bookmarks: "book"
        }
    }

    var shortcut: String {
        switch self {
        case .history: "⌘Y"
        case .downloads: "⌥⌘L"
        case .bookmarks: "⌥⌘B"
        }
    }

    @MainActor func show(in browser: Browser, openWindow: OpenWindowAction) {
        switch self {
        case .history: openWindow(id: HistoryWindow.id)
        case .downloads: Downloads.shared.presentedIn = browser.id
        case .bookmarks: openWindow(id: BookmarksWindow.id)
        }
    }
}

extension CommandBar {
    /// Bookmarks matching what was typed — only while bookmarks are shown.
    @MainActor static func bookmarkResults(for query: String, app: AppModel, limit: Int) -> [Result] {
        guard app.showsBookmarks, limit > 0 else { return [] }
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        return BookmarkStore.shared.list.all.lazy
            .filter { bookmark in
                let title = bookmark.title.lowercased()
                let url = bookmark.url?.absoluteString.lowercased() ?? ""
                return words.allSatisfy { title.contains($0) || url.contains($0) }
            }
            .prefix(limit)
            .map { bookmark in
                Result(
                    id: "b" + bookmark.id.uuidString, kind: .bookmark(bookmark), title: bookmark.title,
                    subtitle: URLGuess.displayHost(bookmark.url), icon: Favicons.shared.cached(for: bookmark.url),
                    symbol: "book", trailing: "Bookmark")
            }
    }

    /// "hist", "downl", "bookm" — the panel, by the start of its name.
    @MainActor static func panelResults(for query: String, app: AppModel) -> [Result] {
        let q = query.lowercased()
        guard q.count >= 3 else { return [] }
        return LibraryPanel.allCases
            .filter { $0 != .bookmarks || app.showsBookmarks }
            .filter { $0.rawValue.hasPrefix(q) || $0.title.lowercased().hasPrefix(q) }
            .map {
                Result(
                    id: "p" + $0.rawValue, kind: .panel($0), title: $0.title, subtitle: "Zentic",
                    icon: nil, symbol: $0.symbol, trailing: $0.shortcut)
            }
    }
}
