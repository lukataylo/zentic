import AppKit
import ZenticKit

/// The multi-lens surface: what this site has, what each one did, and what to do
/// about the ones that stopped working.
///
/// A popover rather than a window because it is about the page behind it — close it
/// and the thing it describes is still there. The list is newest edit first, which
/// is a reading order and not a claim about who wins: where two lenses genuinely
/// change the same thing the browser's cascade decides, by the specificity of the
/// selectors involved. The header says exactly that, because a list whose order
/// looks meaningful and is not is worse than one that explains itself.
@MainActor
final class LensPopover: NSObject {
    /// One lens as the list shows it: the record, plus what it did on the page that
    /// is open — which is nothing at all when its path pattern does not cover this
    /// URL, and that is worth saying rather than hiding.
    struct Row {
        var lens: Lens
        var entry: LensState.Entry?
    }

    /// What the popover can ask the app to do. Closures rather than a delegate
    /// protocol: every one of these is a one-line hop back into the view controller
    /// that owns the tab, and a nine-method protocol would only spread that out.
    struct Actions {
        var setEnabled: (Lens, Bool) -> Void
        var edit: (Lens) -> Void
        var duplicate: (Lens) -> Void
        var refit: (Lens) -> Void
        var delete: (Lens) -> Void
        var newLens: () -> Void
    }

    private var popover: NSPopover?
    /// The host the open popover is titled with, so a rebuild does not have to be
    /// told again what it is already showing.
    private var host: String?
    /// Everything the drawn list is made of, in one string. See ``update(rows:actions:)``.
    private var shown: String?

    func show(relativeTo view: NSView, host: String?, rows: [Row], actions: Actions) {
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = list(host: host, rows: rows, actions: actions, in: popover)
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        self.popover = popover
        self.host = host
        shown = Self.fingerprint(rows)
    }

    /// Redraw an open popover from a freshly read set.
    ///
    /// The store is the truth and the popover is a view of it, but nothing was
    /// re-reading it: a lens deleted in another window kept its row here, and Edit,
    /// Re-fit and Delete on that row all resolved a lens id the store no longer has
    /// and returned silently. Swapping the content view controller rather than
    /// closing keeps the surface the user is working in on screen — and the popover
    /// resizes itself to whatever the new list needs.
    ///
    /// Called for reports as well as for store changes, so a `3/4` that becomes `4/4`
    /// while the popover is up moves the row and not just the toolbar badge. That
    /// makes this a hot path — a coalesced report lands every half second on a live
    /// feed — so it compares what the new rows would draw against what is already
    /// drawn before rebuilding anything: rebuilding the view tree at report rate
    /// makes the list flicker and drops any menu open over it.
    func update(rows: [Row], actions: Actions) {
        guard let popover, popover.isShown else { return }
        let fingerprint = Self.fingerprint(rows)
        guard fingerprint != shown else { return }
        shown = fingerprint
        popover.contentViewController = self.list(
            host: host,
            rows: rows,
            actions: actions,
            in: popover
        )
    }

    /// Everything a row draws, flattened. Two lists with the same fingerprint would
    /// build the same view tree, so rebuilding is pure cost.
    private static func fingerprint(_ rows: [Row]) -> String {
        rows.map { row in
            let entry = row.entry
            let notes: String = (entry?.notes ?? [])
                .map {
                    "\($0.note)=\($0.status.rawValue)=\($0.detail)=\($0.anchor?.selector ?? "")"
                }
                .joined(separator: "·")
            var fields: [String] = [row.lens.id, row.lens.name]
            fields.append(row.lens.isEnabled ? "on" : "off")
            fields.append(row.lens.pathPattern)
            fields.append(entry.map { $0.isSuppressed ? "suppressed" : "live" } ?? "unmatched")
            fields.append(entry?.tally ?? "")
            fields.append(entry?.suppressionReason ?? "")
            fields.append(entry.map { "\($0.missedCount)/\($0.totalCount)" } ?? "")
            fields.append(notes)
            fields.append(Self.historyLine(for: row) ?? "")
            return fields.joined(separator: "\u{1}")
        }
        .joined(separator: "\u{2}")
    }

