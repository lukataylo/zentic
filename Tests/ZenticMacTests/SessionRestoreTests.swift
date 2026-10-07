import Foundation
import Testing

@testable import ZenticKit
@testable import ZenticMac

extension AppIntegration {
    /// Launches played in one process: each `Windows(directory:)` is one, and
    /// one that never quits is a crash. ZenticKitTests check the pieces
    /// (`SessionSnapshot`, `LaunchGuard`, `TabStateStore`); these check what
    /// `Windows` makes of them together.
    @MainActor
    @Suite struct Sessions {
        let directory = FileManager.default.temporaryDirectory.appending(path: "zentic-session-\(UUID().uuidString)")
        var file: JSONFile<SessionSnapshot> { JSONFile(name: "session.json", directory: directory) }

        /// Two windows; spaces with icons, emoji and tints; pinned tabs away
        /// from home; a selection in each space.
        func saved() async throws -> SessionSnapshot {
            let server = try await AppIntegration.server()
            func tab(_ path: String, _ title: String, pinned: String? = nil) -> SessionSnapshot.Tab {
                SessionSnapshot.Tab(id: UUID(), url: server.url(path), title: title, pinnedURL: pinned.map(server.url))
            }
            let mail = tab("second.html?inbox=3", "Inbox", pinned: "second.html")
            let article = tab("article.html", "Fixture Article")
            let work = SessionSnapshot.Space(
                id: UUID(), name: "Work", icon: "briefcase", tint: "ocean", pinned: [mail],
                tabs: [article, tab("article.html?2", "Another")], selected: article.id)
            let second = tab("second.html", "Second")
            let fun = SessionSnapshot.Space(
                id: UUID(), name: "Fun", icon: "🎸", tint: "rose", pinned: [], tabs: [second], selected: second.id)
            let personal = SessionSnapshot.Space(
                id: UUID(), name: "Personal", icon: "person", tint: "indigo", pinned: [], tabs: [], selected: nil)
            return SessionSnapshot(windows: [
                .init(
                    id: UUID(), frame: .init(x: 40, y: 60, width: 1200, height: 800), sidebarWidth: 300,
                    sidebarVisible: false, spaces: [work, fun], selectedSpace: fun.id),
                .init(
                    id: UUID(), frame: .init(x: 90, y: 90, width: 900, height: 700), sidebarWidth: 260,
                    sidebarVisible: true,
                    spaces: [personal], selectedSpace: personal.id),
            ])
        }

        @Test func aSessionComesBackExactlyAsItWasSaved() async throws {
            let saved = try await saved()
            file.save(saved)

            let launch = Windows(directory: directory)
            #expect(launch.launch == .clean)
            #expect(launch.snapshot == saved, "through Browser and back without losing a tab, space or pin")

            launch.saveForTermination()
            #expect(file.load() == saved)
            #expect(Windows(directory: directory).launch == .clean, "a quit is not a crash")
        }

        @Test func aCrashIsReportedOnceAndLosesNothing() async throws {
            let saved = try await saved()
            file.save(saved)
            _ = Windows(directory: directory)  // and never quits

            let relaunch = Windows(directory: directory)
            #expect(relaunch.launch == .recovered)
            #expect(relaunch.snapshot == saved)
            let first = relaunch.claim(nil)
            #expect(first.recoveryNotice == .recovered, "the first window says so")
            #expect(first.selectedTab?.isRealized == true, "and loads its page as usual")
            let second = relaunch.claim(nil)
            #expect(second.recoveryNotice == nil, "once")
            first.closeAllTabs(forgettingState: false)
        }

        /// Crashing again straight after launching is likely the page on
        /// screen; the tabs come back, but that page waits for a click.
        @Test func crashingTwiceOnLaunchHoldsBackTheSelectedPage() async throws {
            file.save(try await saved())
            _ = Windows(directory: directory)
            _ = Windows(directory: directory)

            let third = Windows(directory: directory)
            #expect(third.launch == .recoveredRepeatedly)
            let browser = third.claim(nil)
            let selected = try #require(browser.selectedTab)
            #expect(!selected.isRealized)

            browser.select(selected)
            #expect(selected.isRealized, "a click loads it")
            browser.closeAllTabs(forgettingState: false)
        }

        /// Invariant 9: a session that can't be read is set aside, never
        /// overwritten, and the tabs' saved states stay for whoever recovers it.
        @Test func anUnreadableSessionIsSetAsideWithItsTabsStates() async throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(#"{"version":2,"windows":[{"id":"#.utf8).write(to: file.url)
            let orphan = UUID()
            Windows.tabStates.writeNow(Data([1, 2, 3]), for: orphan)
            defer { Windows.tabStates.remove(orphan) }

            let launch = Windows(directory: directory)
            #expect(launch.snapshot.windows.count == 1, "a fresh window instead")
            launch.saveForTermination()

            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(names.contains { $0.hasPrefix("session.json.unreadable-") })
            #expect(await Windows.tabStates.read(orphan) == Data([1, 2, 3]))
        }
    }
}
