import SwiftUI
import ZenticKit

/// Said once, quietly, after Zentic comes back from an unexpected quit.
struct RecoveryToast: View {
    let outcome: LaunchGuard.Outcome
    var dismiss: () -> Void
    /// Opens the report about the quit, to read and, if they choose, send.
    var sendReport: () -> Void
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(Color.accentColor.gradient)
                .symbolEffect(.rotate, value: appeared)
            VStack(alignment: .leading, spacing: 1) {
                Text("Zentic quit unexpectedly — your tabs are back.")
                    .font(.callout.weight(.medium))
                if outcome == .recoveredRepeatedly {
                    Text("Pages will load when you click them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Send Report…", action: sendReport)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .help("See what Zentic recorded about the quit, and email it to the developer if you like")
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .panelGlass(in: .capsule)
        .accessibilityElement(children: .contain)
        .task {
            appeared = true
            AccessibilityNotification.Announcement("Zentic quit unexpectedly. Your tabs are back.").post()
            // Long enough to reach Send Report… without hurrying.
            // A cancelled wait means the view went away, not that time is up:
            // dismissing then would take the notice down before anyone saw it.
            guard (try? await Task.sleep(for: .seconds(outcome == .recoveredRepeatedly ? 14 : 10))) != nil
            else { return }
            dismiss()
        }
    }
}

/// The selected tab, held back after repeated crashes on launch: what it was,
/// and one click to load it.
struct HeldTabView: View {
    let tab: Tab

    var body: some View {
        VStack(spacing: 12) {
            SiteIcon(image: tab.icon, size: 40)
                .padding(.bottom, 4)
            Text(tab.title.isEmpty ? tab.displayHost : tab.title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text("Not loaded, in case it is what made Zentic quit.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Load Page") { tab.realize() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
