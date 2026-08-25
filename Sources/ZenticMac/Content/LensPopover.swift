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
                .map { "\($0.note)=\($0.status.rawValue)=\($0.detail)" }
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

    private let rowsStack = NSStackView()
    /// AppKit holds targets weakly, so the closures behind the footer links and the
    /// row menus need an owner for as long as the popover is up.
    private var buttonTargets: [ClosureTarget] = []
    weak var popover: NSPopover?

    /// Popover width. Wide enough for a name, a tally and the actions button on one
    /// line, and for a missed op's note to read as a sentence underneath.
    private static let width: CGFloat = 340

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
        rowsStack.spacing = 2
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        for row in rows { rowsStack.addArrangedSubview(makeRow(row)) }
        if rows.isEmpty { rowsStack.addArrangedSubview(emptyState()) }
        container.addArrangedSubview(rowsStack)

        container.addArrangedSubview(separator())
        container.addArrangedSubview(footer())

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.width),
            rowsStack.widthAnchor.constraint(equalToConstant: Self.width - 28),
        ])
        view = container
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

/// One lens: a switch, a name, what it did, and why part of it did not.
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

        var trailing: [NSView] = []
        if let tally = row.entry?.tally {
            trailing.append(Self.tallyLabel(tally, drifted: row.entry?.isDrifted ?? false))
        }
        if row.entry?.isDrifted ?? false {
            trailing.append(Self.chip("drift", colour: .systemOrange))
        } else if row.entry == nil, row.lens.isEnabled {
            // On, but scoped to a path this page is not on. Said plainly, because a
            // lens working perfectly on `/watch` otherwise looks, from the home
            // page, exactly like one that has stopped working.
            trailing.append(Self.chip(Self.scope(row.lens.pathPattern), colour: .secondaryLabelColor))
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

    /// The part of the row that explains itself: every op that did not simply
    /// apply, in the user's own words for it.
    ///
    /// Shown expanded rather than behind a disclosure triangle. A drifted lens is
    /// the one thing in this popover that needs the user to do something, and a
    /// row that hides why it is amber until clicked is a row that will be ignored.
    ///
    /// One line per ``LensState/OpNote``, unconditionally, which is what makes
    /// every ``LensOpStatus`` visible somewhere. It used to be two hand-picked
    /// lists — the `missed` ops, and the `skipped` ones — so an op reported
    /// `ambiguous` or `failed` counted against the tally and then appeared nowhere:
    /// the row said `3/4` and offered no account of the fourth.
    private func detail(for row: LensPopover.Row, width: CGFloat) -> NSView? {
        let entry = row.entry
        let notes = entry?.notes ?? []

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

        guard !notes.isEmpty || history != nil || suppression != nil || entry?.canRefit == true
        else { return nil }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: Self.detailIndent, bottom: 2, right: 0)

        if let history {
            stack.addArrangedSubview(
                Self.line(history, colour: .tertiaryLabelColor, width: width)
            )
        }

        if let suppression {
            stack.addArrangedSubview(
                Self.line(suppression, colour: .secondaryLabelColor, width: width)
            )
        }

        // Amber for drift, because it is the only one of these the user can act on
        // and the only one that means the site changed. Everything else is the page
        // telling us what it did with an op, which is information, not a warning.
        for note in notes {
            stack.addArrangedSubview(
                Self.line(
                    "\(note.note) — \(note.detail)",
                    colour: note.isDrift ? .systemOrange : .secondaryLabelColor,
                    width: width
                )
            )
        }
        // Drift with nothing to list is a real state, not a contradiction: the page
        // is still running the shape of the lens it was handed, so it can report op
        // ids another window has already edited away. The row was amber with nothing
        // under it and no button, which put the one action that repairs it out of
        // reach exactly when it was needed.
        if let entry, entry.isDrifted, entry.driftNotes.isEmpty {
            stack.addArrangedSubview(
                Self.line(
                    "\(entry.missedCount) of \(entry.totalCount) changes did not match — "
                        + "this lens has been edited since the page loaded",
                    colour: .systemOrange,
                    width: width
                )
            )
        }

        if entry?.canRefit == true {
            let target = ClosureTarget(action: { [weak self] in self?.onRefit?() })
            refitTarget = target
            let button = NSButton(
                title: "Re-fit to This Page",
                target: target,
                action: #selector(ClosureTarget.fire)
            )
            button.bezelStyle = .inline
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.contentTintColor = .controlAccentColor
            button.toolTip = "Ask the model for fresh selectors, from what this lens was for."
            stack.addArrangedSubview(button)
        }
        return stack
    }

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

    private static func tallyLabel(_ text: String, drifted: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        // Tabular figures, as in the toolbar badge: the column of tallies down the
        // list only reads as a column if the digits line up.
        label.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = drifted ? .systemOrange : .secondaryLabelColor
        label.toolTip = "Ops applied, out of ops in this lens — as reported by the page"
        return label
    }

    /// A path pattern short enough to sit in a chip. The literal pattern is what the
    /// editor's scope control showed when the lens was saved, so it is worth showing
    /// verbatim — up to the point where it would push the name out of the row.
    private static func scope(_ pattern: String) -> String {
        pattern.count > 18 ? String(pattern.prefix(17)) + "…" : pattern
    }

    /// A small capsule. Used for states, never for counts.
    private static func chip(_ text: String, colour: NSColor) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = colour
        label.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 4
        box.layer?.cornerCurve = .continuous
        box.layer?.backgroundColor = colour.withAlphaComponent(0.14).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
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
