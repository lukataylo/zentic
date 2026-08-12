import AppKit
import ZenticKit

@MainActor
protocol SidebarViewDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarView, didSelectTab id: UUID)
    func sidebar(_ sidebar: SidebarView, didRequestCloseTab id: UUID)
    func sidebar(_ sidebar: SidebarView, didToggleGroup id: UUID)
    func sidebar(_ sidebar: SidebarView, didToggleFolder id: UUID)
    func sidebar(_ sidebar: SidebarView, didOpenBookmark urlString: String)
    func sidebar(_ sidebar: SidebarView, didSelectSpace id: UUID)
    func sidebar(_ sidebar: SidebarView, didRequestUnpinTab id: UUID)
    func sidebarDidRequestNewTab(_ sidebar: SidebarView)
}

/// Everything the sidebar needs to draw itself, flattened out of SwiftData.
///
/// The view is rebuilt from one of these rather than observing model objects: with
/// pins, folders, groups and a flat list interleaved in a fixed order, a
/// diff-and-patch design would be far more code than rebuilding thirty small
/// views, and correctness here is more valuable than the microseconds.
struct SidebarModel {
    struct SpaceChip {
        var id: UUID
        var title: String
        var symbolName: String
        var tint: NSColor
    }

    struct TabItem {
        var id: UUID
        var title: String
        var icon: NSImage?
        /// What the user would see on this tab: Zentic's rendering, the site's own
        /// page, or a rewrite. Shown as a small glyph on the row, because with
        /// twenty tabs open "is this one transformed?" is otherwise a question you
        /// can only answer by switching to it.
        var transform: TabTransformState = .original
    }

    /// The per-tab reader indicator.
    enum TabTransformState: Equatable {
        /// The site's own page — either not restructured, or toggled back.
        case original
        /// Zentic's reading view.
        case transformed
        /// Zentic's reading view, with model-rewritten prose.
        case rewritten
        case rewriting

        var symbolName: String? {
            switch self {
            case .original: nil
            case .transformed: "textformat"
            case .rewritten: "wand.and.stars"
            case .rewriting: "wand.and.stars.inverse"
            }
        }

        var tip: String {
            switch self {
            case .original: "Showing the site's own page"
            case .transformed: "Showing Zentic's transformed page"
            case .rewritten: "Rewritten by a model"
            case .rewriting: "Rewriting…"
            }
        }
    }

    struct GroupItem {
        var id: UUID
        var title: String
        var isExpanded: Bool
        var tabs: [TabItem]
    }

    struct FolderItem {
        var id: UUID
        var title: String
        var isExpanded: Bool
        var bookmarks: [Bookmark]
    }

    var spaces: [SpaceChip] = []
    var activeSpaceID: UUID?
    var pinned: [PinnedGridView.Entry] = []
    var folders: [FolderItem] = []
    var tabs: [TabItem] = []
    var groups: [GroupItem] = []
    var selectedTabID: UUID?
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The Arc-style sidebar: pinned grid, folders, `+ New Tab`, the live tab list,
/// one level of tab groups, and the space switcher.
final class SidebarView: PointerTrackingView {
    weak var delegate: (any SidebarViewDelegate)?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let pinnedGrid = PinnedGridView()
    private let spaceSwitcher = NSStackView()

