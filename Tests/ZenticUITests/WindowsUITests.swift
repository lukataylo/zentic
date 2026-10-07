import XCTest

/// More than one window, private windows, spaces and pinned tabs.
final class WindowsUITests: ZenticUITestCase {
    func testANewWindowHasTabsOfItsOwn() {
        launch()
        open("article.html", title: "Fixture Article")

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(wait(for: browserWindows, "count == 2"), "⌘N opens a second window")
        open("second.html", title: "Fixture Second")

        // Each window lists only its own tabs. A window is titled after its page.
        let second = app.windows["Fixture Second"]
        let first = app.windows["Fixture Article"]
        XCTAssertTrue(second.exists && first.exists)
        XCTAssertTrue(tabRow("Fixture Second", in: second).exists)
        XCTAssertFalse(tabRow("Fixture Article", in: second).exists)
        XCTAssertFalse(tabRow("Fixture Second", in: first).exists)
    }

    /// Invariant 8, from the outside: whatever a private window visits, no
    /// file Zentic writes ever mentions it — not after quitting either.
    func testAPrivateWindowWritesNothing() throws {
        launch()
        open("article.html", title: "Fixture Article")

        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(wait(for: browserWindows, "count == 2"))
        let privateWindow = browserWindows.containing(.any, identifier: "Private window").firstMatch
        XCTAssertTrue(app.descendants(matching: .any)["Private window"].waitForExistence(timeout: 5), "it says it is private")

        let secret = "private-\(UUID().uuidString)"
        open("second.html?\(secret)", title: "Fixture Second")
        // Visited, so history and the session would have it by now if they
        // were going to: the page has finished loading.
        XCTAssertTrue(pageText("The bottom of the second page.").waitForExistence(timeout: 10))
        _ = privateWindow

        app.typeKey("w", modifierFlags: [.command, .shift])
        XCTAssertTrue(wait(for: browserWindows, "count == 1"))
        quit()

        // Everything written, and synchronously at that, on the way out.
        var found: [String] = []
        var sawHistory = false
        let files = FileManager.default.enumerator(at: dataDirectory, includingPropertiesForKeys: [.isRegularFileKey])
        while let file = files?.nextObject() as? URL {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                let data = try? Data(contentsOf: file)
            else { continue }
            if data.range(of: Data(secret.utf8)) != nil { found.append(file.lastPathComponent) }
            if file.lastPathComponent == "history.json", data.range(of: Data("article.html".utf8)) != nil { sawHistory = true }
        }
        XCTAssertTrue(sawHistory, "the ordinary window's visit was recorded, so the search looked in the right place")
        XCTAssertEqual(found, [], "nothing on disk mentions the private page")
    }

    func testSpacesKeepTheirOwnTabsAndPinsSurviveARelaunch() {
        launch()
        open("article.html", title: "Fixture Article")

        menu("Spaces", "New Space…")
        let name = app.sheets.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Work")
        app.sheets.buttons["Create Space"].click()
        let work = app.buttons["Work"]
        XCTAssertTrue(work.waitForExistence(timeout: 5), "the space switcher shows it")
        XCTAssertTrue(waitForAbsence(of: tabRow("Fixture Article")), "a new space starts empty")

        open("second.html", title: "Fixture Second")
        menu("Tabs", "Pin Tab")
        XCTAssertTrue(tabRow("Fixture Second, pinned").waitForExistence(timeout: 5))

        menu("Spaces", "Personal")
        XCTAssertTrue(tabRow("Fixture Article").waitForExistence(timeout: 5))
        XCTAssertFalse(tabRow("Fixture Second, pinned").exists, "pins belong to their space")

        menu("Spaces", "Work")
        XCTAssertTrue(tabRow("Fixture Second, pinned").waitForExistence(timeout: 5))

        quit()
        launch()
        XCTAssertTrue(app.buttons["Work"].waitForExistence(timeout: 5), "spaces are restored")
        XCTAssertTrue(tabRow("Fixture Second, pinned").waitForExistence(timeout: 5), "with their pinned tabs")
        menu("Spaces", "Personal")
        XCTAssertTrue(tabRow("Fixture Article").waitForExistence(timeout: 5))
    }
}
