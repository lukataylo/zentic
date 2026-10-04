import Foundation
import Testing

@testable import ZenticKit

@Suite struct OnboardingRecordTests {
    /// A scratch defaults domain, removed after the test so runs do not
    /// leave a preferences file behind each time.
    private func withFreshDefaults(_ body: (UserDefaults) -> Void) {
        let name = "zentic-onboarding-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test func dueOnFirstRunAndNotOnceSeen() {
        withFreshDefaults { defaults in
            #expect(OnboardingRecord.isDue(in: defaults))
            OnboardingRecord.markSeen(in: defaults)
            #expect(!OnboardingRecord.isDue(in: defaults))
        }
    }

    @Test func aNewerTourIsShownToSomeoneWhoSawAnOlderOne() {
        withFreshDefaults { defaults in
            defaults.set(OnboardingRecord.current - 1, forKey: OnboardingRecord.key)
            #expect(OnboardingRecord.isDue(in: defaults))
        }
    }

    @Test func anOlderBuildDoesNotRearmANewerTour() {
        withFreshDefaults { defaults in
            defaults.set(OnboardingRecord.current + 1, forKey: OnboardingRecord.key)
            OnboardingRecord.markSeen(in: defaults)
            #expect(defaults.integer(forKey: OnboardingRecord.key) == OnboardingRecord.current + 1)
        }
    }
}
