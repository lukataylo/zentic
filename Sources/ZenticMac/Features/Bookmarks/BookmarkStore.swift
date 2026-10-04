import AppKit
import Observation
import UniformTypeIdentifiers
import ZenticKit

/// The user's bookmarks, saved as they change.
///
/// Made on first use, and nothing uses it while bookmarks are hidden: with
/// the setting off, Zentic never reads the file.
@MainActor
@Observable
final class BookmarkStore {
    static let shared = BookmarkStore()

    private(set) var list = BookmarkList()
    private(set) var isLoaded = false
    @ObservationIgnored private var loading: Task<Void, Never>?

    @ObservationIgnored private let file = JSONFile<BookmarkList>(name: "bookmarks.json")
    @ObservationIgnored private let io = DispatchQueue(label: "Zentic.bookmarks", qos: .utility)

    private init() {
        let file = self.file
        loading = Task {
            list = await Task.detached(priority: .userInitiated) { file.load() ?? BookmarkList() }.value
            isLoaded = true
        }
    }

    /// Edits wait for the file: saving before it was read would replace it.
    func change(_ edit: @escaping (inout BookmarkList) -> Void) {
        guard isLoaded else {
            Task { await loading?.value; change(edit) }
            return
        }
        edit(&list)
        let (file, snapshot) = (self.file, list)
        io.async { file.save(snapshot) }
    }

    // MARK: - Import

    /// Choose an exported bookmarks file and add what is new in it.
    static func importFile(then showBookmarks: @escaping @MainActor () -> Void = {}) {
        let panel = NSOpenPanel()
        panel.message = "Choose a bookmarks file exported from Safari, Chrome, Firefox or Edge."
        panel.prompt = "Import"
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        let chosen: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await shared.importBookmarks(from: url, then: showBookmarks) }
        }
        if let window = NSApp.keyWindow, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: chosen)
        } else {
            chosen(panel.runModal())
        }
    }

    private func importBookmarks(from url: URL, then showBookmarks: @MainActor () -> Void) async {
        // Read and parsed off the main thread: an export can be megabytes.
        let parsed = await Task.detached(priority: .userInitiated) { () -> [Bookmark]? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            // Exports declare UTF-8; a file that is not is most likely Latin-1.
            let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            return BookmarkImport.parse(html)
        }.value
        await loading?.value

        let alert = NSAlert()
        if let parsed {
            var added = 0
            change { added = $0.merge(parsed) }
            let found = parsed.flatMap { $0.isFolder ? $0.children : [$0] }.count
            switch (found, added) {
            case (0, _):
                alert.messageText = "No bookmarks found"
                alert.informativeText = "“\(url.lastPathComponent)” doesn’t look like a bookmarks file. In Safari choose File › Export › Bookmarks; in Chrome, Bookmark Manager › Export Bookmarks."
            case (_, 0):
                alert.messageText = "Already up to date"
                alert.informativeText = "Every bookmark in “\(url.lastPathComponent)” is already in Zentic."
            default:
                alert.messageText = added == 1 ? "Imported 1 bookmark" : "Imported \(added.formatted()) bookmarks"
                let skipped = found - added
                alert.informativeText =
                    skipped > 0
                    ? "\(skipped.formatted()) you already had were left out." : "From “\(url.lastPathComponent)”."
            }
        } else {
            alert.messageText = "Couldn’t read the file"
            alert.informativeText = "“\(url.lastPathComponent)” couldn’t be opened."
        }
        if let window = NSApp.keyWindow, window.attachedSheet == nil {
            await alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
        if parsed?.isEmpty == false { showBookmarks() }
    }
}

/// Bookmarks › Add Bookmark…: name it and choose where it goes.
@MainActor
enum AddBookmarkAlert {
    static func run(url: URL, title: String) {
        let store = BookmarkStore.shared
        let alert = NSAlert()
        alert.messageText = "Add Bookmark"
        alert.informativeText =
            store.list.contains(url)
            ? "This page is already bookmarked. Add it again?" : URLGuess.displayHost(url)

        let name = NSTextField(string: title.isEmpty ? URLGuess.displayHost(url) : title)
        name.placeholderString = "Title"
        name.lineBreakMode = .byTruncatingTail
        name.setAccessibilityLabel("Title")
        let folder = NSPopUpButton(frame: .zero, pullsDown: false)
        folder.addItem(withTitle: "Bookmarks")
        folder.lastItem?.image = NSImage(systemSymbolName: "book", accessibilityDescription: nil)
        let folders = store.list.folders
        if !folders.isEmpty { folder.menu?.addItem(.separator()) }
        for item in folders {
            folder.addItem(withTitle: item.title)
            folder.lastItem?.representedObject = item.id
            folder.lastItem?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        }
        if let last = DataDirectory.defaults.string(forKey: lastFolderKey).flatMap(UUID.init),
            let index = folder.itemArray.firstIndex(where: { $0.representedObject as? UUID == last })
        {
            folder.selectItem(at: index)
        }
        folder.setAccessibilityLabel("Folder")

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Title:"), name],
            [NSTextField(labelWithString: "Folder:"), folder],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 300, height: 58)
        name.widthAnchor.constraint(equalToConstant: 230).isActive = true
        alert.accessoryView = grid
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let chosen = folder.selectedItem?.representedObject as? UUID
            DataDirectory.defaults.set(chosen?.uuidString, forKey: lastFolderKey)
            let typed = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            store.change { $0.add(url, title: typed.isEmpty ? URLGuess.displayHost(url) : typed, in: chosen) }
        }
        if let window = NSApp.keyWindow, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private static let lastFolderKey = "bookmarkFolder"
}
