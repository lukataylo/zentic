import AppKit
import ZenticKit

@MainActor
protocol ContentToolbarDelegate: AnyObject {
    func toolbarDidToggleSidebar()
    func toolbarDidGoBack()
    func toolbarDidGoForward()
    func toolbarDidReload()
    func toolbar(_ toolbar: ContentToolbar, didSubmitAddress text: String)
    func toolbarDidRequestDownloads(_ sender: NSView)
    /// The reader/original segmented control moved.
    func toolbar(_ toolbar: ContentToolbar, didSelectMode mode: ReaderMode)
    /// The rewrite button. `sender` anchors the options menu.
    func toolbarDidRequestRewrite(_ sender: NSView)
    /// The AI badge was clicked — put the original text back.
    func toolbarDidRequestDiscardRewrite()
}

/// What the toolbar needs to know to draw the reader controls.
struct ReaderControlState {
    var mode: ReaderMode = .restructured
    var canTransform = false
    var canRewrite = false
    var rewrite: TabController.RewriteState = .none
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

    /// Reader ⇄ Original. The visible half of ⌘\.
    ///
    /// A segmented control rather than a single toggle button, because the two
    /// states are not "on and off" — they are two renderings of the same page, and
    /// the user needs to see which one they are looking at without clicking to
    /// find out.
    private let modeControl = NSSegmentedControl()
    private let rewriteButton = NSButton()
    /// Shown only while a rewrite is on screen. Invariant 6: rewritten text is
    /// badged for as long as it is displayed.
    private let aiBadge = NSButton()

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

        buildReaderControls()

        let leftGroup = NSStackView(views: [sidebarButton, backButton, forwardButton, reloadButton])
        leftGroup.orientation = .horizontal
        leftGroup.spacing = 2
        leftGroup.translatesAutoresizingMaskIntoConstraints = false

        let rightGroup = NSStackView(views: [aiBadge, modeControl, rewriteButton, downloadsButton])
        rightGroup.orientation = .horizontal
        rightGroup.spacing = 6
        rightGroup.translatesAutoresizingMaskIntoConstraints = false

        addSubview(leftGroup)
        addSubview(breadcrumb)
        addSubview(rightGroup)

        NSLayoutConstraint.activate([
            leftGroup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            leftGroup.centerYAnchor.constraint(equalTo: centerYAnchor),

            breadcrumb.leadingAnchor.constraint(equalTo: leftGroup.trailingAnchor, constant: 8),
            breadcrumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            breadcrumb.heightAnchor.constraint(equalToConstant: 24),
            breadcrumb.trailingAnchor.constraint(equalTo: rightGroup.leadingAnchor, constant: -8),

            rightGroup.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -(Chrome.contentInset + 4)
            ),
            rightGroup.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: Chrome.toolbarHeight),
        ])
    }

    private func buildReaderControls() {
        // Icons, not words. Two labels cost about 150pt of a toolbar whose most
        // valuable tenant is the address bar, and the pair reads fine as glyphs
        // once you have used it twice. The tooltip carries the words until then.
        modeControl.segmentCount = 2
        modeControl.setImage(
            NSImage(systemSymbolName: "textformat", accessibilityDescription: "Transformed"),
            forSegment: 0
        )
        modeControl.setImage(
            NSImage(systemSymbolName: "globe", accessibilityDescription: "Original page"),
            forSegment: 1
        )
        modeControl.setWidth(28, forSegment: 0)
        modeControl.setWidth(28, forSegment: 1)
        modeControl.segmentStyle = .capsule
        modeControl.trackingMode = .selectOne
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.controlSize = .small
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        configure(
            rewriteButton,
            symbol: "wand.and.stars",
            action: #selector(requestRewrite),
            tip: "Rewrite this page"
        )

        // Deliberately a button, not a label: the badge that tells the user they
        // are reading rewritten text is also the fastest way back to the original.
        aiBadge.title = "AI"
        aiBadge.bezelStyle = .badge
        aiBadge.controlSize = .small
        aiBadge.font = .systemFont(ofSize: 10, weight: .bold)
        aiBadge.target = self
        aiBadge.action = #selector(discardRewrite)
        aiBadge.toolTip = "Rewritten by a model. Click to restore the original text."
        aiBadge.isHidden = true
        aiBadge.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Drive the reader controls from the selected tab.
    func apply(reader state: ReaderControlState) {
        modeControl.isEnabled = state.canTransform
        modeControl.selectedSegment = state.mode == .restructured ? 0 : 1
        // Says *why* it is inert rather than just being inert. On a page Zentic
        // left alone both segments show the same thing, and a control that appears
        // to do nothing without explaining itself is the most annoying kind.
        modeControl.toolTip = state.canTransform
            ? "Zentic's transformed page, or the site's own (⌘\\)"
            : "Zentic left this page as it is — there is nothing to switch between"

        switch state.rewrite {
        case .none:
            aiBadge.isHidden = true
            rewriteButton.isEnabled = state.canRewrite
            rewriteButton.toolTip = state.canRewrite
                ? "Rewrite this page"
                : "Rewriting needs the transformed page"
            rewriteButton.contentTintColor = .secondaryLabelColor
        case .running(let done, let total):
            aiBadge.isHidden = true
            rewriteButton.isEnabled = false
            rewriteButton.toolTip = "Rewriting \(done) of \(total)…"
            rewriteButton.contentTintColor = .controlAccentColor
        case .shown:
            aiBadge.isHidden = false
            rewriteButton.isEnabled = state.canRewrite
            rewriteButton.contentTintColor = .controlAccentColor
            rewriteButton.toolTip = "Rewrite again with different settings"
        case .failed(let reason):
            aiBadge.isHidden = true
            rewriteButton.isEnabled = state.canRewrite
            rewriteButton.contentTintColor = .systemOrange
            rewriteButton.toolTip = reason
        }
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

    @objc private func modeChanged() {
        delegate?.toolbar(self, didSelectMode: modeControl.selectedSegment == 0 ? .restructured : .original)
    }

    @objc private func requestRewrite() { delegate?.toolbarDidRequestRewrite(rewriteButton) }
    @objc private func discardRewrite() { delegate?.toolbarDidRequestDiscardRewrite() }
}
