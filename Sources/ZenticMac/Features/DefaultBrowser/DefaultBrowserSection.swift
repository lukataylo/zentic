import AppKit
import SwiftUI

/// Settings › General: whether Zentic is the default browser, and the button
/// that asks macOS to make it so.
struct DefaultBrowserSection: View {
    private var model: DefaultBrowser { .shared }

    var body: some View {
        Section {
            switch model.status {
            case .isDefault:
                Label {
                    Text("Zentic is your default browser")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, .green)
                }
            case .notDefault:
                LabeledContent {
                    Button {
                        Task { await model.makeDefault() }
                    } label: {
                        Text(model.isAsking ? "Asking…" : "Make Default")
                    }
                    .disabled(model.isAsking)
                } label: {
                    Text("Zentic isn’t your default browser")
                    Text("Links you click in other apps open in your default browser.")
                }
            case .unavailable:
                LabeledContent("Default browser") {
                    Text("Available in Zentic.app")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { model.refresh() }
        // Changed in System Settings while Zentic was in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }
}
