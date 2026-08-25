import AppKit
import Testing

@testable import ZenticMac

/// The shell's own test target.
///
/// It exists for one reason: `ZenticMac` is where the original inert-lens defect
/// lived — `LensStore` instantiated nowhere, `generateLens` with no caller,
/// `ReaderConfiguration.lenses` never populated — and none of that layer was
/// executed by a test, so 259 green tests said nothing about it.
///
/// The test below is the precondition for the target being safe at all.
/// `ZenticMac` is an `.executableTarget` whose `main.swift` ends in
/// `NSApplication.shared.run()`. SwiftPM is supposed to keep that entry point out
/// of a test bundle, but "supposed to" is how a suite ends up hanging in CI
/// waiting on a run loop nobody can see. This asserts it, so the day that changes
/// we get a failure rather than a timeout.
@Suite("App target")
struct AppTargetTests {
    @MainActor
    @Test("Linking the shell into tests does not start the app")
    func mainDoesNotRun() {
        #expect(NSApplication.shared.delegate == nil)
        #expect(!NSApplication.shared.isRunning)
    }
}
