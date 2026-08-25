import AppKit
import Testing

@testable import ZenticMac

@Suite("spike")
struct Spike {
    @MainActor
    @Test("main does not run")
    func mainDoesNotRun() {
        #expect(NSApplication.shared.delegate == nil)
        #expect(!NSApplication.shared.isRunning)
    }
}
