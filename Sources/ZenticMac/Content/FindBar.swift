import AppKit

/// ⌘F find-in-page.
///
/// Thin by design: `WKWebView.find(_:configuration:)` already does the searching
/// and highlighting, so the bar's only jobs are holding the query and reporting
/// "not found" — which it does by tinting the field, since a browser that silently
/// does nothing on a failed search feels broken.
final class FindBar: ChromeView {
    var onSearch: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?

    private let field = NSTextField()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        field.placeholderString = "Find in page"
        field.font = .systemFont(ofSize: 12)
        field.bezelStyle = .roundedBezel
        field.target = self
        field.action = #selector(searchForwards)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        configure(previousButton, symbol: "chevron.up", action: #selector(searchBackwards))
        configure(nextButton, symbol: "chevron.down", action: #selector(searchForwards))
        configure(closeButton, symbol: "xmark", action: #selector(close))

        // The controller collapses this bar to zero height instead of hiding it, so
        // its contents must not spill out when closed.
        clipsToBounds = true

        addSubview(field)
        let buttons = NSStackView(views: [previousButton, nextButton, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 2
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)

        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.contentInset + 4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 240),
            buttons.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 6),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func configure(_ button: NSButton, symbol: String, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .inline
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func reportMatch(_ found: Bool) {
        field.textColor = found || field.stringValue.isEmpty ? .labelColor : .systemRed
    }

    @objc private func searchForwards() { onSearch?(field.stringValue, true) }
    @objc private func searchBackwards() { onSearch?(field.stringValue, false) }
    @objc private func close() { onClose?() }
}

extension FindBar: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        // Incremental search: WebKit's find is cheap enough per keystroke, and
        // waiting for Return to see anything is the wrong feel for a find bar.
        onSearch?(field.stringValue, true)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        return false
    }
}
