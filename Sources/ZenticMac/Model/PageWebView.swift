import AppKit
import WebKit

/// A tab's web view, with the link menu a Mac browser is expected to have.
///
/// WebKit's own context menu offers "Open Link in New Window" and nothing for
/// tabs. Its item is kept — it is what makes WebKit ask for a new web view
/// with the right opener, referrer and policy — and Zentic adds "Open Link in
/// New Tab" (and "Open Image in New Tab") beside it. Each item notes what the
/// person chose, then lets WebKit's own action run; `createWebViewWith` reads
/// the note to decide where the page goes.
final class PageWebView: WKWebView {
    enum LinkIntent {
        case backgroundTab
        case window
    }

    /// What the last menu choice asked for, consumed by the next new web view.
    private var linkIntent: LinkIntent?

    func takeLinkIntent() -> LinkIntent? {
        defer { linkIntent = nil }
        return linkIntent
    }

    private static let newWindowItems: [String: String] = [
        "WKMenuItemIdentifierOpenLinkInNewWindow": "Open Link in New Tab",
        "WKMenuItemIdentifierOpenImageInNewWindow": "Open Image in New Tab",
    ]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        linkIntent = nil
        for (index, item) in menu.items.enumerated().reversed() {
            guard let id = item.identifier?.rawValue, let title = Self.newWindowItems[id],
                let action = item.action
            else { continue }

            // WebKit's item, re-pointed so a choice is noted before it runs.
            let original = Original(target: item.target, action: action)
            item.target = self
            item.action = #selector(openInWindow(_:))
            item.representedObject = original

            let tabItem = NSMenuItem(title: title, action: #selector(openInTab(_:)), keyEquivalent: "")
            tabItem.target = self
            tabItem.representedObject = original
            menu.insertItem(tabItem, at: index)
        }
    }

    @objc private func openInTab(_ sender: NSMenuItem) {
        perform(sender, as: .backgroundTab)
    }

    @objc private func openInWindow(_ sender: NSMenuItem) {
        perform(sender, as: .window)
    }

    private func perform(_ sender: NSMenuItem, as intent: LinkIntent) {
        guard let original = sender.representedObject as? Original else { return }
        linkIntent = intent
        NSApp.sendAction(original.action, to: original.target, from: sender)
        // If WebKit did not ask for a web view (a blocked or failed open), the
        // note must not leak into the page's next window.open.
        DispatchQueue.main.async { [weak self] in self?.linkIntent = nil }
    }

    private final class Original: NSObject {
        let target: AnyObject?
        let action: Selector
        init(target: AnyObject?, action: Selector) {
            self.target = target
            self.action = action
        }
    }
}