    /// Rows keyed by tab id, so a title or favicon arriving late is a targeted
    /// update rather than a full rebuild that would drop the user's scroll position.
    private var tabRows: [UUID: SidebarRowView] = [:]
    private var spaceTargets: [ClosureTarget] = []
    private var model = SidebarModel()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildLayout()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildLayout() {
        // Traffic lights live at the window's top-left, i.e. on top of this view.
        // Content therefore starts below them.
        let topInset = NSView()
        topInset.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        // `.width` makes every row span the sidebar, which is what lets a selected
        // row's pill be inset from both edges by a fixed amount.
        stack.alignment = .width
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = document
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        spaceSwitcher.orientation = .horizontal
        spaceSwitcher.spacing = 6
        spaceSwitcher.alignment = .centerY
        spaceSwitcher.translatesAutoresizingMaskIntoConstraints = false

        addSubview(topInset)
        addSubview(scrollView)
        addSubview(spaceSwitcher)

        NSLayoutConstraint.activate([
            topInset.topAnchor.constraint(equalTo: topAnchor),
            topInset.leadingAnchor.constraint(equalTo: leadingAnchor),
            topInset.trailingAnchor.constraint(equalTo: trailingAnchor),
            topInset.heightAnchor.constraint(equalToConstant: Chrome.trafficLightInset),

            scrollView.topAnchor.constraint(equalTo: topInset.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: spaceSwitcher.topAnchor, constant: -6),

            spaceSwitcher.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Chrome.sidebarHorizontalPadding
            ),
            spaceSwitcher.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -Chrome.sidebarHorizontalPadding
            ),
            spaceSwitcher.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            spaceSwitcher.heightAnchor.constraint(equalToConstant: 26),

            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    /// Drag the window by the sidebar's empty space.
    ///
    /// Replaces `isMovableByWindowBackground`, which had to go because it claimed
    /// mouse-downs on the toolbar's controls. Rows, the pinned grid and the space
    /// switcher all handle their own clicks, so a drag reaching this view is by
    /// definition on empty space — which is exactly the area that should move the
    /// window now that there is no title bar to grab.
    override func mouseDragged(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    // MARK: - Rendering

    func reload(_ model: SidebarModel) {
        self.model = model
        tabRows.removeAll()

        for view in stack.views { stack.removeView(view) }

        pinnedGrid.reload(model.pinned, selected: model.selectedTabID)
        if !model.pinned.isEmpty {
            stack.addView(pinnedGrid, in: .top)
            stack.addView(spacer(6), in: .top)
        }
        pinnedGrid.onSelect = { [weak self] id in
            guard let self else { return }
            delegate?.sidebar(self, didSelectTab: id)
        }
        pinnedGrid.onUnpin = { [weak self] id in
            guard let self else { return }
            delegate?.sidebar(self, didRequestUnpinTab: id)
        }

        for folder in model.folders {
            stack.addView(folderRow(folder), in: .top)
            guard folder.isExpanded else { continue }
            for bookmark in folder.bookmarks {
                stack.addView(bookmarkRow(bookmark), in: .top)
            }
        }

        if !model.folders.isEmpty || !model.pinned.isEmpty {
            stack.addView(SidebarDivider(), in: .top)
        }

        stack.addView(newTabRow(), in: .top)

        for item in model.tabs {
            stack.addView(tabRow(item, indent: 0), in: .top)
        }

        for group in model.groups {
            stack.addView(groupHeaderRow(group), in: .top)
            guard group.isExpanded else { continue }
            for item in group.tabs {
                stack.addView(tabRow(item, indent: Chrome.groupIndent), in: .top)
            }
        }

        stack.addView(spacer(12), in: .top)
        rebuildSpaceSwitcher()
    }

    /// Selection changed but nothing else did.
    func setSelectedTab(_ id: UUID?) {
        model.selectedTabID = id
        for (rowID, row) in tabRows { row.isSelected = rowID == id }
        pinnedGrid.setSelected(id)
    }

    /// A tab's reader state changed. Patched in place rather than triggering a
    /// rebuild: this fires on every reveal, and rebuilding the whole list for a
    /// one-glyph change is what made the sidebar quadratic in the first place.
    func updateTransform(id: UUID, state: SidebarModel.TabTransformState) {
        tabRows[id]?.setTransform(state)
    }

    func setContextMenu(for tabID: UUID, items: [(String, () -> Void)]) {
        tabRows[tabID]?.menuItems = items.map { (title: $0.0, action: $0.1) }
    }

    /// A title or favicon arrived for a tab already on screen.
    func updateTab(id: UUID, title: String, icon: NSImage?) {
        if let row = tabRows[id] {
            row.title = title
            row.icon = icon ?? Self.placeholderFavicon
            row.tintsIcon = icon == nil
        }
        pinnedGrid.updateIcon(icon, title: title, for: id)
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private static let placeholderFavicon = NSImage(
        systemSymbolName: "globe",
        accessibilityDescription: nil
    )

    private func tabRow(_ item: SidebarModel.TabItem, indent: CGFloat) -> SidebarRowView {
        let row = SidebarRowView(
            icon: item.icon ?? Self.placeholderFavicon,
            title: item.title,
            accessory: .close
        )
        row.tintsIcon = item.icon == nil
        row.indent = indent
        row.isSelected = item.id == model.selectedTabID
        row.setTransform(item.transform)
        row.toolTip = item.transform == .original
            ? item.title
            : "\(item.title) — \(item.transform.tip)"
        row.onClick = { [weak self] in
            guard let self else { return }
            delegate?.sidebar(self, didSelectTab: item.id)
        }
        row.onClose = { [weak self] in
            guard let self else { return }
            delegate?.sidebar(self, didRequestCloseTab: item.id)
        }
        tabRows[item.id] = row
        return row
    }

    private func groupHeaderRow(_ group: SidebarModel.GroupItem) -> SidebarRowView {
        let row = SidebarRowView(
            icon: NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil),
            title: group.title.uppercased(),
            accessory: .chevron(expanded: group.isExpanded)
        )
        row.onAccessory = { [weak self] in
            guard let self else { return }
            delegate?.sidebar(self, didToggleGroup: group.id)
        }
        row.onClick = row.onAccessory
        return row
    }

    private func folderRow(_ folder: SidebarModel.FolderItem) -> SidebarRowView {
        let row = SidebarRowView(
            icon: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil),
            title: folder.title,
            accessory: .chevron(expanded: folder.isExpanded)
        )
        row.onAccessory = { [weak self] in
            guard let self else { return }
            delegate?.sidebar(self, didToggleFolder: folder.id)
        }
        row.onClick = row.onAccessory
        return row
    }

    private func bookmarkRow(_ bookmark: Bookmark) -> SidebarRowView {
        let row = SidebarRowView(
            icon: NSImage(systemSymbolName: "link", accessibilityDescription: nil),
            title: bookmark.title
        )
        row.indent = Chrome.groupIndent
        row.onClick = { [weak self] in
            guard let self else { return }
            delegate?.sidebar(self, didOpenBookmark: bookmark.urlString)
        }
        return row
    }

    private func newTabRow() -> SidebarRowView {
        let row = SidebarRowView(
            icon: NSImage(systemSymbolName: "plus", accessibilityDescription: nil),
            title: "New Tab"
        )
        row.onClick = { [weak self] in
            guard let self else { return }
            delegate?.sidebarDidRequestNewTab(self)
        }
        return row
    }

    private func rebuildSpaceSwitcher() {
        for view in spaceSwitcher.views { spaceSwitcher.removeView(view) }
        spaceTargets.removeAll()
        for space in model.spaces {
            let button = NSButton()
            button.isBordered = false
            button.bezelStyle = .inline
            button.imagePosition = .imageOnly
            button.image = NSImage(systemSymbolName: space.symbolName, accessibilityDescription: space.title)
            button.contentTintColor = space.id == model.activeSpaceID ? .labelColor : .tertiaryLabelColor
            button.toolTip = space.title
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            // `NSButton.target` is weak, so the closure box needs an owner that
            // outlives the button. The sidebar is it.
            let target = ClosureTarget { [weak self] in
                guard let self else { return }
                delegate?.sidebar(self, didSelectSpace: space.id)
            }
            spaceTargets.append(target)
            button.target = target
            button.action = #selector(ClosureTarget.fire)
            spaceSwitcher.addView(button, in: .leading)
        }

        let label = NSTextField(
            labelWithString: model.spaces.first { $0.id == model.activeSpaceID }?.title ?? ""
        )
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        spaceSwitcher.addView(label, in: .leading)
    }
}

/// Boxes a closure as an ObjC target, for controls created in a loop.
@MainActor
final class ClosureTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func fire() { action() }
}
