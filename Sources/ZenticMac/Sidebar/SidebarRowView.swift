import AppKit

/// A sidebar row: icon, single-line truncated title, optional trailing button.
///
/// Hand-drawn rather than `NSTableCellView` because the selected state is the
/// signature of the design — a white pill inset from the sidebar edges with a
/// shadow under it — and table selection highlighting cannot be persuaded to look
/// like that without fighting it at every appearance change.
final class SidebarRowView: ChromeView {
    /// Rebuilt-view accounting. The sidebar recreates its rows wholesale on every
    /// change, which is only affordable if the old ones actually go away.
    nonisolated(unsafe) static var alive = 0
    nonisolated(unsafe) static var created = 0

    enum Accessory {
        case none
        /// Disclosure chevron; `expanded` picks the direction.
        case chevron(expanded: Bool)
        /// Close button, revealed on hover.
        case close
    }

    var onClick: (() -> Void)?
    var onAccessory: (() -> Void)?
    /// Middle-click, and ⌘W's per-row equivalent.
    var onClose: (() -> Void)?

    /// Right-click menu, as title/handler pairs. Built lazily on each click so the
    /// titles reflect current state ("Pin" vs "Unpin").
    var menuItems: [(title: String, action: () -> Void)] = []
    private var menuTargets: [ClosureTarget] = []

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let accessoryButton = NSButton()
    private let pill = ChromeView(frame: .zero)

    private var accessory: Accessory = .none
    private var isHovered = false
    private var trackingAreaAdded = false

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            applyLayerColors()
            needsDisplay = true
        }
    }

    /// Indent for a tab inside a group. One level only — see `TabGroup`.
    var indent: CGFloat = 0 {
        didSet { leadingConstraint?.constant = Chrome.sidebarHorizontalPadding + 6 + indent }
    }

    private var leadingConstraint: NSLayoutConstraint?

    init(icon: NSImage?, title: String, accessory: Accessory = .none) {
        super.init(frame: .zero)
        Self.alive += 1
        Self.created += 1
        self.accessory = accessory

        pill.wantsLayer = true
        pill.layer?.cornerRadius = Chrome.selectedRowRadius
        pill.layer?.cornerCurve = .continuous
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .secondaryLabelColor
        addSubview(iconView)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        accessoryButton.isBordered = false
        accessoryButton.bezelStyle = .inline
        accessoryButton.imagePosition = .imageOnly
        accessoryButton.target = self
        accessoryButton.action = #selector(accessoryPressed)
        accessoryButton.translatesAutoresizingMaskIntoConstraints = false
        accessoryButton.contentTintColor = .tertiaryLabelColor
        addSubview(accessoryButton)

        let leading = iconView.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: Chrome.sidebarHorizontalPadding + 6
        )
        leadingConstraint = leading

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Chrome.rowHeight),

            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.sidebarHorizontalPadding - 4),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Chrome.sidebarHorizontalPadding - 4)),
            pill.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            leading,
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Chrome.rowIconSize),
            iconView.heightAnchor.constraint(equalToConstant: Chrome.rowIconSize),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: accessoryButton.leadingAnchor,
                constant: -4
            ),

            accessoryButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -(Chrome.sidebarHorizontalPadding + 2)
            ),
            accessoryButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessoryButton.widthAnchor.constraint(equalToConstant: 16),
            accessoryButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        updateAccessoryImage()
        applyLayerColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }

    var icon: NSImage? {
        get { iconView.image }
        set { iconView.image = newValue }
    }

    /// Whether the icon should be tinted as a template (a glyph) or left alone (a
    /// favicon, which has its own colours).
    var tintsIcon = true {
        didSet { iconView.contentTintColor = tintsIcon ? .secondaryLabelColor : nil }
    }

    func setAccessory(_ accessory: Accessory) {
        self.accessory = accessory
        updateAccessoryImage()
    }

    private func updateAccessoryImage() {
        switch accessory {
        case .none:
            accessoryButton.isHidden = true
        case .chevron(let expanded):
            accessoryButton.isHidden = false
            accessoryButton.image = NSImage(
                systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                accessibilityDescription: expanded ? "Collapse" : "Expand"
            )
        case .close:
            // Only on hover: a permanent × on every row turns the sidebar into a
            // wall of buttons and steals width from the title.
            accessoryButton.isHidden = !isHovered
            accessoryButton.image = NSImage(
                systemSymbolName: "xmark",
                accessibilityDescription: "Close tab"
            )
        }
    }

    deinit { Self.alive -= 1 }

    override func updateLayerColors() {
        guard let layer = pill.layer else { return }
        let dark = isDarkAppearance
        if isSelected {
            // Glass rather than an opaque card: the pill is translucent over the
            // sidebar's blur, with a hairline edge doing the work the old solid fill
            // did. No `NSVisualEffectView` here — thirty rows would mean thirty blur
            // passes, and the blur behind is already the sidebar's.
            layer.backgroundColor = Glass.raisedFill(dark: dark).cgColor
            layer.borderWidth = Chrome.glassStrokeWidth
            layer.borderColor = Glass.stroke(dark: dark).cgColor
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.18
            layer.shadowRadius = 4
            layer.shadowOffset = CGSize(width: 0, height: -1)
            titleLabel.textColor = .labelColor
        } else if isHovered {
            layer.backgroundColor = Glass.hoverFill(dark: dark).cgColor
            layer.borderWidth = 0
            layer.shadowOpacity = 0
            titleLabel.textColor = .labelColor
        } else {
            layer.backgroundColor = nil
            layer.borderWidth = 0
            layer.shadowOpacity = 0
            titleLabel.textColor = .secondaryLabelColor
        }
    }

    // MARK: - Interaction

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
        trackingAreaAdded = true
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAccessoryImage()
        applyLayerColors()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAccessoryImage()
        applyLayerColors()
    }

    override func mouseDown(with event: NSEvent) {
        // Consumed here rather than in mouseUp so selection feels immediate, which
        // matters at 30 tabs where the alternative reads as lag.
        onClick?()
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !menuItems.isEmpty else { return nil }
        // `NSMenuItem.target` is weak, so the closure boxes need an owner. Replacing
        // the array each time also drops the previous click's boxes.
        menuTargets = menuItems.map { ClosureTarget(action: $0.action) }
        let menu = NSMenu()
        for (spec, target) in zip(menuItems, menuTargets) {
            let item = NSMenuItem(title: spec.title, action: #selector(ClosureTarget.fire), keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }
        return menu
    }

    @objc private func accessoryPressed() {
        switch accessory {
        case .close: onClose?()
        case .chevron, .none: onAccessory?()
        }
    }
}

/// The `+ New Tab` row, and section headers.
final class SidebarLabelRow: ChromeView {
    private let label = NSTextField(labelWithString: "")

    init(text: String, font: NSFont, color: NSColor, height: CGFloat) {
        super.init(frame: .zero)
        label.stringValue = text
        label.font = font
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            label.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Chrome.sidebarHorizontalPadding + 6
            ),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -Chrome.sidebarHorizontalPadding
            ),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A hairline divider that follows the appearance.
final class SidebarDivider: ChromeView {
    init() {
        super.init(frame: .zero)
        NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant: 9)])
        applyLayerColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        let line = NSRect(
            x: Chrome.sidebarHorizontalPadding + 2,
            y: (bounds.height / 2).rounded(),
            width: bounds.width - 2 * (Chrome.sidebarHorizontalPadding + 2),
            height: 1
        )
        line.fill()
    }
}
