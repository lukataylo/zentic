import SwiftUI
import ZenticKit

#if canImport(Sparkle)
import Sparkle

/// Software update, by Sparkle: the app's feed and public key are in
/// Info.plist, and every update is checked against that key (and the feed
/// against its signature) before anything is installed.
///
/// An update check fetches the appcast from GitHub and nothing else: no system
/// profile, no identifiers. `swift run` builds have no Sparkle and no updates.
@MainActor
@Observable
final class Updates {
    static let shared = Updates()

    /// A copy isolated by `ZENTIC_DATA_DIR` never updates itself. It is a test
    /// run, and Sparkle keeps its settings in the app's real preferences,
    /// which an isolated run must not touch.
    let isEnabled = !DataDirectory.isIsolated

    private(set) var canCheck = false
    private(set) var lastChecked: Date?

    var automaticallyChecks = false {
        didSet {
            if updater.automaticallyChecksForUpdates != automaticallyChecks {
                updater.automaticallyChecksForUpdates = automaticallyChecks
            }
        }
    }

    var automaticallyDownloads = false {
        didSet {
            if updater.automaticallyDownloadsUpdates != automaticallyDownloads {
                updater.automaticallyDownloadsUpdates = automaticallyDownloads
            }
        }
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    private var updater: SPUUpdater { controller.updater }

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: isEnabled, updaterDelegate: nil, userDriverDelegate: nil)
        // Sparkle changes these itself — its first-run question, a check
        // finishing — so the settings follow it rather than a copy.
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheck = self?.isEnabled == true && updater.canCheckForUpdates }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.lastChecked = updater.lastUpdateCheckDate }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.automaticallyChecks = updater.automaticallyChecksForUpdates }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.automaticallyDownloads = updater.automaticallyDownloadsUpdates }
            },
        ]
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
#endif

/// "Check for Updates…" in the app menu, below About.
struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            #if canImport(Sparkle)
            Button("Check for Updates…") { Updates.shared.checkForUpdates() }
                .disabled(!Updates.shared.canCheck)
            #endif
        }
    }
}

/// Settings › General › Software Update.
struct SoftwareUpdateSection: View {
    var body: some View {
        #if canImport(Sparkle)
        @Bindable var updates = Updates.shared
        Section {
            Toggle("Automatically check for updates", isOn: $updates.automaticallyChecks)
            Toggle("Automatically download and install", isOn: $updates.automaticallyDownloads)
                .disabled(!updates.automaticallyChecks)
            LabeledContent {
                Button("Check Now") { updates.checkForUpdates() }
                    .disabled(!updates.canCheck)
            } label: {
                Text("Zentic \(Bundle.main.zenticVersion)")
                Text(lastCheckedText(updates.lastChecked))
            }
        } header: {
            Text("Software Update")
        } footer: {
            Text(
                updates.isEnabled
                    ? "Updates come from GitHub, signed by the developer; Zentic checks the signature before installing. A check sends nothing about you or your browsing."
                    : "Off in this test copy: ZENTIC_DATA_DIR keeps it away from your real settings, and Sparkle keeps its settings with the app’s."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .disabled(!updates.isEnabled)
        #else
        EmptyView()
        #endif
    }

    private func lastCheckedText(_ date: Date?) -> String {
        guard let date else { return "Not checked yet" }
        return "Last checked \(date.formatted(.relative(presentation: .named)))"
    }
}
