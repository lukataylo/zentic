import SwiftUI
import ZenticKit

/// ⌥⌘B: the bookmarks, in folders one level deep. Drag to reorder, double-
/// click to open, Return or the context menu to rename.
struct BookmarksWindow: View {
    static let id = "bookmarks"

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    private let store = BookmarkStore.shared
    @State private var selection: Set<UUID> = []
    @State private var expanded: Set<UUID> = []
    @State private var renaming: UUID?

    var body: some View {
        content
            .frame(minWidth: 420, minHeight: 360)
            .navigationTitle("Bookmarks")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("New Folder", systemImage: "folder.badge.plus") { newFolder() }
                        .help("New Folder")
                    Button("Import…", systemImage: "square.and.arrow.down") { BookmarkStore.importFile() }
                        .help("Import bookmarks exported from Safari, Chrome, Firefox or Edge")
                }
            }
            // Turning bookmarks off in Settings takes them off the screen too.
            .onChange(of: app.showsBookmarks) { _, shown in if !shown { dismiss() } }
    }

    @ViewBuilder
    private var content: some View {
        if !store.isLoaded {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.list.items.isEmpty {
            ContentUnavailableView {
                Label("No Bookmarks", systemImage: "book")
            } description: {
                Text("Press ⇧⌘D to bookmark the page you’re on, or bring your bookmarks over from another browser.")
            } actions: {
                Button("Import Bookmarks…") { BookmarkStore.importFile() }
            }
        } else {
            List(selection: $selection) {
                ForEach(store.list.items) { item in
                    if item.isFolder {
                        DisclosureGroup(isExpanded: expansion(of: item.id)) {
                            ForEach(item.children) { child in
                                row(child)
                            }
                            .onMove { source, destination in
                                store.change { $0.move(fromOffsets: source, toOffset: destination, in: item.id) }
                            }
                        } label: {
                            row(item)
                        }
                    } else {
                        row(item)
                    }
                }
                .onMove { source, destination in
                    store.change { $0.move(fromOffsets: source, toOffset: destination) }
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: UUID.self) { ids in
                menu(for: ids)
            } primaryAction: { ids in
                open(ids, newTab: ids.count > 1)
            }
            .onKeyPress(.return, phases: .down) { press in
                // Return renames, as in the Finder; ⌘Return opens in new tabs.
                if press.modifiers.contains(.command) {
                    open(selection, newTab: true)
                    return .handled
                }
                guard renaming == nil, selection.count == 1 else { return .ignored }
                renaming = selection.first
                return .handled
            }
            .onDeleteCommand { delete(selection) }
        }
    }

    private func row(_ item: Bookmark) -> some View {
        BookmarkRow(
            item: item, count: item.children.count,
            isRenaming: Binding(
                get: { renaming == item.id },
                set: { if !$0, renaming == item.id { renaming = nil } }),
            rename: { title in store.change { $0.rename(item.id, to: title) } }
        )
        .tag(item.id)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func menu(for ids: Set<UUID>) -> some View {
        let items = ids.compactMap(store.list.item)
        let bookmarks = items.filter { !$0.isFolder }
        if !bookmarks.isEmpty {
            Button(bookmarks.count == 1 ? "Open" : "Open \(bookmarks.count) Bookmarks in New Tabs") {
                open(ids, newTab: bookmarks.count > 1)
            }
            if bookmarks.count == 1 {
                Button("Open in New Tab") { open(ids, newTab: true) }
            }
            Divider()
        }
        if items.count == 1, let item = items.first {
            Button("Rename") { renaming = item.id }
            if let url = item.url {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
        }
        if !bookmarks.isEmpty {
            Menu("Move To") {
                Button("Bookmarks") { move(bookmarks, into: nil) }
                let folders = store.list.folders
                if !folders.isEmpty { Divider() }
                ForEach(folders) { folder in
                    Button(folder.title) { move(bookmarks, into: folder.id) }
                }
            }
        }
        if !items.isEmpty {
            Divider()
            Button("Delete", role: .destructive) { delete(ids) }
        }
    }

    private func expansion(of id: UUID) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    /// Bookmarks in the order shown; a folder double-clicked opens or closes.
    private func open(_ ids: Set<UUID>, newTab: Bool) {
        if ids.count == 1, let id = ids.first, store.list.item(id)?.isFolder == true {
            withAnimation(.smooth(duration: 0.25)) { expansion(of: id).wrappedValue.toggle() }
            return
        }
        for bookmark in store.list.all where ids.contains(bookmark.id) {
            if let url = bookmark.url { Windows.shared.open(url, inNewTab: newTab) }
        }
    }

    private func move(_ bookmarks: [Bookmark], into folder: UUID?) {
        withAnimation(.smooth(duration: 0.25)) {
            store.change { list in bookmarks.forEach { list.move($0.id, into: folder) } }
            if let folder { expanded.insert(folder) }
        }
    }

    private func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        withAnimation(.smooth(duration: 0.25)) { store.change { $0.remove(ids) } }
        selection.subtract(ids)
    }

    private func newFolder() {
        var id: UUID?
        store.change { id = $0.addFolder("New Folder") }
        guard let id else { return }
        selection = [id]
        renaming = id
    }
}

private struct BookmarkRow: View {
    let item: Bookmark
    let count: Int
    @Binding var isRenaming: Bool
    var rename: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 9) {
            if item.isFolder {
                Image(systemName: "folder.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor.gradient)
                    .frame(width: 16)
            } else {
                SiteIcon(image: Favicons.shared.cached(for: item.url), size: 16)
            }
            if isRenaming {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onAppear {
                        draft = item.title
                        focused = true
                    }
                    .onSubmit {
                        rename(draft)
                        isRenaming = false
                    }
                    .onExitCommand { isRenaming = false }
                    .onChange(of: focused) { _, now in
                        // Clicking away keeps what was typed, as in the Finder.
                        if !now, isRenaming {
                            rename(draft)
                            isRenaming = false
                        }
                    }
            } else {
                Text(item.title).lineLimit(1)
                if let url = item.url {
                    Text(URLGuess.displayHost(url))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if item.isFolder {
                Text(count.formatted())
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(count == 1 ? "1 bookmark" : "\(count) bookmarks")
            }
        }
        .padding(.vertical, 2)
        .help(item.url?.absoluteString ?? "")
        .accessibilityElement(children: isRenaming ? .contain : .combine)
        .accessibilityAddTraits(item.isFolder ? [] : .isLink)
    }
}
