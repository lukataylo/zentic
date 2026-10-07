import XCTest

/// The windows and panes around the browser: History, Downloads, Settings,
/// and the welcome tour.
final class LibraryUITests: ZenticUITestCase {
    func testHistoryShowsTheVisit() {
        launch()
        open("article.html", title: "Fixture Article")

        app.typeKey("y", modifierFlags: .command)
        let history = app.windows["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 5), "⌘Y opens History")
        // A row reads as one element: title, site, time.
        let row = history.outlines.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Fixture Article'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "with the page just visited")
        XCTAssertTrue(history.staticTexts["Today, 1 page"].exists, "under today")
    }

    /// Downloads ask the page's site first (Settings › Permissions), then
    /// land in the data directory's Downloads folder and the toolbar's list.
    func testADownloadAsksThenLandsInTheList() {
        launch()
        open("article.html", title: "Fixture Article")

        app.webViews.links["Download the report"].click()
        let allow = app.buttons["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5), "the site is asked about first")
        // Armed half a second after it appears, so a click aimed at the page
        // can't land on it.
        XCTAssertTrue(wait(for: allow, "isEnabled == true"))
        allow.click()

        let file = dataDirectory.appending(path: "Downloads/fixture-report.zip")
        XCTAssertTrue(wait("the file on disk") { FileManager.default.fileExists(atPath: file.path) })

        let button = app.buttons["Downloads"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "the toolbar gains a Downloads button")
        button.click()
        let row = app.popovers.descendants(matching: .any)["fixture-report.zip"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "and the list has the file")
    }

    func testEverySettingsPaneOpens() {
        launch()
        app.typeKey(",", modifierFlags: .command)
        let panes = ["General", "Intelligence", "Sites", "Passwords", "Permissions", "Security", "Extensions"]
        // On whichever pane was shown last: SwiftUI remembers it outside the data directory.
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "⌘, opens Settings")
        for pane in panes {
            app.toolbars.buttons[pane].click()
            XCTAssertTrue(app.windows[pane].waitForExistence(timeout: 5), "\(pane) opens")
        }
    }

    /// The tour is for a new Mac: once, then never again on its own.
    func testTheWelcomeTourAppearsExactlyOnce() {
        launch(welcome: true)
        let next = app.sheets.buttons["Continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 10), "a first launch shows the tour")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForAbsence(of: next))

        quit()
        launch(welcome: true)
        // The tour waits a moment for the window to settle; give it that and more.
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 3), "a second launch does not")
    }
}