    private func list(
        host: String?,
        rows: [Row],
        actions: Actions,
        in popover: NSPopover
    ) -> LensListViewController {
        let list = LensListViewController(host: host, rows: rows, actions: actions)
        // The list closes the popover itself before anything that opens a sheet, a
        // file panel or the in-page editor: a popover still floating over a sheet it
        // spawned looks like two pieces of UI arguing.
        list.popover = popover
        return list
    }

    /// What this lens did the *last* time it ran, when this page has nothing to say
    /// about it yet.
    ///
    /// Shown for a row with no entry too — a lens switched off, or scoped to another
    /// path — which is where it matters most: a lens that is not applying here is
    /// precisely the one whose history the user cannot get at any other way. It used
    /// to be gated behind having an entry, so the only lenses that could explain
    /// their past were the ones already running in front of the user.
    ///
    /// "Last time this lens ran", not "last visit": the stored report is per lens
    /// across every path its pattern covers, so for a `*` lens it is routinely about
    /// a different page of the site than the one open now.
    static func historyLine(for row: Row) -> String? {
        // This page's own report always wins. History is what there is to say when
        // there is nothing current to say.
        if row.entry?.hasReport == true { return nil }
        guard let stored = row.lens.lastReport, stored.isDrifted else { return nil }
        return """
            Last time this lens ran, \(stored.missedCount) of \(stored.totalCount) \
            changes did not match
            """
    }

    func close() {
        popover?.close()
        popover = nil
        host = nil
        shown = nil
    }

    var isShown: Bool { popover?.isShown ?? false }
}

// MARK: - List

private final class LensListViewController: NSViewController {
    private let host: String?
    private var rows: [LensPopover.Row]
    private let actions: LensPopover.Actions

    private let rowsStack = FlippedStackView()
    /// AppKit holds targets weakly, so the closures behind the footer links and the
    /// row menus need an owner for as long as the popover is up.
    private var buttonTargets: [ClosureTarget] = []
    weak var popover: NSPopover?

    /// Popover width. Wide enough for a name, a meter, a tally and the actions
    /// button on one line, and for an op's note plus the selector it went through
    /// to read as one line underneath.
    private static let width: CGFloat = 360

    /// How tall the list of lenses may get before it scrolls.
    ///
    /// A cap rather than a taller popover, because the two things that make this
    /// list long are unbounded: a site can hold any number of lenses, and each row
    /// explains itself in place rather than behind a disclosure triangle. Roughly a
    /// dozen rows on a laptop screen, with the header and the footer staying put
    /// outside the scroll so **New Lens…** never scrolls away. The per-lens half of
    /// the same problem is capped separately — see ``LensRowView/maxNoteRows``.
    private static let maxListHeight: CGFloat = 400

