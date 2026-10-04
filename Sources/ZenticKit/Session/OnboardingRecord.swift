import Foundation

/// Whether the welcome tour is due. Stored as the version last seen, so a
/// later tour with something genuinely new to say can ask to be shown once
/// more by raising `current`, without showing the old one twice.
public enum OnboardingRecord {
    /// Raise only when the tour has changed enough to be worth a returning
    /// user's minute.
    public static let current = 1
    static let key = "onboardingVersionSeen"

    public static func isDue(in defaults: UserDefaults) -> Bool {
        defaults.integer(forKey: key) < current
    }

    public static func markSeen(in defaults: UserDefaults) {
        // Never lower it: an older build run once must not re-arm the tour
        // for a newer one.
        defaults.set(max(defaults.integer(forKey: key), current), forKey: key)
    }
}
