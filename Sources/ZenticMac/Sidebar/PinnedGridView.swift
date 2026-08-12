import AppKit
import ZenticKit

/// The pinned-favicon grid at the top of the sidebar.
///
/// Icon-only tiles, four across. Pinned sites are the ones the user reaches for
/// without reading a label, so the row of names a normal tab list would show is
/// wasted vertical space.
final class PinnedGridView: ChromeView {
    struct Entry {
        var id: UUID
        var icon: NSImage?
        var title: String
    }

    var onSelect: ((UUID) -> Void)?
    var onUnpin: ((UUID) -> Void)?

    private var selectedID: UUID?
    private var tiles: [UUID: PinnedTile] = [:]
    private let grid = NSGridView()

    init() {
        super.init(frame: .zero)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = Chrome.pinGridSpacing
        grid.columnSpacing = Chrome.pinGridSpacing
        grid.xPlacement = .leading
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
            grid.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Chrome.sidebarHorizontalPadding
            ),
            grid.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -Chrome.sidebarHorizontalPadding
            ),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func reload(_ entries: [Entry], selected: UUID?) {
        selectedID = selected
        tiles.removeAll()

        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        while grid.numberOfColumns > 0 { grid.removeColumn(at: 0) }
        isHidden = entries.isEmpty
        guard !entries.isEmpty else { return }

        for _ in 0..<Chrome.pinColumns { grid.addColumn(with: []) }

        for chunkStart in stride(from: 0, to: entries.count, by: Chrome.pinColumns) {
            let chunk = entries[chunkStart..<min(chunkStart + Chrome.pinColumns, entries.count)]
            var views: [NSView] = chunk.map { entry in
                let tile = PinnedTile(entry: entry)
                tile.isSelected = entry.id == selected
                tile.onClick = { [weak self] in self?.onSelect?(entry.id) }
                tile.onUnpin = { [weak self] in self?.onUnpin?(entry.id) }
                tiles[entry.id] = tile
                return tile
            }
            // NSGridView needs every row the same width; a short last row gets
            // spacers rather than stretched tiles.
            while views.count < Chrome.pinColumns { views.append(NSGridCell.emptyContentView) }
            grid.addRow(with: views)
        }
    }

    func setSelected(_ id: UUID?) {
        guard id != selectedID else { return }
        selectedID = id
        for (tileID, tile) in tiles { tile.isSelected = tileID == id }
    }

    func updateIcon(_ icon: NSImage?, title: String, for id: UUID) {
        tiles[id]?.update(icon: icon, title: title)
    }
}

/// One rounded pinned tile.
final class PinnedTile: ChromeView {
    var onClick: (() -> Void)?
    var onUnpin: (() -> Void)?

    private let iconView = NSImageView()
    private let initialLabel = NSTextField(labelWithString: "")
    private var isHovered = false

    var isSelected = false {
        didSet { applyLayerColors() }
    }

    init(entry: PinnedGridView.Entry) {
        super.init(frame: .zero)
        layer?.cornerRadius = Chrome.pinRadius
        layer?.cornerCurve = .continuous

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // Fallback for a site with no favicon: its first letter, which is still
        // recognisable at a glance. A generic globe on eight tiles is not.
        initialLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        initialLabel.textColor = .secondaryLabelColor
        initialLabel.alignment = .center
        initialLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(initialLabel)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Chrome.pinTileSize),
            heightAnchor.constraint(equalToConstant: Chrome.pinTileSize),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            initialLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            initialLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        update(icon: entry.icon, title: entry.title)
        applyLayerColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(icon: NSImage?, title: String) {
        iconView.image = icon
        iconView.isHidden = icon == nil
        initialLabel.isHidden = icon != nil
        initialLabel.stringValue = title.first.map { String($0).uppercased() } ?? "?"
        toolTip = title
    }

    override func updateLayerColors() {
        guard let layer else { return }
        let dark = isDarkAppearance
        layer.borderWidth = Chrome.glassStrokeWidth
        layer.borderColor = Glass.stroke(dark: dark).cgColor
        if isSelected {
            layer.backgroundColor = Glass.raisedFill(dark: dark).cgColor
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.10
            layer.shadowRadius = 4
            layer.shadowOffset = CGSize(width: 0, height: -1)
        } else {
            layer.backgroundColor = Glass.hoverFill(dark: dark).cgColor
            layer.shadowOpacity = 0
            // Unhovered tiles keep a fainter edge, so the grid still reads as a grid
            // when nothing in it is selected. Scaled from the palette's alpha rather
            // than set to a constant: dark-mode strokes are already near-invisible,
            // and a fixed 0.45 would make them *brighter* than the hovered state.
            let edge = Glass.stroke(dark: dark)
            layer.borderColor = isHovered
                ? edge.cgColor
                : edge.withAlphaComponent(edge.alphaComponent * 0.45).cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyLayerColors()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyLayerColors()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Unpin", action: #selector(unpin), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func unpin() { onUnpin?() }
}
