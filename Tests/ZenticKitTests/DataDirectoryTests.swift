import Foundation
import Testing

@testable import ZenticKit

@Suite struct DataDirectoryTests {
    @Test func withoutTheVariableDataLivesInApplicationSupport() {
        let url = DataDirectory.resolve([:])
        #expect(url == URL.applicationSupportDirectory.appending(path: "Zentic", directoryHint: .isDirectory))
    }

    @Test func anEmptyVariableDoesNotRedirectToTheWorkingDirectory() {
        // `ZENTIC_DATA_DIR= swift run` must not scatter files into the repo.
        #expect(DataDirectory.override(in: ["ZENTIC_DATA_DIR": "  "]) == nil)
        #expect(DataDirectory.resolve(["ZENTIC_DATA_DIR": ""]) == DataDirectory.resolve([:]))
    }

    @Test func theVariableRedirectsAndExpandsTilde() {
        #expect(DataDirectory.resolve(["ZENTIC_DATA_DIR": "/tmp/zentic-a/"]).path == "/tmp/zentic-a")
        let home = DataDirectory.resolve(["ZENTIC_DATA_DIR": "~/zentic-b"]).path
        #expect(home == NSHomeDirectory() + "/zentic-b")
    }

    /// `swift test` with nothing set must not open the user's real history,
    /// session and passwords: the tests drive the real app model.
    @Test func aTestRunNeverFallsThroughToTheRealData() {
        let real = DataDirectory.resolve([:])
        #expect(DataDirectory.resolve([:], testRun: true) != real)
        #expect(DataDirectory.resolve(["ZENTIC_DATA_DIR": "/tmp/zentic-a"], testRun: true).path == "/tmp/zentic-a")
        // And this process is one.
        #expect(TestRun.isActive)
        #expect(DataDirectory.isIsolated)
        #expect(DataDirectory.root != real)
    }

    @Test func eachDirectoryGetsItsOwnStableCookieStore() {
        let a = URL(filePath: "/tmp/zentic-a")
        // Stable across launches, or every relaunch would sign the user out.
        #expect(DataDirectory.storeID(for: a) == DataDirectory.storeID(for: URL(filePath: "/tmp/zentic-a/")))
        #expect(DataDirectory.storeID(for: a) != DataDirectory.storeID(for: URL(filePath: "/tmp/zentic-b")))
    }
}
