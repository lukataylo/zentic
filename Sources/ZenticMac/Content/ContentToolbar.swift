import AppKit

@MainActor
protocol ContentToolbarDelegate: AnyObject {
    func toolbarDidToggleSidebar()
    func toolbarDidGoBack()
    func toolbarDidGoForward()
    func toolbarDidReload()
    func toolbar(_ toolbar: ContentToolbar, didSubmitAddress text: String)
    func toolbarDidRequestDownloads(_ sender: NSView)
}

/// The toolbar. Sits above the **content area**, never above the sidebar — that
/// placement is what makes the sidebar read as a separate surface rather than a
/// pane of one window, and it is the detail people notice about Arc.
final class ContentToolbar: PointerTrackingView {
    weak var delegate: (any ContentToolbarDelegate)?

    let breadcrumb = BreadcrumbURLView(frame: .zero)

    private let sidebarButton = NSButton()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let downloadsButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        configure(sidebarButton, symbol: "sidebar.left", action: #selector(toggleSidebar), tip: "Toggle Sidebar")
        configure(backButton, symbol: "chevron.left", action: #selector(goBack), tip: "Back")
        configure(forwardButton, symbol: "chevron.right", action: #selector(goForward), tip: "Forward")
        configure(reloadButton, symbol: "arrow.clockwise", action: #selector(reload), tip: "Reload")
        configure(
            downloadsButton,
            symbol: "arrow.down.circle",
            action: #selector(showDownloads),
            tip: "Downloads"
        )

        breadcrumb.translatesAutoresizingMaskIntoConstraints = false
        breadcrumb.onSubmit = { [weak self] text in
            guard let self else { return }
            delegate?.toolbar(self, didSubmitAddress: text)
        }

        let leftGroup = NSStackView(views: [sidebarButton, backButton, forwardButton, reloadButton])
        leftGroup.orientation = .horizontal
        leftGroup.spacing = 2
        leftGroup.translatesAutoresizingMaskIntoConstraints = false

        addSubview(leftGroup)
        addSubview(breadcrumb)
        addSubview(downloadsButton)

        NSLayoutConstraint.activate([
            leftGroup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            leftGroup.centerYAnchor.constraint(equalTo: centerYAnchor),

            breadcrumb.leadingAnchor.constraint(equalTo: leftGroup.trailingAnchor, constant: 8),
            breadcrumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            breadcrumb.heightAnchor.constraint(equalToConstant: 24),
            breadcrumb.trailingAnchor.constraint(equalTo: downloadsButton.leadingAnchor, constant: -8),

            downloadsButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -(Chrome.contentInset + 4)
            ),
            downloadsButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: Chrome.toolbarHeight),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func configure(_ button: NSButton, symbol: String, action: Selector, tip: String) {
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.symbolConfiguration = .init(pointSize: 12.5, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        button.toolTip = tip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    func update(url: URL?, canGoBack: Bool, canGoForward: Bool, isLoading: Bool) {
        breadcrumb.show(url: url, isLoading: isLoading)
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        // Doubles as a stop button while loading, which is the only time the
        // distinction matters.
        reloadButton.image = NSImage(
            systemSymbolName: isLoading ? "xmark" : "arrow.clockwise",
            accessibilityDescription: isLoading ? "Stop" : "Reload"
        )
        backButton.contentTintColor = canGoBack ? .secondaryLabelColor : .quaternaryLabelColor
        forwardButton.contentTintColor = canGoForward ? .secondaryLabelColor : .quaternaryLabelColor
    }

    func setDownloadsVisible(_ visible: Bool) {
        downloadsButton.isHidden = !visible
    }

    @objc private func toggleSidebar() { delegate?.toolbarDidToggleSidebar() }
    @objc private func goBack() { delegate?.toolbarDidGoBack() }
    @objc private func goForward() { delegate?.toolbarDidGoForward() }
    @objc private func reload() { delegate?.toolbarDidReload() }
    @objc private func showDownloads() { delegate?.toolbarDidRequestDownloads(downloadsButton) }
}
