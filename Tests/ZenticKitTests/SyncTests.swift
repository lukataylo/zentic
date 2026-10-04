import CloudKit
import Foundation
import Testing

@testable import ZenticKit

private func tab(_ url: String?, _ title: String = "", pinnedAt pinned: String? = nil) -> SessionSnapshot.Tab {
    SessionSnapshot.Tab(id: UUID(), url: url.flatMap(URL.init(string:)), title: title, pinnedURL: pinned.flatMap(URL.init(string:)))
}

private func space(_ name: String, pinned: [SessionSnapshot.Tab] = [], tabs: [SessionSnapshot.Tab]) -> SessionSnapshot.Space {
    SessionSnapshot.Space(id: UUID(), name: name, icon: "star", tint: nil, pinned: pinned, tabs: tabs, selected: nil)
}

private func window(_ spaces: SessionSnapshot.Space...) -> SessionSnapshot.Window {
    SessionSnapshot.Window(id: UUID(), frame: nil, sidebarWidth: 260, sidebarVisible: true, spaces: spaces, selectedSpace: nil)
}

private func device(_ id: String, modified: Date, tabs: [String] = ["https://example.com"]) -> SyncedDevice {
    SyncedDevice(
        id: id, name: id, kind: .laptop, modified: modified,
        spaces: [.init(name: "Personal", icon: "star", pinned: [], tabs: tabs.map { .init(title: $0, url: URL(string: $0)!) })])
}

@Suite struct SyncedDeviceFromSessionTests {
    @Test func sendsWebPagesOnlyAndEachAddressOncePerSpace() {
        let session = SessionSnapshot(windows: [
            window(space("Personal", tabs: [
                tab("https://a.example/1", "One"),
                tab("https://a.example/1", "One again"),
                tab("file:///Users/me/secret.pdf", "A local file"),
                tab("about:blank"),
                tab(nil, "A new tab with nothing in it"),
            ]))
        ])
        let spaces = SyncedDevice.spaces(from: session)
        #expect(spaces.count == 1)
        #expect(spaces[0].tabs.map(\.url.absoluteString) == ["https://a.example/1"])
        #expect(spaces[0].tabs[0].title == "One")
    }

    @Test func mergesSameNamedSpacesAcrossWindowsAndDropsEmptyOnes() {
        let session = SessionSnapshot(windows: [
            window(space("Work", tabs: [tab("https://a.example")]), space("Empty", tabs: [])),
            window(space("Work", tabs: [tab("https://b.example"), tab("https://a.example")])),
        ])
        let spaces = SyncedDevice.spaces(from: session)
        #expect(spaces.map(\.name) == ["Work"])
        #expect(spaces[0].tabs.map(\.url.host) == ["a.example", "b.example"])
    }

    @Test func aPinnedTabSendsThePageItIsOnAndStaysPinned() {
        let session = SessionSnapshot(windows: [
            window(space(
                "Personal",
                pinned: [
                    tab("https://mail.example/inbox/42", "Inbox", pinnedAt: "https://mail.example"),
                    // Unloaded since launch: only its pinned address is known.
                    tab(nil, "Calendar", pinnedAt: "https://cal.example"),
                ],
                tabs: [tab("https://mail.example/inbox/42")]))
        ])
        let spaces = SyncedDevice.spaces(from: session)
        #expect(spaces[0].pinned.map(\.url.absoluteString) == ["https://mail.example/inbox/42", "https://cal.example"])
        // Already listed as a pinned tab of the space.
        #expect(spaces[0].tabs.isEmpty)
    }

    @Test func aHugeSessionStillFitsInOneRecord() throws {
        // A page can set any title, and some sessions have thousands of tabs:
        // the record must still be small enough for CloudKit to accept.
        let long = String(repeating: "x", count: 5_000)
        let tabs = (0..<3_000).map { tab("https://example.com/\($0)?q=\(String(repeating: "y", count: 400))", long) }
        let spaces = SyncedDevice.spaces(from: SessionSnapshot(windows: [window(space("Personal", tabs: tabs))]))
        #expect(spaces[0].tabs.count > 100)
        #expect(spaces[0].tabs.count < 3_000)
        #expect(spaces[0].tabs.allSatisfy { $0.title.count == SyncedDevice.maxTitleLength })

        let record = CKRecord(recordType: SyncedDevice.recordType)
        try SyncedDevice(id: "me", name: "Mac", kind: .desktop, modified: .now, spaces: spaces).write(to: record)
        let size = try #require(record["spaces"] as? Data).count
        #expect(size < 500_000)
    }

    @Test func aSwitchedTabIsNotNews() {
        let a = device("me", modified: .now)
        var b = a
        b.modified = .now.addingTimeInterval(60)
        #expect(a.hasSameContent(as: b))
        b.spaces[0].tabs.append(.init(title: "New", url: URL(string: "https://new.example")!))
        #expect(!a.hasSameContent(as: b))
    }
}

