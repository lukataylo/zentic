import SwiftUI
import ZenticKit

/// History › Recently Closed: this window's closed tabs, newest first, and
/// the window closed most recently.
struct RecentlyClosedMenu: View {
    /// The browser the menu speaks for — the focused one, or the one in front
    /// while History or Settings is key.
    let browser: Browser?
    private static let limit = 15

    var body: some View {
        let tabs = Array((browser?.closed ?? []).suffix(Self.limit).reversed())
        let window = Windows.shared.recentlyClosedWindowTitle
        Menu("Recently Closed") {
            ForEach(tabs, id: \.id) { saved in
                Button(Self.title(of: saved)) { browser?.reopenClosed(saved.id) }
            }
            if let window {
                if !tabs.isEmpty { Divider() }
                Button(window) { Windows.shared.reopenClosedWindow() }
            }
        }
        .disabled(tabs.isEmpty && window == nil)
    }

    private static func title(of saved: Tab.Saved) -> String {
        let host = URLGuess.displayHost(saved.url)
        let title = saved.title.trimmingCharacters(in: .whitespaces)
        // Menu items are one line; a page title can be a paragraph.
        let name = title.isEmpty ? host : title
        return name.count > 60 ? name.prefix(59) + "…" : name
    }
}
