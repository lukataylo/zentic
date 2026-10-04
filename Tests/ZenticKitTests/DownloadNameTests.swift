import Foundation
import Testing

@testable import ZenticKit

@Suite struct DownloadNameTests {
    let folder = URL(filePath: "/Users/someone/Downloads", directoryHint: .isDirectory)

    @Test func aSuggestedPathCannotLeaveTheFolder() {
        for suggested in ["../../Library/LaunchAgents/evil.plist", "/etc/passwd", "a/b/../c.txt"] {
            let url = DownloadName.unused(for: suggested, in: folder) { _ in false }
            #expect(url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        }
    }

    @Test func hiddenAndBlankNamesGetAVisibleName() {
        #expect(DownloadName.unused(for: ".zshrc", in: folder) { _ in false }.lastPathComponent == "download.zshrc")
        #expect(DownloadName.unused(for: "  ", in: folder) { _ in false }.lastPathComponent == "download")
        #expect(DownloadName.unused(for: "/", in: folder) { _ in false }.lastPathComponent == "download")
    }

    @Test func aTakenNameIsNumberedBeforeItsExtension() {
        // Taken on disk, or claimed by a download that has not written yet.
        let taken: Set<String> = ["report.pdf", "report 2.pdf", "notes"]
        let url = DownloadName.unused(for: "report.pdf", in: folder) { taken.contains($0.lastPathComponent) }
        #expect(url.lastPathComponent == "report 3.pdf")
        #expect(DownloadName.unused(for: "notes", in: folder) { taken.contains($0.lastPathComponent) }.lastPathComponent == "notes 2")
    }
}
