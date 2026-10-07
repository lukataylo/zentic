import SwiftUI

/// ⌘F. A small pill under the toolbar, like Safari's find banner made quieter.
struct FindBar: View {
    @Environment(Browser.self) private var browser
    let tab: Tab
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var browser = browser
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Find on page", text: $browser.findBar.text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 180)
                .focused($focused)
                .accessibilityIdentifier("find")
                .onSubmit { find(backwards: false) }
                .onChange(of: browser.findBar.text) { find(backwards: false) }
            if browser.findBar.notFound && !browser.findBar.text.isEmpty {
                Text("Not found")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Divider().frame(height: 14)
            Button { find(backwards: true) } label: { Image(systemName: "chevron.up") }
                .help("Previous (⇧⌘G)")
            Button { find(backwards: false) } label: { Image(systemName: "chevron.down") }
                .help("Next (⌘G)")
            Button("Done") { close() }
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 12)
        .frame(height: 34)
        .panelGlass(in: .capsule)
        // Focused a turn after appearing. Asked for while the field is
        // still being put on screen, SwiftUI hands the keyboard to the page's
        // web view instead, and typing goes to the page.
        .onAppear { Task { focused = true } }
        .onExitCommand { close() }
        .animation(.easeOut(duration: 0.15), value: browser.findBar.notFound)
    }

    private func find(backwards: Bool) {
        let text = browser.findBar.text
        Task { browser.findBar.notFound = !(await tab.find(text, backwards: backwards)) }
    }

    private func close() {
        browser.findBar.isPresented = false
        Task { _ = await tab.find("") }
    }
}
