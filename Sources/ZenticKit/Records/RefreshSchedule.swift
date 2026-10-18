import Foundation

/// When a background visit to a source may happen.
///
/// Pure, so the pacing rules are tested rather than trusted: a signed-in visit
/// waits at least the interval since the last one — plus jitter, so visits never
/// land on a clock-shaped schedule — and stops for the day at a cap, however
/// often the app asks.
public struct RefreshSchedule: Sendable, Equatable {
    public var interval: TimeInterval
    public var perDay: Int
    /// Fraction of the interval added at random, 0…1.
    public var jitter: Double

    public static let session = RefreshSchedule(
        interval: LibraryBudget.sessionRefreshInterval, perDay: LibraryBudget.sessionVisitsPerDay, jitter: 0.35)
    public static let signedOut = RefreshSchedule(
        interval: TimeInterval(LibraryBudget.sourceRefreshInterval.components.seconds), perDay: 96, jitter: 0.1)

    public init(interval: TimeInterval, perDay: Int, jitter: Double) {
        self.interval = interval
        self.perDay = perDay
        self.jitter = jitter
    }

    /// Whether a visit may start now, given the earlier ones (any order).
    ///
    /// - Parameter roll: 0…1, the jitter's draw for this decision. A parameter so
    ///   tests can pin it; callers pass a random number.
    public func mayVisit(now: Date, previous: [Date], roll: Double, calendar: Calendar = .current) -> Bool {
        let today = previous.filter { calendar.isDate($0, inSameDayAs: now) }
        guard today.count < perDay else { return false }
        guard let last = previous.max() else { return true }
        let wait = interval * (1 + jitter * min(max(roll, 0), 1))
        return now.timeIntervalSince(last) >= wait
    }
}
