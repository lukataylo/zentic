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
    /// A stop on the level rail was clicked.
    func toolbar(_ toolbar: ContentToolbar, didSelectLevel level: PageLevel)
    /// A stop this page cannot reach was clicked. Answer, do not ignore.
    func toolbar(_ toolbar: ContentToolbar, didSelectBlockedLevel level: PageLevel)
    /// The rail's label was clicked. `sender` anchors the detail popover.
    func toolbar(_ toolbar: ContentToolbar, didRequestLevelDetail sender: NSView)
    /// The AI badge was clicked — put the original text back.
    func toolbarDidRequestDiscardRewrite()
}

/// What the toolbar needs to know to draw the reader controls.
struct ReaderControlState {
    var rewrite: TabController.RewriteState = .none
    /// Where this page currently sits on the ladder.
    var level: PageLevel = .reader
    /// Where it would sit with no override, drawn hollow when the two differ.
    var automatic: PageLevel = .reader
    /// The highest stop this page can actually reach.
    var ceiling: PageLevel = .rewritten
    /// Why, when that is lower than the top.
    var ceilingReason: String?
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

    /// The five-stop ladder, from the site as shipped to a model-rewritten page.
    ///
    /// Replaces the old two-segment Transformed/Original control and the separate
    /// wand button. Those described two of the three layers through two unrelated
    /// widgets and left the strip layer with no control at all, so the one question
    /// worth answering — how much is this browser changing what I am looking at —
    /// had no single place to read it.
    let levelRail = LevelRailView(frame: .zero)
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

        let rightGroup = NSStackView(views: [aiBadge, levelRail, downloadsButton])
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
        levelRail.translatesAutoresizingMaskIntoConstraints = false
        levelRail.onSelect = { [weak self] level in
            guard let self else { return }
            delegate?.toolbar(self, didSelectLevel: level)
        }
        levelRail.onBlocked = { [weak self] level in
            guard let self else { return }
            delegate?.toolbar(self, didSelectBlockedLevel: level)
        }
        levelRail.onOpenDetail = { [weak self] in
            guard let self else { return }
            delegate?.toolbar(self, didRequestLevelDetail: levelRail)
        }

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
        levelRail.apply(
            level: state.level,
            automatic: state.automatic,
            ceiling: state.ceiling,
            ceilingReason: state.ceilingReason
        )

        // The badge is the only rewrite affordance left in the toolbar now that the
        // wand has become the ladder's top stop. It stays for invariant 6: rewritten
        // text is badged for as long as it is shown, and the badge is also the
        // fastest way back.
        switch state.rewrite {
        case .none, .failed:
            aiBadge.isHidden = true
        case .running(let done, let total):
            aiBadge.isHidden = false
            aiBadge.title = "AI \(done)/\(total)"
            aiBadge.toolTip = "Rewriting \(done) of \(total)…"
        case .shown:
            aiBadge.isHidden = false
            aiBadge.title = "AI"
            aiBadge.toolTip = "Rewritten by a model. Click to restore the original text."
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

    @objc private func discardRewrite() { delegate?.toolbarDidRequestDiscardRewrite() }
}
