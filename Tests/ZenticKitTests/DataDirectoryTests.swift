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

    @Test func eachDirectoryGetsItsOwnStableCookieStore() {
        let a = URL(filePath: "/tmp/zentic-a")
        // Stable across launches, or every relaunch would sign the user out.
        #expect(DataDirectory.storeID(for: a) == DataDirectory.storeID(for: URL(filePath: "/tmp/zentic-a/")))
        #expect(DataDirectory.storeID(for: a) != DataDirectory.storeID(for: URL(filePath: "/tmp/zentic-b")))
    }
}
