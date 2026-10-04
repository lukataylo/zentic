import SwiftUI
import ZenticKit

/// Edit › AutoFill Password: the keyboard way to the suggestion menu, and the
/// way to it at all with automatic suggestions turned off.
struct PasswordCommands: Commands {
    @FocusedValue(Browser.self) private var browser

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Divider()
            Button("AutoFill Password") { browser?.selectedTab?.passwords.showMenuOnPage() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!SiteKey.isWeb(browser?.selectedTab?.url))
        }
    }
}
