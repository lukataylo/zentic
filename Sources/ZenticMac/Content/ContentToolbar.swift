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
    /// The lens button. `sender` anchors the lens popover.
    func toolbarDidRequestLenses(_ sender: NSView)
}

/// What the toolbar needs to know to draw the reader controls.
///
/// Two axes, deliberately not one. The level is *depth* — how much of this page
/// Zentic is changing — and the rail is its whole control. A lens is *shape*, per
/// site, and neither is a setting of the other.
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
    /// Lenses on this page, and what they actually did. See ``LensState`` — the
    /// counts come from the page's own reports or they are not shown at all.
    var lens = LensState()
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
    /// Replaces the old two-segment Transformed/Original control, the separate
    /// wand button and the shield. Those described two of the three layers through
    /// three unrelated widgets and left the strip layer with no honest control at
    /// all, so the one question worth answering — how much is this browser changing
    /// what I am looking at — had no single place to read it.
    let levelRail = LevelRailView(frame: .zero)
    /// Lenses, for this page. A separate control because it answers a separate
    /// question: the rail sets how deep the change goes, a lens sets its shape.
    /// Unlike the rail this one *may* carry a number, because the page reports what
    /// each op did — but only ever that number. See ``applyLens(_:)``.
    private let lensButton = NSButton()
    private let lensBadge = NSTextField(labelWithString: "")
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

        // The lens pair sits as one unit so the badge tracks its glyph rather than
        // drifting away from it as the group's other members come and go.
        let lensGroup = NSStackView(views: [lensButton, lensBadge])
        lensGroup.orientation = .horizontal
        lensGroup.spacing = 1
        lensGroup.translatesAutoresizingMaskIntoConstraints = false

        let rightGroup = NSStackView(views: [aiBadge, lensGroup, levelRail, downloadsButton])
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
        configure(
            lensButton,
            symbol: "camera.filters",
            action: #selector(requestLenses),
            tip: "Lenses"
        )

        // The one number in this corner of the toolbar, and only ever the page's own
        // count of what ran. Tabular figures so `3/4` and `11/12` occupy the same
        // width — a badge that shifts the rail sideways as ops report reads as the
        // toolbar twitching.
        lensBadge.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        lensBadge.textColor = .secondaryLabelColor
        lensBadge.isHidden = true
        lensBadge.translatesAutoresizingMaskIntoConstraints = false

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

        applyLens(state.lens)
    }

    /// Draw the lens button from what the page reported, and nothing else.
    ///
    /// Three states the user can tell apart at a glance: dimmed for a site with no
    /// lens acting on it, tinted for lenses that all found what they were pointed
    /// at, amber for drift. Amber rather than red because a drifted lens is a site
    /// that changed, not an error — the page is fine, one op has stopped landing.
    ///
    /// **Invariant 8 is the rule here.** The badge is drawn from ``LensState/tally``,
    /// which is nil until a report arrives; no report means no badge, never a
    /// hopeful `4/4`. A number that turns out to be wrong about what the user is
    /// looking at is worse than no number, because they cannot tell which it was.
    private func applyLens(_ state: LensState) {
        // Enabled even when it does nothing, like the rail's blocked stops: a toolbar
        // corner that swallows clicks reads as broken, and the tooltip does the
        // explaining.
        lensButton.isEnabled = true
        lensBadge.stringValue = state.tally ?? ""
        lensBadge.isHidden = state.tally == nil

        let tint: NSColor
        let tip: String
        if !state.hasLenses {
            tint = .tertiaryLabelColor
            tip = "No lenses for this site — ⌥⌘L to make one"
        } else if !state.isActive {
            tint = .tertiaryLabelColor
            // Two different states look identical from here and need different
            // sentences: a lens that is switched off is a switch to flip, a lens
            // scoped to `/watch` while the user is on the home page is a page to
            // visit. Saying "switched off" for the second sent people to the popover
            // to turn on a lens that was already on, which is the popover's own
            // wording problem in reverse.
            let offPath = state.offPathCount
            if offPath > 0 {
                tip = "\(Self.lensPhrase(offPath)) on, but for other pages"
            } else {
                // Nothing is on and nothing is off-path, so every lens the site has
                // is switched off — and there is at least one, or `hasLenses` would
                // have taken the branch above. The count is phrased through the same
                // helper so "This site's 0 lenses" cannot be written at all.
                tip = "\(Self.lensPhrase(state.siteLensCount)) switched off"
            }
        } else if state.isSuppressed {
            // On, correct, and invisible: the reader is showing Zentic's render and
            // a lens acts on the site's own page underneath it. The engine reports
            // every op `skipped`, which is true and which the badge used to draw as
            // `0/4` in the accent tint — a working colour over a total-failure
            // number. No badge and the sentence instead: there is no count that is
            // true of what is on screen, so invariant 8 says show none.
            tint = .tertiaryLabelColor
            tip = """
                \(Self.lensPhrase(state.entries.count)) on. Lenses act on the site's own \
                page — ⌘\\ to see it.
                """
        } else if state.isDrifted {
            tint = .systemOrange
            tip = "\(state.missedCount) of \(state.totalCount) changes no longer match this page"
        } else if let tally = state.tally {
            tint = .controlAccentColor
            tip = "\(tally) changes applied by \(state.entries.count == 1 ? "1 lens" : "\(state.entries.count) lenses")"
        } else {
            tint = .controlAccentColor
            tip = "Lenses are on for this page"
        }
        lensButton.contentTintColor = tint
        lensBadge.textColor = tint
        lensButton.toolTip = tip
        lensBadge.toolTip = tip
    }

    /// "This site's lens is" / "This site's 3 lenses are", with the verb, so every
    /// sentence built from it agrees with itself. A count below two is written as
    /// the singular: zero is unreachable in all three call sites, and "0 lenses" is
    /// the kind of string that only ever ships because nobody could reach it.
    private static func lensPhrase(_ count: Int) -> String {
        count > 1 ? "This site's \(count) lenses are" : "This site's lens is"
    }

    /// Anchors the lens popover.
    var lensAnchor: NSView { lensButton }

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

    /// The strip around the controls is chrome: drag moves the window, and a
    /// double-click is the title-bar gesture. Anything over a button or the
    /// address field never reaches here.
    override func mouseDragged(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            performTitleBarDoubleClick()
        } else {
            super.mouseDown(with: event)
        }
    }

    @objc private func requestLenses() { delegate?.toolbarDidRequestLenses(lensButton) }
    @objc private func discardRewrite() { delegate?.toolbarDidRequestDiscardRewrite() }
}
