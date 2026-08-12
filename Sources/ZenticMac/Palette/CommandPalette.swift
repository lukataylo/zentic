import AppKit
import ZenticKit

/// One thing the palette can do.
enum PaletteItem {
    case tab(id: UUID, title: String, subtitle: String)
    case history(url: URL, title: String)
    case space(id: UUID, title: String)
    case action(PaletteAction)
    /// Whatever the user typed, treated as a URL or a search.
    case open(text: String, url: URL)

    var title: String {
        switch self {
        case .tab(_, let title, _): title
        case .history(let url, let title): title.isEmpty ? url.absoluteString : title
        case .space(_, let title): "Switch to \(title)"
        case .action(let action): action.title
        case .open(let text, let url): url.host() == nil ? "Search for “\(text)”" : text
        }
    }

    var subtitle: String {
        switch self {
        case .tab(_, _, let subtitle): subtitle
        case .history(let url, _): url.host() ?? url.absoluteString
        case .space: "Space"
        case .action: "Action"
        case .open(_, let url): url.absoluteString
        }
    }

    var symbolName: String {
        switch self {
        case .tab: "square.on.square"
        case .history: "clock"
        case .space: "rectangle.3.group"
        case .action(let action): action.symbolName
        case .open(_, let url): url.host() == nil ? "magnifyingglass" : "arrow.up.right"
        }
    }

    /// Text the query is scored against — title plus subtitle, so "gh" finds a tab
    /// titled "Pull requests" on github.com.
    var searchText: String { "\(title) \(subtitle)" }
}

enum PaletteAction: CaseIterable {
    case newTab
    case closeTab
    case reload
    case toggleOriginal
    case toggleFocusMode
    case toggleSidebar
    case findInPage
    case nextTab
    case previousTab
    case newSpace
    case clearHistory

    var title: String {
        switch self {
        case .newTab: "New Tab"
        case .closeTab: "Close Tab"
        case .reload: "Reload Page"
        case .toggleOriginal: "Toggle Original Page"
        case .toggleFocusMode: "Toggle Focus Mode"
        case .toggleSidebar: "Toggle Sidebar"
        case .findInPage: "Find in Page"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .newSpace: "New Space"
        case .clearHistory: "Clear History"
        }
    }

    var symbolName: String {
        switch self {
        case .newTab: "plus.square"
        case .closeTab: "xmark.square"
        case .reload: "arrow.clockwise"
        case .toggleOriginal: "doc.plaintext"
        case .toggleFocusMode: "rectangle.inset.filled"
        case .toggleSidebar: "sidebar.left"
        case .findInPage: "magnifyingglass"
        case .nextTab: "chevron.down.square"
        case .previousTab: "chevron.up.square"
        case .newSpace: "rectangle.badge.plus"
        case .clearHistory: "trash"
        }
    }
}

/// A panel that can take keyboard focus without a title bar.
///
/// `NSPanel` rather than `NSWindow` so it floats over the browser and does not
/// appear in the window menu; `canBecomeKey` overridden because a borderless window
/// refuses key status by default, which would leave the search field untypable.
final class CommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
protocol CommandPaletteDelegate: AnyObject {
    /// Candidate items for the current query. The palette scores and orders them.
    func paletteItems(for query: String) -> [PaletteItem]
    func palette(didChoose item: PaletteItem)
}

/// ⌘K. Fuzzy search over open tabs, history, spaces and actions.
@MainActor
final class CommandPalette: NSObject {
    weak var delegate: (any CommandPaletteDelegate)?

    private var panel: CommandPalettePanel?
    private let field = NSTextField()
    private let tableView = NSTableView()
    private var results: [PaletteItem] = []
    private weak var host: NSWindow?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(over window: NSWindow) {
        if isVisible {
            dismiss()
        } else {
            present(over: window)
        }
    }

    func present(over window: NSWindow) {
        host = window
        let panel = self.panel ?? buildPanel()
        self.panel = panel

        // Centred horizontally, a third of the way down — the position everyone
        // from Spotlight to Raycast uses, so it lands where the eye already is.
        let frame = window.frame
        let size = NSSize(width: min(620, frame.width - 80), height: 380)
        panel.setFrame(
            NSRect(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height - frame.height * 0.18,
                width: size.width,
                height: size.height
            ),
            display: false
        )

        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        field.stringValue = ""
        refresh()
        panel.makeFirstResponder(field)
    }

    func dismiss() {
        guard let panel else { return }
        host?.removeChildWindow(panel)
        panel.orderOut(nil)
        host?.makeKeyAndOrderFront(nil)
    }

    private func buildPanel() -> CommandPalettePanel {
        let panel = CommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true

        field.font = .systemFont(ofSize: 18, weight: .regular)
        field.placeholderString = "Search tabs, history, or type a URL"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.target = self
        field.action = #selector(commit)
        field.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        tableView.headerView = nil
        tableView.rowHeight = 38
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(commit)
        tableView.addTableColumn(NSTableColumn(identifier: .init("main")))

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(field)
        background.addSubview(separator)
        background.addSubview(scrollView)

        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
            field.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),

            separator.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: background.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        panel.contentView = background
        return panel
    }

    // MARK: - Results

    private func refresh() {
        let query = field.stringValue
        let candidates = delegate?.paletteItems(for: query) ?? []

        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            // No query: show the candidate order the delegate supplied (open tabs
            // first, then recent history) rather than a meaningless zero-score sort.
            results = Array(candidates.prefix(40))
        } else {
            results =
                candidates
                .compactMap { item -> (PaletteItem, Int)? in
                    guard let match = FuzzyMatcher.match(query, in: item.searchText) else {
                        return nil
                    }
                    return (item, match.score)
                }
                // Stable within a score band, so the delegate's own ordering
                // (recency) breaks ties instead of the sort's arbitrary choice.
                .enumerated()
                .sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }
                .prefix(40)
                .map(\.element.0)
        }

        tableView.reloadData()
        if !results.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    @objc private func commit() {
        let row = tableView.selectedRow
        guard results.indices.contains(row) else { return }
        let item = results[row]
        dismiss()
        delegate?.palette(didChoose: item)
    }

    private func move(by offset: Int) {
        guard !results.isEmpty else { return }
        let next = (tableView.selectedRow + offset).clamped(to: 0...(results.count - 1))
        tableView.selectRowIndexes([next], byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }
}

extension CommandPalette: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        refresh()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        // Arrow keys have to be intercepted here: the field is first responder (so
        // typing works), which means it, not the table, receives them.
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            move(by: -1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        default:
            return false
        }
    }
}

extension CommandPalette: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let item = results[row]
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail

        let subtitle = NSTextField(labelWithString: item.subtitle)
        subtitle.font = .systemFont(ofSize: 10.5)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle

        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        text.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(icon)
        container.addSubview(text)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            text.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
