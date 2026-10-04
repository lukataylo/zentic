import Foundation
import Testing

@testable import ZenticKit

@Suite struct IncomingURLTests {
    @Test func webLinksPassThroughAndOtherSchemesAreRefused() {
        let link = URL(string: "https://example.com/a?b=c#d")!
        #expect(IncomingURL.resolve(link) == link)
        #expect(IncomingURL.resolve(URL(string: "HTTP://example.com")!) != nil)
        // Zentic only registers http and https, but anything can call `open`.
        #expect(IncomingURL.resolve(URL(string: "javascript:alert(1)")!) == nil)
        #expect(IncomingURL.resolve(URL(string: "ftp://example.com/file")!) == nil)
        #expect(IncomingURL.resolve(URL(string: "mailto:a@example.com")!) == nil)
        #expect(IncomingURL.resolve(URL(string: "https:///no-host")!) == nil)
    }

    @Test func aPageOrArchiveFromDiskLoadsFromWhereItIs() {
        let page = URL(filePath: "/Users/someone/Saved/page.html")
        #expect(IncomingURL.resolve(page) == page)
        let archive = URL(filePath: "/Users/someone/Saved/page.webarchive")
        #expect(IncomingURL.resolve(archive) == archive)
    }

    @Test func weblocInBothPlistFormats() throws {
        let plist = ["URL": "https://example.com/saved"]
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
            #expect(IncomingURL.webloc(data) == URL(string: "https://example.com/saved"))
        }
    }

    @Test func aSavedLinkCannotPointAtAFileOrScript() throws {
        // Double-clicking a downloaded .webloc must not open a local file or
        // run script in whatever page is current.
        for target in ["file:///etc/passwd", "javascript:alert(1)", "not a url"] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["URL": target], format: .xml, options: 0)
            #expect(IncomingURL.webloc(data) == nil)
            #expect(IncomingURL.internetShortcut("[InternetShortcut]\nURL=\(target)\n") == nil)
        }
        #expect(IncomingURL.webloc(Data("garbage".utf8)) == nil)
    }

    @Test func internetShortcutAsWindowsWritesIt() {
        let text = "[DEFAULT]\r\nBASEURL=https://wrong.example\r\n[InternetShortcut]\r\nIconIndex=0\r\nurl = https://example.com/x\r\n"
        #expect(IncomingURL.internetShortcut(text) == URL(string: "https://example.com/x"))
        // A URL key outside the section is not the link.
        #expect(IncomingURL.internetShortcut("[Other]\nURL=https://example.com\n") == nil)
    }

    @Test func savedLinkFilesAreReadFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let webloc = dir.appending(path: "Link.webloc")
        try PropertyListSerialization.data(fromPropertyList: ["URL": "https://a.example"], format: .binary, options: 0)
            .write(to: webloc)
        #expect(IncomingURL.resolve(webloc) == URL(string: "https://a.example"))

        let shortcut = dir.appending(path: "Link.URL")
        try Data("[InternetShortcut]\nURL=https://b.example\n".utf8).write(to: shortcut)
        #expect(IncomingURL.resolve(shortcut) == URL(string: "https://b.example"))

        // Unreadable: nothing opens, rather than a tab showing the file.
        #expect(IncomingURL.resolve(dir.appending(path: "Missing.webloc")) == nil)
    }
}

@Suite struct OnboardingRecordTests {
    private func freshDefaults() -> UserDefaults {
        let name = "zentic-onboarding-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func dueOnFirstRunAndNotOnceSeen() {
        let defaults = freshDefaults()
        #expect(OnboardingRecord.isDue(in: defaults))
        OnboardingRecord.markSeen(in: defaults)
        #expect(!OnboardingRecord.isDue(in: defaults))
    }

    @Test func aNewerTourIsShownToSomeoneWhoSawAnOlderOne() {
        let defaults = freshDefaults()
        defaults.set(OnboardingRecord.current - 1, forKey: OnboardingRecord.key)
        #expect(OnboardingRecord.isDue(in: defaults))
    }

    @Test func anOlderBuildDoesNotRearmANewerTour() {
        let defaults = freshDefaults()
        defaults.set(OnboardingRecord.current + 1, forKey: OnboardingRecord.key)
        OnboardingRecord.markSeen(in: defaults)
        #expect(defaults.integer(forKey: OnboardingRecord.key) == OnboardingRecord.current + 1)
    }
}
