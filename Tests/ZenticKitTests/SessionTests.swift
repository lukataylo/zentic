import Foundation
import Testing

@testable import ZenticKit

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("zentic-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct SessionSnapshotTests {
    @Test func theSingleWindowSessionBeforeSpacesIsMigratedNotLost() throws {
        // Written by the previous version of Zentic: no `version` key.
        let tab = UUID()
        let json = """
            {"tabs":[{"id":"\(tab.uuidString)","url":"https://example.com/a","title":"A"}],
             "selected":"\(tab.uuidString)","sidebarWidth":300,"sidebarVisible":false}
            """
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.version == SessionSnapshot.currentVersion)
        #expect(snapshot.windows.count == 1)
        let window = try #require(snapshot.windows.first)
        #expect(window.sidebarWidth == 300)
        #expect(window.sidebarVisible == false)
        let space = try #require(window.spaces.first)
        #expect(space.name == "Personal")
        #expect(space.tabs.map(\.id) == [tab])
        #expect(space.tabs.first?.url == URL(string: "https://example.com/a"))
        #expect(space.selected == tab)
        #expect(space.pinned.isEmpty)
    }

    @Test func roundTripsPinnedTabsAndSpaces() throws {
        let pinned = SessionSnapshot.Tab(
            id: UUID(), url: URL(string: "https://mail.example.com/inbox/3"), title: "Inbox",
            pinnedURL: URL(string: "https://mail.example.com"))
        let snapshot = SessionSnapshot(windows: [
            .init(
                id: UUID(), frame: .init(x: 10, y: 20, width: 1200, height: 800), sidebarWidth: 260,
                sidebarVisible: true,
                spaces: [
                    .init(id: UUID(), name: "Work", icon: "briefcase", tint: "ocean", pinned: [pinned], tabs: [], selected: pinned.id),
                    .init(id: UUID(), name: "Fun", icon: "🎸", tint: nil, pinned: [], tabs: [], selected: nil),
                ],
                selectedSpace: nil)
        ])
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(SessionSnapshot.self, from: data) == snapshot)
        #expect(snapshot.tabIDs == [pinned.id])
    }

    @Test func aSessionFromANewerZenticIsSetAsideNotOverwritten() throws {
        let dir = temporaryDirectory()
        let file = JSONFile<SessionSnapshot>(name: "session.json", directory: dir)
        try Data(#"{"version":99,"windows":[],"somethingNew":true}"#.utf8).write(to: file.url)

        #expect(file.load() == nil)
        // The file is moved aside, so the next save cannot destroy it.
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.hasPrefix("session.json.unreadable-") })
        #expect(!names.contains("session.json"))
    }

    @Test func aCorruptSessionIsSetAside() throws {
        let dir = temporaryDirectory()
        let file = JSONFile<SessionSnapshot>(name: "session.json", directory: dir)
        try Data(#"{"version":2,"windows":[{"id":"#.utf8).write(to: file.url)
        #expect(file.load() == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.hasPrefix("session.json.unreadable-") })
    }
}

@Suite struct LaunchGuardTests {
    @Test func aCleanQuitIsNotReportedAsACrash() {
        let guard_ = LaunchGuard(directory: temporaryDirectory())
        #expect(guard_.begin() == .clean)
        guard_.end()
        #expect(guard_.begin() == .clean)
    }

    @Test func endingWithoutQuittingIsReported() {
        let guard_ = LaunchGuard(directory: temporaryDirectory())
        _ = guard_.begin()
        guard_.markStartupSurvived()
        // No end(): killed, or crashed after running a while.
        #expect(guard_.begin() == .recovered)
    }

    @Test func twoCrashesInARowOnLaunchHoldBackTheSelectedPage() {
        let guard_ = LaunchGuard(directory: temporaryDirectory())
        _ = guard_.begin()  // crashes within the startup window
        #expect(guard_.begin() == .recovered)  // and again
        #expect(guard_.begin() == .recoveredRepeatedly)
    }

    @Test func aRunThatSurvivesStartupResetsTheCount() {
        let guard_ = LaunchGuard(directory: temporaryDirectory())
        _ = guard_.begin()
        #expect(guard_.begin() == .recovered)
        guard_.markStartupSurvived()
        // Crashed later on: one crash, not a launch loop.
        #expect(guard_.begin() == .recovered)
    }
}

@Suite struct TabStateStoreTests {
    @Test func writesReadsAndPrunesClosedTabs() async {
        let store = TabStateStore(directory: temporaryDirectory())
        let kept = UUID()
        let closed = UUID()
        await store.write(Data([1, 2, 3]), for: kept)
        await store.write(Data([4]), for: closed)
        #expect(await store.read(kept) == Data([1, 2, 3]))

        await store.prune(keeping: [kept])
        #expect(await store.read(kept) == Data([1, 2, 3]))
        #expect(await store.read(closed) == nil)

        await store.remove(kept)
        #expect(await store.read(kept) == nil)
    }

    @Test func pruningLeavesOtherFilesAlone() async throws {
        let dir = temporaryDirectory()
        let other = dir.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: other)
        await TabStateStore(directory: dir).prune(keeping: [])
        #expect(FileManager.default.fileExists(atPath: other.path))
    }
}

@Suite struct SpaceSwipeTests {
    @Test func firesOncePerGesture() {
        var swipe = SpaceSwipe()
        swipe.begin()
        #expect(swipe.move(dx: -30, dy: 0) == nil)
        #expect(swipe.move(dx: -40, dy: 0) == .next)
        // The rest of the same gesture does not skip a second space.
        #expect(swipe.move(dx: -200, dy: 0) == nil)
        swipe.begin()
        #expect(swipe.move(dx: 80, dy: 2) == .previous)
    }

    @Test func scrollingTheTabListNeverSwitches() {
        var swipe = SpaceSwipe()
        swipe.begin()
        // Mostly vertical, drifting sideways as a real scroll does.
        for _ in 0..<20 { #expect(swipe.move(dx: -8, dy: 30) == nil) }
    }
}

/// A private window's site changes ride over the shared book in memory.
@Suite struct PrivateSiteOverlayTests {
    @Test func aPrivateChangeLeavesTheSharedBookAlone() {
        let shared = SiteBook(defaultMode: .clean)
        let change = shared.override("a.com") { $0.setMode(.minimal, for: "a.com") }
        let seen = shared.overlaying(["a.com": change])
        #expect(seen.mode(for: "a.com") == .minimal)
        #expect(shared.mode(for: "a.com") == .clean)
    }

    @Test func resettingASiteInPrivateBeatsTheSharedChoice() {
        var shared = SiteBook(defaultMode: .clean)
        shared.setMode(.original, for: "a.com")
        // Back to the default inside the private window: the override is an
        // explicit nil, which must not fall through to the shared `.original`.
        let change = shared.override("a.com") { $0.setMode(.clean, for: "a.com") }
        #expect(change == nil)
        #expect(shared.overlaying(["a.com": change]).mode(for: "a.com") == .clean)
        #expect(shared.overlaying([:]).mode(for: "a.com") == .original)
    }
}
