import Foundation

/// Whether this process is one of Zentic's own test runs: the test bundle
/// itself (`swift test`, `xcodebuild test`, where XCTest is loaded), or the app
/// launched by the UI tests with ``argument``.
///
/// A test run touches nothing it was not asked to. Its data goes to a directory
/// of its own (``DataDirectory``), even when nobody set `ZENTIC_DATA_DIR`, and
/// the app fetches nothing a test did not load itself: no filter lists beyond
/// the bundled seed, no Safe Browsing lists, no first page and no favourites
/// whose icons it would go and get. A test that passes only with the internet
/// up is a test that fails on a train.
public enum TestRun {
    /// What the UI tests launch the app with.
    public static let argument = "--ui-testing"

    public static let isActive = NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.arguments.contains(argument)
}