@Suite struct SyncedDeviceRecordTests {
    private let zone = CKRecordZone.ID(zoneName: "Tabs", ownerName: CKCurrentUserDefaultName)

    @Test func roundTripsThroughARecord() throws {
        let original = SyncedDevice(
            id: "8F0C", name: "Luka’s MacBook Air", kind: .laptop, modified: Date(timeIntervalSince1970: 1_800_000_000),
            spaces: [
                .init(
                    name: "Work", icon: "🎸",
                    pinned: [.init(title: "Inbox", url: URL(string: "https://mail.example")!)],
                    tabs: [.init(title: "Ünïcödé — “quoted”", url: URL(string: "https://example.com/a?b=c#d")!)])
            ])
        let record = CKRecord(recordType: SyncedDevice.recordType, recordID: original.recordID(in: zone))
        try original.write(to: record)
        #expect(SyncedDevice(record: record) == original)
    }

    @Test func spacesFromANewerZenticAreSkippedNotMisread() throws {
        let record = CKRecord(recordType: SyncedDevice.recordType, recordID: CKRecord.ID(recordName: "other", zoneID: zone))
        try device("other", modified: .now).write(to: record)
        record["spaces"] = Data(#"{"version":2,"spaces":[{"groups":[]}]}"#.utf8) as NSData
        #expect(SyncedDevice(record: record) == nil)
    }

    @Test func aRecordMissingItsTabsIsSkipped() {
        let record = CKRecord(recordType: SyncedDevice.recordType)
        record["name"] = "Mac" as NSString
        record["modified"] = Date() as NSDate
        #expect(SyncedDevice(record: record) == nil)
    }

    @Test func systemFieldsSurviveTheRoundTripSoTheNextSaveIsAnUpdate() throws {
        let record = CKRecord(recordType: SyncedDevice.recordType, recordID: CKRecord.ID(recordName: "me", zoneID: zone))
        let restored = try #require(CKRecord(systemFields: record.encodedSystemFields))
        #expect(restored.recordID == record.recordID)
        #expect(restored.recordType == record.recordType)
    }
}

@Suite struct SyncedDevicesTests {
    @Test func anOlderCopyNeverReplacesANewerOne() {
        let now = Date()
        var devices = SyncedDevices()
        devices.apply(device("a", modified: now, tabs: ["https://new.example"]))
        devices.apply(device("a", modified: now.addingTimeInterval(-60), tabs: ["https://old.example"]))
        #expect(devices.byID["a"]?.allTabs.first?.url.host == "new.example")
    }

    @Test func showsOtherMacsWithTabsMostRecentFirstAndHidesStaleOnes() {
        let now = Date()
        var devices = SyncedDevices()
        devices.apply(device("me", modified: now))
        devices.apply(device("old", modified: now.addingTimeInterval(-3600)))
        devices.apply(device("new", modified: now.addingTimeInterval(-60)))
        devices.apply(device("empty", modified: now, tabs: []))
        devices.apply(device("sold", modified: now.addingTimeInterval(-SyncedDevices.staleAfter - 1)))
        #expect(devices.others(than: "me", now: now).map(\.id) == ["new", "old"])

        devices.remove(id: "new")
        #expect(devices.others(than: "me", now: now).map(\.id) == ["old"])
    }

    @Test func searchMatchesTitleOrHostEachAddressOnce() {
        let devices = [
            device("a", modified: .now, tabs: ["https://swift.org", "https://example.com/Swift"]),
            device("b", modified: .now, tabs: ["https://swift.org"]),
        ]
        let matches = devices.tabs(matching: "SWIFT", limit: 5)
        #expect(matches.map(\.tab.url.absoluteString) == ["https://swift.org", "https://example.com/Swift"])
        #expect(matches.allSatisfy { $0.device.id == "a" })
        #expect(devices.tabs(matching: "swift", limit: 1).count == 1)
        #expect(devices.tabs(matching: "  ", limit: 5).isEmpty)
    }
}

@Suite struct SyncPacingTests {
    @Test func neverSendsMoreThanOnceInTheMinimumInterval() {
        let now = Date()
        let justSent = SyncPacing.nextSend(lastSent: now.addingTimeInterval(-2), now: now)
        #expect(justSent.timeIntervalSince(now) == SyncPacing.minimumInterval - 2)
        let longAgo = SyncPacing.nextSend(lastSent: now.addingTimeInterval(-600), now: now)
        #expect(longAgo.timeIntervalSince(now) == SyncPacing.settle)
        #expect(SyncPacing.nextSend(lastSent: nil, now: now).timeIntervalSince(now) == SyncPacing.settle)
    }
}
