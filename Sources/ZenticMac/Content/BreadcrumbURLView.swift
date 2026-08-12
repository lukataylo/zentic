import AppKit

/// The address display: **`linkedin.com`** ` / Post`.
///
/// Domain in bold at full label contrast, path in secondary grey, path separators
/// replaced with a spaced slash and each segment title-cased. This is the one piece
/// of chrome that tells you where you are at a glance rather than making you read a
/// URL, which is why it is worth drawing by hand instead of showing a text field.
///
/// Clicking (or ⌘L) swaps in a real editable field, because a breadcrumb you cannot
/// type into is a demo, not an address bar.
final class BreadcrumbURLView: ChromeView {
    /// Called when the user commits an edit. The string is raw user input — a URL,
    /// a bare host, or a search phrase.
    var onSubmit: ((String) -> Void)?

    private let display = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private let lockIcon = NSImageView()

    private var url: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous

        lockIcon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Secure")
        lockIcon.contentTintColor = .tertiaryLabelColor
        lockIcon.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        lockIcon.translatesAutoresizingMaskIntoConstraints = false

        display.lineBreakMode = .byTruncatingTail
        display.maximumNumberOfLines = 1
        display.cell?.usesSingleLineMode = true
        display.translatesAutoresizingMaskIntoConstraints = false

        field.isHidden = true
        field.font = .systemFont(ofSize: 12.5)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.target = self
        field.action = #selector(commitEdit)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        addSubview(lockIcon)
        addSubview(display)
        addSubview(field)

        NSLayoutConstraint.activate([
            lockIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            lockIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            lockIcon.widthAnchor.constraint(equalToConstant: 10),

            display.leadingAnchor.constraint(equalTo: lockIcon.trailingAnchor, constant: 6),
            display.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            display.centerYAnchor.constraint(equalTo: centerYAnchor),

            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        applyLayerColors()
    }

    override func updateLayerColors() {
        let dark = isDarkAppearance
        layer?.borderWidth = Chrome.glassStrokeWidth
        if isEditing {
            // Editing is the one moment the field stops being glass: a text cursor
            // and an autocomplete selection need an opaque ground to stay legible.
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
        } else {
            layer?.backgroundColor = Glass.hoverFill(dark: dark).cgColor
            layer?.borderColor = Glass.stroke(dark: dark).cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var isEditing: Bool { !field.isHidden }

    func show(url: URL?, isLoading: Bool) {
        self.url = url
        guard !isEditing else { return }

        lockIcon.isHidden = url?.scheme != "https"
        display.attributedStringValue = Self.breadcrumb(for: url, dimmed: isLoading)
        toolTip = url?.absoluteString
    }

    /// Enter edit mode with the full URL selected, matching every other browser's
    /// ⌘L: the user's next keystroke replaces the whole address.
    func beginEditing() {
        field.stringValue = url?.absoluteString ?? ""
        field.isHidden = false
        display.isHidden = true
        lockIcon.isHidden = true
        applyLayerColors()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func endEditing() {
        guard isEditing else { return }
        field.isHidden = true
        display.isHidden = false
        applyLayerColors()
        show(url: url, isLoading: false)
        if window?.firstResponder === field.currentEditor() {
            window?.makeFirstResponder(nil)
        }
    }

    @objc private func commitEdit() {
        let text = field.stringValue
        endEditing()
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSubmit?(text)
    }

    override func mouseDown(with event: NSEvent) {
        beginEditing()
    }

    // MARK: - Breadcrumb construction

    private static func breadcrumb(for url: URL?, dimmed: Bool) -> NSAttributedString {
        let domainFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let pathFont = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        let domainColor: NSColor = dimmed ? .secondaryLabelColor : .labelColor

        guard let url, let host = url.host() else {
            return NSAttributedString(
                string: url?.absoluteString ?? "Search or enter address",
                attributes: [.font: pathFont, .foregroundColor: NSColor.tertiaryLabelColor]
            )
        }

        let result = NSMutableAttributedString(
            string: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host,
            attributes: [.font: domainFont, .foregroundColor: domainColor]
        )

        let segments = url.pathComponents
            .filter { $0 != "/" && !$0.isEmpty }
            .map(prettify)
        for segment in segments {
            result.append(
                NSAttributedString(
                    string: "  /  \(segment)",
                    attributes: [.font: pathFont, .foregroundColor: NSColor.secondaryLabelColor]
                )
            )
        }
        return result
    }

    /// `some-post-title` → `Some Post Title`, and long slugs are truncated.
    ///
    /// Percent-decoded and de-hyphenated because the point of the breadcrumb is to
    /// be read, and `%E2%80%99` in the middle of a headline defeats that.
    private static func prettify(_ segment: String) -> String {
        let decoded = segment.removingPercentEncoding ?? segment
        let words = decoded
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map { $0.count <= 3 ? String($0) : $0.capitalized }
        let joined = words.joined(separator: " ")
        return joined.count > 28 ? String(joined.prefix(27)) + "…" : joined
    }
}

extension BreadcrumbURLView: NSTextFieldDelegate {
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endEditing()
            return true
        }
        return false
    }
}
