import SwiftUI
import ZenticKit

/// Settings › General › iCloud: the switch, and a plain account of where
/// sync stands. Absent from a build that cannot use iCloud at all.
struct TabSyncSettings: View {
    private var sync: TabSync { .shared }

    var body: some View {
        if TabSync.isSupported {
            @Bindable var sync = sync
            Section("iCloud") {
                Toggle(isOn: $sync.isEnabled) {
                    Text("Sync tabs with iCloud")
                    Text("Your other Macs show this Mac’s open and pinned tabs, and you see theirs. Private windows, history and site settings never sync.")
                }
                if sync.isEnabled {
                    LabeledContent {
                        Button("Sync Now") { sync.syncNow() }
                            .disabled(sync.status == .starting || sync.status == .syncing)
                    } label: {
                        status
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let problem = sync.problem {
            Label(problem, systemImage: "exclamationmark.icloud")
                .foregroundStyle(.orange)
        } else {
            switch sync.status {
            case .off:
                EmptyView()
            case .starting, .syncing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(sync.status == .starting ? "Connecting to iCloud…" : "Syncing…")
                        .foregroundStyle(.secondary)
                }
            case .unavailable(let reason):
                Label(reason, systemImage: "icloud.slash")
                    .foregroundStyle(.secondary)
            case .synced(let date?):
                Label {
                    // Re-rendered each minute, so "Last synced" never sits at a stale "now".
                    TimelineView(.everyMinute) { _ in
                        Text("Last synced \(date, format: .relative(presentation: .named))")
                    }
                } icon: {
                    Image(systemName: "checkmark.icloud")
                        .foregroundStyle(.green)
                }
                .foregroundStyle(.secondary)
            case .synced(nil):
                Label("Waiting for the first sync", systemImage: "icloud")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
