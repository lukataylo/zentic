import Foundation

/// Turns a two-finger trackpad gesture into at most one space switch.
///
/// Fed the gesture's deltas in physical terms (positive x = fingers moved
/// right, whatever the scrolling-direction setting). Fires once per gesture,
/// and only for a clearly horizontal one, so scrolling the tab list never
/// changes space by accident.
public struct SpaceSwipe: Sendable {
    public enum Direction: Equatable, Sendable { case next, previous }

    /// Points of horizontal travel before a swipe counts.
    public static let threshold = 60.0

    private var x = 0.0
    private var y = 0.0
    private var fired = false

    public init() {}

    /// Fingers touched down: a new gesture.
    public mutating func begin() {
        x = 0
        y = 0
        fired = false
    }

    public mutating func move(dx: Double, dy: Double) -> Direction? {
        guard !fired else { return nil }
        x += dx
        y += dy
        // Twice as far across as down: a diagonal flick through a long tab
        // list is a scroll.
        guard abs(x) >= Self.threshold, abs(x) > abs(y) * 2 else { return nil }
        fired = true
        // Fingers moving left pull the next space in from the right, as
        // between full-screen apps.
        return x < 0 ? .next : .previous
    }
}
