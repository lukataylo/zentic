import SwiftUI
import ZenticKit

/// The welcome tour: shown once over the first ordinary window, and again
/// from Help › Welcome to Zentic.
@MainActor
@Observable
final class Onboarding {
    static let shared = Onboarding()

    /// The window the tour is shown over, while it is up.
    private(set) var browserID: UUID?
    /// Asked for from the Help menu with no window open: shown over the
    /// window that opens for it.
    @ObservationIgnored private var requested = false

    private init() {}

    func windowAppeared(_ browser: Browser) {
        guard browserID == nil, !browser.isPrivate,
            requested || OnboardingRecord.isDue(in: DataDirectory.defaults)
        else { return }
        requested = false
        browserID = browser.id
    }

    /// Help › Welcome to Zentic.
    func show(over browser: Browser?) {
        // Already up — unless its window was closed with the tour still on it.
        if let browserID, Windows.shared.open.contains(where: { $0.id == browserID }) { return }
        guard let browser = browser ?? Windows.shared.frontmost else {
            browserID = nil
            requested = true
            return Windows.shared.newWindow(private: false)
        }
        browser.window?.makeKeyAndOrderFront(nil)
        browserID = browser.id
    }

    func finish() {
        OnboardingRecord.markSeen(in: DataDirectory.defaults)
        browserID = nil
    }
}

extension View {
    /// Presents the welcome tour over this window when it is due.
    func onboarding(for browser: Browser) -> some View {
        modifier(OnboardingPresentation(browser: browser))
    }
}

private struct OnboardingPresentation: ViewModifier {
    let browser: Browser

    func body(content: Content) -> some View {
        // Read here, in `body`, so the sheet follows it.
        let shown = Onboarding.shared.browserID == browser.id
        content
            .task {
                // Let the window settle before the sheet comes down over it.
                try? await Task.sleep(for: .milliseconds(450))
                Onboarding.shared.windowAppeared(browser)
            }
            .sheet(isPresented: Binding(get: { shown }, set: { if !$0 { Onboarding.shared.finish() } })) {
                OnboardingView { Onboarding.shared.finish() }
                    .environment(AppModel.shared)
            }
    }
}
