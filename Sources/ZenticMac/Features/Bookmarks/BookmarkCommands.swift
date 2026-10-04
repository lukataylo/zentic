import SwiftUI
import ZenticKit

/// The Bookmarks menu — there only while Settings › General › Show Bookmarks
/// is on.
struct BookmarkCommands: Commands {
    @FocusedValue(Browser.self) private var browser
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        if AppModel.shared.showsBookmarks {
            CommandMenu("Bookmarks") {
                let tab = browser?.selectedTab
                Button("Add Bookmark…") {
                    if let tab, let url = tab.url { AddBookmarkAlert.run(url: url, title: tab.title) }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                // A private window keeps nothing — bookmarks included.
                .disabled(!SiteKey.isWeb(tab?.url) || browser?.isPrivate == true)
                Button("Show Bookmarks") { openWindow(id: BookmarksWindow.id) }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                Divider()
                BookmarkMenuItems()
                Button("Import Bookmarks…") {
                    BookmarkStore.importFile { openWindow(id: BookmarksWindow.id) }
                }
            }
        }
    }
}

/// The bookmarks themselves, as Safari lists them in its menu: folders as
/// submenus. Capped, because the menu is rebuilt whenever focus moves, and
/// an imported thousand would make that show — the window holds them all.
private struct BookmarkMenuItems: View {
    private static let limit = 40
    private let store = BookmarkStore.shared

    var body: some View {
        let items = store.list.items
        if !items.isEmpty {
            ForEach(items.prefix(Self.limit)) { item in
                if item.isFolder {
                    Menu(item.title) {
                        ForEach(item.children.prefix(Self.limit)) { child in link(child) }
                    }
                } else {
                    link(item)
                }
            }
            Divider()
        }
    }

    private func link(_ bookmark: Bookmark) -> some View {
        Button(bookmark.title.count > 60 ? bookmark.title.prefix(59) + "…" : bookmark.title) {
            if let url = bookmark.url { Windows.shared.open(url, inNewTab: false) }
        }
    }
}
