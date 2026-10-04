import AppKit
import Observation

/// Whether Zentic is the browser other apps open links in, and the one way to
/// make it so: asking macOS, which asks the user.
///
/// Read when a view that shows it appears and whenever Zentic comes back to
/// the front (the user may have changed it in System Settings meanwhile) —
/// never at launch, and never on a timer.
@MainActor
@Observable
final class DefaultBrowser {
    static let shared = DefaultBrowser()

    enum Status {
        /// Run without an app bundle (`swift run`): there is nothing macOS
        /// could register.
        case unavailable
        case isDefault
        case notDefault
    }

    private(set) var status: Status = .notDefault
    /// macOS's confirmation is up.
    private(set) var isAsking = false

    private static let schemes = ["http", "https"]
    private let bundle = Bundle.main

    private init() { refresh() }

    func refresh() {
        guard bundle.bundleURL.pathExtension == "app", bundle.bundleIdentifier != nil else {
            status = .unavailable
            return
        }
        status = Self.schemes.allSatisfy(isOurs) ? .isDefault : .notDefault
    }

    /// Shows the system's "Change your default web browser?" prompt. Setting
    /// `http` normally moves `https` with it; `https` is only asked for
    /// separately if it did not, so the user is not asked twice.
    func makeDefault() async {
        guard status == .notDefault, !isAsking else { return }
        isAsking = true
        defer {
            isAsking = false
            refresh()
        }
        for scheme in Self.schemes where !isOurs(scheme) {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: bundle.bundleURL, toOpenURLsWithScheme: scheme)
            } catch {
                // Declined. Nothing to report: the button is still there.
                return
            }
        }
    }

    /// By identifier, not path: any copy of Zentic being the default counts —
    /// a fresh build, or the one in Applications.
    private func isOurs(_ scheme: String) -> Bool {
        let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "\(scheme)://example.com")!)
        return handler.flatMap { Bundle(url: $0)?.bundleIdentifier } == bundle.bundleIdentifier
    }
}