    init(host: String?, rows: [LensPopover.Row], actions: LensPopover.Actions) {
        self.host = host
        self.rows = rows
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8
        container.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        container.addArrangedSubview(header())

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        for row in rows { rowsStack.addArrangedSubview(makeRow(row)) }
        if rows.isEmpty { rowsStack.addArrangedSubview(emptyState()) }

        let scroll = scroller(around: rowsStack)
        container.addArrangedSubview(scroll)

        container.addArrangedSubview(separator())
        container.addArrangedSubview(footer())

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.width),
            rowsStack.widthAnchor.constraint(equalToConstant: Self.width - 28),
            scroll.widthAnchor.constraint(equalToConstant: Self.width - 28),
        ])

        // The scroller's height is *measured*, not related to the list's by a
        // constraint. Any constraint tying the two — an equality, or an inequality
        // at any priority — is one the solver may also satisfy by squashing the
        // list to fit the cap, and squash is what it did: three forty-op lenses
        // came out as three overlapping stacks inside a scroll view with nothing
        // left to scroll. A constant cannot be resolved from the wrong end. It is
        // computed once because the whole list is rebuilt whenever anything in it
        // changes — see `LensPopover.update(rows:actions:)`.
        scroll.heightAnchor.constraint(
            equalToConstant: min(rowsStack.fittingSize.height, Self.maxListHeight)
        ).isActive = true
        view = container
    }

    /// The rows, in something that can run out of room.
    ///
    /// The document view is flipped so the list starts at the top: an unflipped
    /// `NSStackView` in a clip view lays out from the bottom edge, which shows up
    /// as a popover that opens already scrolled to its last lens.
    private func scroller(around document: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        // Transparent all the way down: the popover paints its own vibrant ground
        // and a scroll view's default white would cut a rectangle out of it.
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
        return scroll
    }

    // MARK: Chrome

    private func header() -> NSView {
        let title = NSTextField(labelWithString: host ?? "Lenses")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle

        // What the order means, and — the part users get wrong — what it does not.
        // Only shown when there is actually a stack: with one lens there is nothing
        // to overlap. Saying "the lower one wins" here was a rule the app enforced
        // and the page did not, so the list explained a conflict resolution that
        // never happened.
        let hint = NSTextField(
            labelWithString: rows.count > 1
                ? "Newest first. Where two lenses change the same thing, the more "
                    + "specific change wins, as with any two style rules."
                : "Replayed on every visit. No model call, nothing leaves the device."
        )
        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        hint.preferredMaxLayoutWidth = Self.width - 28

        let stack = NSStackView(views: [title, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func emptyState() -> NSView {
        let label = NSTextField(
            labelWithString: "No lenses for this site yet."
        )
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
        return line
    }

    private func footer() -> NSView {
        let stack = NSStackView(views: [
            link("New Lens…") { [weak self] in self?.dismissThen { self?.actions.newLens() } }
        ])
        stack.orientation = .horizontal
        stack.spacing = 14
        return stack
    }

    private func link(_ title: String, action: @escaping () -> Void) -> NSButton {
        let target = ClosureTarget(action: action)
        buttonTargets.append(target)
        let button = NSButton(title: title, target: target, action: #selector(ClosureTarget.fire))
        button.isBordered = false
        button.bezelStyle = .inline
        button.contentTintColor = .controlAccentColor
        button.font = .systemFont(ofSize: 11.5, weight: .medium)
        return button
    }

    /// Run an action with the popover out of the way.
    private func dismissThen(_ action: () -> Void) {
        popover?.performClose(nil)
        action()
    }

    // MARK: Rows

    private func makeRow(_ row: LensPopover.Row) -> LensRowView {
        let view = LensRowView(row: row, width: Self.width - 28)
        view.onToggle = { [weak self] isEnabled in
            self?.actions.setEnabled(row.lens, isEnabled)
        }
        view.onRefit = { [weak self] in
            self?.dismissThen { self?.actions.refit(row.lens) }
        }
        view.onMenu = { [weak self] sender in
            self?.showMenu(for: row.lens, from: sender)
        }
        return view
    }

    /// The per-row actions.
    ///
    /// Nothing here reaches back through `self`, and the targets are owned by the
    /// menu items rather than by this controller. `menu.popUp` runs a nested tracking
    /// loop that services the main queue, so a lens saved in another window can land
    /// a `didChangeLenses` *while the menu is open* — which rebuilds the popover's
    /// content and releases this controller. `NSMenuItem.target` is weak, so every
    /// open item's target went nil and Re-fit and Delete then did nothing at all,
    /// silently. `representedObject` is strong, and the menu holds its items, so the
    /// actions outlive the list they were opened from.
    private func showMenu(for lens: Lens, from sender: NSView) {
        let menu = NSMenu()
        // Captured by value: `actions` closures are held by the view controller that
        // owns the tab, which is not the thing being replaced, and `popover` is the
        // window this list happens to be inside.
        let actions = self.actions
        let popover = self.popover
        let run: (@escaping (Lens) -> Void) -> () -> Void = { action in
            {
                popover?.performClose(nil)
                action(lens)
            }
        }
        let items: [(String, () -> Void)] = [
            ("Edit…", run(actions.edit)),
            ("Duplicate", run(actions.duplicate)),
            ("Re-fit to This Page", run(actions.refit)),
            ("Delete", run(actions.delete)),
        ]

        for (title, action) in items {
            let target = ClosureTarget(action: action)
            let item = NSMenuItem(
                title: title,
                action: #selector(ClosureTarget.fire),
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
    }

}

// MARK: - Row

/// One lens: a switch, a name, how much of it is on the page, and — grouped by
/// outcome — an account of whatever is not.
///
/// The row reads left to right as it is meant to be scanned: the switch, the name,
/// then a meter and a tally that answer "how much of this is working" before any
/// text is read. Everything below the top line explains a state that is not simply
/// "it applied".
private final class LensRowView: NSView {
    var onToggle: ((Bool) -> Void)?
    var onMenu: ((NSView) -> Void)?
    var onRefit: (() -> Void)?

    private let checkbox = NSButton()
    private let menuButton = NSButton()
    /// The Re-fit button's target. Weak on the control, so it lives here.
    private var refitTarget: ClosureTarget?

    init(row: LensPopover.Row, width: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        checkbox.setButtonType(.switch)
        checkbox.title = ""
        checkbox.state = row.lens.isEnabled ? .on : .off
        checkbox.target = self
        checkbox.action = #selector(toggled)
        checkbox.toolTip = row.lens.isEnabled ? "Switch this lens off" : "Switch this lens on"
        checkbox.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: row.lens.name)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.textColor = row.lens.isEnabled ? .labelColor : .secondaryLabelColor
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        menuButton.isBordered = false
        menuButton.bezelStyle = .inline
        menuButton.imagePosition = .imageOnly
        menuButton.image = NSImage(
            systemSymbolName: "ellipsis.circle",
            accessibilityDescription: "Lens actions"
        )
        menuButton.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        menuButton.contentTintColor = .secondaryLabelColor
        menuButton.target = self
        menuButton.action = #selector(showMenu)
        menuButton.toolTip = "Edit, duplicate, re-fit or delete"
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // What the right-hand end of the row says, by state. Only two of the five
        // spend any colour: a lens that is working must not read as a warning, so
        // amber is kept for the two states with a repair behind them.
        var trailing: [NSView] = []
        if let entry = row.entry {
            switch entry.standing {
            case .silent:
                // The page has not answered. No meter and no number — a bar drawn
                // from nothing is exactly the fabrication invariant 8 is about.
                break
            case .suppressed:
                trailing.append(
                    Self.chip(
                        "not on screen",
                        colour: .secondaryLabelColor,
                        tip: "This lens acts on the site's own page — ⌘\\ to see it"
                    )
                )
            case .holding:
                trailing.append(Self.meter(for: entry))
                trailing.append(Self.tallyLabel(entry.tally, colour: .secondaryLabelColor))
            case .drifting:
                trailing.append(Self.meter(for: entry))
                trailing.append(Self.tallyLabel(entry.tally, colour: .systemOrange))
            case .stopped:
                // The one row that gets a word as well as a colour. `0/3` in amber
                // is already the strongest tally the meter can draw, and a lens
                // with nothing left on the page is worth naming rather than making
                // the user read the proportion.
                trailing.append(Self.meter(for: entry))
                trailing.append(Self.tallyLabel(entry.tally, colour: .systemOrange))
                trailing.append(
                    Self.chip(
                        "stopped",
                        colour: .systemOrange,
                        tip: "Nothing this lens changes matches this page any more"
                    )
                )
            }
        } else if row.lens.isEnabled {
            // On, but scoped to a path this page is not on. Said plainly, because a
            // lens working perfectly on `/watch` otherwise looks, from the home
            // page, exactly like one that has stopped working.
            trailing.append(
                Self.chip(
                    Self.scope(row.lens.pathPattern),
                    colour: .secondaryLabelColor,
                    tip: "On, but only for pages matching \(row.lens.pathPattern)"
                )
            )
        }

        let top = NSStackView(views: [checkbox, name, spacer] + trailing + [menuButton])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 5
        top.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [top])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        column.translatesAutoresizingMaskIntoConstraints = false

        if let detail = detail(for: row, width: width - Self.detailIndent) {
            column.addArrangedSubview(detail)
        }

        addSubview(column)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            top.widthAnchor.constraint(equalToConstant: width),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Detail

    /// The part of the row that explains itself: what the page did with this lens,
    /// gathered into one block per outcome.
    ///
    /// Shown expanded rather than behind a disclosure triangle. A drifted lens is
    /// the one thing in this popover that needs the user to do something, and a
    /// row that hides why it is amber until clicked is a row that will be ignored.
    ///
    /// The shape is a heading per ``LensState/NoteGroup`` and a row per
    /// ``LensState/OpNote`` under it, which is what makes every ``LensOpStatus``
    /// visible somewhere while saying each reason once. It used to be one line per
    /// note, each of them the op's sentence with the reason glued on the end — so
    /// three drifted ops printed "— no longer matches this page" three times, in
    /// amber, over the only text on the row that differed. Now the reason is the
    /// heading, the row is the user's own sentence in full weight, and the selector
    /// the op went through sits at the end of it in tertiary mono.
    private func detail(for row: LensPopover.Row, width: CGFloat) -> NSView? {
        let entry = row.entry
        let groups = entry?.noteGroups ?? []

        // Said in the past tense, muted, and without a tally, because it describes a
        // page load that is over. Not gated on having an entry: see `historyLine`.
        let history = LensPopover.historyLine(for: row)

        // One line for the whole lens, not the same sentence once per op. While the
        // reader is showing its own render every op comes back skipped for one
        // reason, and the reason is about the lens rather than about any op in it.
        let suppression: String? = (entry?.isSuppressed ?? false)
            ? entry?.suppressionReason
                ?? "Zentic is showing its own render — this lens acts on the site's page (⌘\\)"
            : nil

        guard !groups.isEmpty || history != nil || suppression != nil else { return nil }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 3, left: Self.detailIndent, bottom: 1, right: 0)

        if let history {
            stack.addArrangedSubview(
                Self.line(history, colour: .tertiaryLabelColor, width: width)
            )
        }

        // Deliberately plain: no stripe, no heading, no count. Suppression is the
        // one state here that is not a fault, and anything that made it look like
        // the drift blocks below would send the user to repair a lens that is fine.
        if let suppression {
            stack.addArrangedSubview(
                Self.line(suppression, colour: .secondaryLabelColor, width: width)
            )
        }

        // Rows are budgeted across the whole lens rather than per group, so a lens
        // of forty ops cannot push the ones below it off the screen. Headings are
        // never dropped — there are at most four, one per status, and each carries
        // its own count — so nothing the page reported goes unmentioned.
        var budget = Self.maxNoteRows
        let stopped: Bool = if case .stopped = entry?.standing { true } else { false }
        for group in groups {
            stack.addArrangedSubview(
                groupView(
                    group,
                    budget: &budget,
                    refit: entry?.canRefit == true ? (stopped ? .prominent : .quiet) : nil,
                    width: width
                )
            )
        }
        return stack
    }

    /// How loudly the repair is offered. See ``groupView(_:budget:refit:width:)``.
    private enum Refit {
        case quiet
        case prominent
    }

    /// One outcome: a tinted stripe, the reason once, and the ops it covers.
    private func groupView(
        _ group: LensState.NoteGroup,
        budget: inout Int,
        refit: Refit?,
        width: CGFloat
    ) -> NSView {
        let stripeWidth: CGFloat = 2
        let gap: CGFloat = 8
        let contentWidth = width - stripeWidth - gap

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false

        let heading = Self.line(
            group.title,
            colour: group.isDrift ? .systemOrange : .secondaryLabelColor,
            width: contentWidth
        )
        heading.font = .systemFont(ofSize: 10.5, weight: .semibold)
        column.addArrangedSubview(heading)

        let shown = max(0, min(budget, group.notes.count))
        budget -= shown
        for note in group.notes.prefix(shown) {
            column.addArrangedSubview(Self.noteRow(note, width: contentWidth))
        }
        if shown < group.notes.count {
            column.addArrangedSubview(
                Self.line(
                    "…and \(group.notes.count - shown) more",
                    colour: .tertiaryLabelColor,
                    width: contentWidth
                )
            )
        }
        // The heading counts what the page reported; these are the ops it named that
        // this lens no longer holds, because another window edited it while the page
        // kept running the shape it was handed. Without this line the heading simply
        // counts higher than the rows under it, for no reason the user can see.
        if group.hasUnnamed {
            column.addArrangedSubview(
                Self.line(
                    "this lens has been edited since the page loaded",
                    colour: .tertiaryLabelColor,
                    width: contentWidth
                )
            )
        }

        // Re-fit belongs to the drift block and nothing else — it asks the model for
        // fresh selectors, which repairs a stale anchor and does nothing whatever
        // for a budget skip. Its weight follows how much is actually broken: a
        // bordered button when the lens has stopped landing entirely, a quiet link
        // when one op of several has gone stale and the rest of the lens is fine.
        if group.isDrift, let refit {
            column.addArrangedSubview(refitButton(prominent: refit == .prominent))
        }

        let stripe = NSBox()
        stripe.boxType = .custom
        stripe.borderWidth = 0
        stripe.titlePosition = .noTitle
        stripe.fillColor = group.isDrift ? .systemOrange : .quaternaryLabelColor
        stripe.translatesAutoresizingMaskIntoConstraints = false

        let block = NSStackView(views: [stripe, column])
        block.orientation = .horizontal
        block.alignment = .top
        block.spacing = gap
        block.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stripe.widthAnchor.constraint(equalToConstant: stripeWidth),
            // The stripe is the group's left edge, so it has to be as tall as the
            // group; a stack view alone would leave it at its intrinsic zero height.
            stripe.heightAnchor.constraint(equalTo: column.heightAnchor),
            block.widthAnchor.constraint(equalToConstant: width),
        ])
        return block
    }

    /// The repair, at one of two weights. See ``groupView(_:budget:refit:width:)``.
    private func refitButton(prominent: Bool) -> NSButton {
        let target = ClosureTarget(action: { [weak self] in self?.onRefit?() })
        refitTarget = target
        let button = NSButton(
            title: prominent ? "Re-fit to This Page" : "Re-fit",
            target: target,
            action: #selector(ClosureTarget.fire)
        )
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.toolTip = "Ask the model for fresh selectors, from what this lens was for."
        if prominent {
            button.bezelStyle = .rounded
        } else {
            button.isBordered = false
            button.bezelStyle = .inline
            button.contentTintColor = .controlAccentColor
        }
        return button
    }

    /// One op: the user's sentence, and the anchor it went through.
    ///
    /// The sentence is in full label colour at the row's own size — it is the most
    /// informative text in this popover and it used to be drawn in the same muted
    /// tint as the boilerplate after it. The selector trails in tertiary mono,
    /// truncated in the middle because the ends of a selector are what identify it,
    /// and it is never allowed to squeeze the sentence below half the row.
    private static func noteRow(_ note: LensState.OpNote, width: CGFloat) -> NSView {
        let sentence = NSTextField(labelWithString: note.note)
        sentence.font = .systemFont(ofSize: 11)
        sentence.textColor = .labelColor
        sentence.lineBreakMode = .byWordWrapping
        sentence.maximumNumberOfLines = 2
        sentence.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sentence.setContentHuggingPriority(.defaultLow, for: .horizontal)

        guard let anchor = note.anchor else {
            sentence.preferredMaxLayoutWidth = width
            return sentence
        }

        let gap: CGFloat = 8
        sentence.preferredMaxLayoutWidth = width - Self.anchorWidth - gap

        let selector = NSTextField(labelWithString: anchor.selector)
        selector.font = .monospacedSystemFont(ofSize: 9.5, weight: .regular)
        selector.textColor = .tertiaryLabelColor
        selector.lineBreakMode = .byTruncatingMiddle
        selector.maximumNumberOfLines = 1
        selector.alignment = .right
        selector.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        selector.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        // Which of the two it is decides the sentence, and it is not cosmetic: the
        // popover must not imply an element was found where the page reported the
        // opposite.
        switch anchor {
        case .matched(let used):
            selector.toolTip = "The page matched \(used)"
        case .tried(let candidate):
            selector.toolTip = "The lens looked for \(candidate), and nothing on this page matched"
        }
        selector.translatesAutoresizingMaskIntoConstraints = false
        selector.widthAnchor.constraint(lessThanOrEqualToConstant: Self.anchorWidth).isActive = true

        let row = NSStackView(views: [sentence, selector])
        row.orientation = .horizontal
        // First baseline, so a sentence that wraps to two lines keeps the selector
        // level with its first line rather than floating in the middle of it.
        row.alignment = .firstBaseline
        // `.fill` rather than the default gravity areas: the selector belongs at the
        // right edge of the row, and gravity would park it against the sentence
        // wherever that happened to end, so a column of selectors would zig-zag.
        row.distribution = .fill
        row.spacing = gap
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    /// How much of a note row the selector may take.
    private static let anchorWidth: CGFloat = 116

    /// Op rows drawn per lens before the rest become a count.
    ///
    /// A lens may hold forty ops and every one of them can come back unapplied, so
    /// without a cap one bad lens owns the whole popover. Six is enough to read a
    /// pattern — the same rail named three different ways, say — and the headings
    /// above them still account for every op the page reported.
    private static let maxNoteRows = 6

    /// How far the explanation under a row is indented: past the checkbox, so the
    /// lines sit under the lens's name rather than under its switch. Seventeen
    /// points less than it was, which is the drag handle that used to sit in front
    /// of the checkbox and no longer does.
    private static let detailIndent: CGFloat = 13

    private static func line(_ text: String, colour: NSColor, width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = colour
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = width
        return label
    }

    private static func tallyLabel(_ text: String?, colour: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text ?? "")
        // Tabular figures, as in the toolbar badge: the column of tallies down the
        // list only reads as a column if the digits line up.
        label.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = colour
        label.toolTip = "Ops applied, out of ops in this lens — as reported by the page"
        return label
    }

    /// The proportion, as a bar: applied, then anything the page had a note about,
    /// then drift.
    ///
    /// The tally says `5/6` and `0/6` in the same four characters, and the whole
    /// complaint about this surface was that a lens mostly working and a lens
    /// entirely dead looked alike. A bar is read before a number is: a sliver of
    /// amber on the end of an accent bar is a different object from a bar that is
    /// all amber, at a glance and from the corner of the eye.
    ///
    /// Drawn only from ``LensState/Entry/report`` counts. There is no bar at all
    /// before the page reports, because a bar is a claim about proportions and we
    /// would not have one.
    private static func meter(for entry: LensState.Entry) -> NSView {
        let total = max(1, entry.totalCount)
        let counts = [
            entry.appliedCount,
            max(0, total - entry.appliedCount - entry.missedCount),
            entry.missedCount,
        ]
        let colours: [NSColor] = [.controlAccentColor, .quaternaryLabelColor, .systemOrange]
        let widths = Self.segmentWidths(counts, total: total, track: Self.meterWidth)

        let segments = NSStackView()
        segments.orientation = .horizontal
        segments.spacing = 0
        segments.translatesAutoresizingMaskIntoConstraints = false
        for (index, width) in widths.enumerated() where width > 0 {
            let segment = NSBox()
            segment.boxType = .custom
            segment.borderWidth = 0
            segment.titlePosition = .noTitle
            segment.fillColor = colours[index]
            segment.translatesAutoresizingMaskIntoConstraints = false
            segment.widthAnchor.constraint(equalToConstant: width).isActive = true
            segments.addArrangedSubview(segment)
        }

        let track = NSView()
        track.wantsLayer = true
        track.layer?.cornerRadius = Self.meterHeight / 2
        track.layer?.cornerCurve = .continuous
        track.layer?.masksToBounds = true
        track.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(segments)
        track.toolTip = entry.standing.needsAttention
            ? "\(entry.missedCount) of \(entry.totalCount) changes no longer match this page"
            : "\(entry.appliedCount) of \(entry.totalCount) changes applied"

        NSLayoutConstraint.activate([
            track.widthAnchor.constraint(equalToConstant: Self.meterWidth),
            track.heightAnchor.constraint(equalToConstant: Self.meterHeight),
            segments.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            segments.topAnchor.constraint(equalTo: track.topAnchor),
            segments.bottomAnchor.constraint(equalTo: track.bottomAnchor),
        ])
        return track
    }

    private static let meterWidth: CGFloat = 30
    private static let meterHeight: CGFloat = 3

    /// Segment widths that fill the track, with any non-zero share at least two
    /// points wide.
    ///
    /// One missed op out of forty is three quarters of a point on a thirty-point
    /// track — a segment nobody can see, which on this surface is a lie by
    /// omission. The floor is taken back off the widest segment, which is the only
    /// one with room to give it.
    private static func segmentWidths(
        _ counts: [Int],
        total: Int,
        track: CGFloat
    ) -> [CGFloat] {
        var widths = counts.map { count -> CGFloat in
            count <= 0 ? 0 : max(2, track * CGFloat(count) / CGFloat(total))
        }
        let overflow = widths.reduce(0, +) - track
        if overflow > 0, let widest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
            widths[widest] = max(0, widths[widest] - overflow)
        }
        return widths
    }

    /// A path pattern short enough to sit in a chip. The literal pattern is what the
    /// editor's scope control showed when the lens was saved, so it is worth showing
    /// verbatim — up to the point where it would push the name out of the row.
    private static func scope(_ pattern: String) -> String {
        pattern.count > 18 ? String(pattern.prefix(17)) + "…" : pattern
    }

    /// A small capsule. Used for states, never for counts.
    private static func chip(_ text: String, colour: NSColor, tip: String?) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = colour
        label.translatesAutoresizingMaskIntoConstraints = false

        // `NSBox`, not a layer background. `.cgColor` resolves the colour *now*,
        // against whatever appearance happens to be current, and then never
        // changes — so a chip built from `.secondaryLabelColor` keeps a light-mode
        // grey on a dark popover, and switching appearance with the popover open
        // leaves it there. The label above re-resolves because `textColor` takes a
        // dynamic `NSColor`; `fillColor` is the same deal for a fill, and it is
        // already how the stripes and the meter segments in this file are drawn.
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.cornerRadius = 4
        box.fillColor = colour.withAlphaComponent(0.14)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.toolTip = tip
        box.contentView = NSView()
        box.contentView?.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            box.heightAnchor.constraint(equalTo: label.heightAnchor, constant: 4),
        ])
        return box
    }

    // MARK: Events

    @objc private func toggled() {
        onToggle?(checkbox.state == .on)
    }

    @objc private func showMenu() {
        onMenu?(menuButton)
    }
}

/// A stack view that lays out from its top edge.
///
/// Only needed because it is a scroll view's document view: `NSClipView` positions
/// an unflipped document against the *bottom* of its content, so the list opened
/// already scrolled to the last lens on any site with enough of them to scroll.
private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}
