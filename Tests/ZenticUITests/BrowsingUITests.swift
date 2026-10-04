import XCTest

/// One window, one page: the address bar, the site's version, the toolbar,
/// tabs and find.
final class BrowsingUITests: ZenticUITestCase {
    func testOpensAPageFromTheAddressBar() {
        launch()
        open("article.html", title: "Fixture Article")
        XCTAssertTrue(pageText("Styling: site").waitForExistence(timeout: 5), "the page itself is on screen")
        XCTAssertEqual(siteVersion.value as? String, "Clean", "a new site opens in the default version")
        XCTAssertTrue(app.buttons["127.0.0.1"].exists, "the address bar names the site")
    }

    /// The fixture reports what it sees Zentic do: Minimal's stylesheet, and
    /// the content blocker hiding its ad.
    func testTheModePickerChangesThePage() {
        launch()
        open("article.html", title: "Fixture Article")
        XCTAssertTrue(pageText("Ad: hidden").waitForExistence(timeout: 5), "Clean blocks the ad")

        siteVersion.click()
        let minimal = app.popovers.buttons["Minimal"]
        XCTAssertTrue(minimal.waitForExistence(timeout: 5))
        minimal.click()
        XCTAssertTrue(pageText("Styling: Zentic").waitForExistence(timeout: 5), "Minimal restyles the live page")
        XCTAssertTrue(wait(for: siteVersion, "value == 'Minimal'"))
        XCTAssertTrue(waitForAbsence(of: minimal), "the picker closes itself")

        siteVersion.click()
        app.popovers.buttons["Original"].click()
        XCTAssertTrue(pageText("Ad: visible").waitForExistence(timeout: 10), "Original reloads without blocking")
        XCTAssertTrue(pageText("Styling: site").exists)
        XCTAssertTrue(wait(for: siteVersion, "value == 'Original'"))
    }

    func testTheToolbarFoldsAwayOnScrollAndComesBack() {
        launch()
        open("article.html", title: "Fixture Article")
        XCTAssertTrue(pageText("Styling: site").waitForExistence(timeout: 5))

        app.webViews.firstMatch.scroll(byDeltaX: 0, deltaY: -600)
        XCTAssertTrue(compactToolbar.waitForExistence(timeout: 5), "scrolling down folds the toolbar into a pill")
        XCTAssertFalse(siteVersion.exists)
        XCTAssertEqual(compactToolbar.label, "127.0.0.1", "the pill names the site")

        compactToolbar.click()
        XCTAssertTrue(siteVersion.waitForExistence(timeout: 5), "clicking the pill opens the toolbar again")
    }

    func testNewTabCloseAndReopen() {
        launch()
        open("article.html", title: "Fixture Article")
        open("second.html", title: "Fixture Second", newTab: true)
        XCTAssertTrue(tabRow("Fixture Article").exists, "a new tab, not the same one")

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitForAbsence(of: tabRow("Fixture Second")), "⌘W closes it")
        XCTAssertTrue(tabRow("Fixture Article").exists)

        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertTrue(tabRow("Fixture Second").waitForExistence(timeout: 10), "⇧⌘T brings it back")
    }

    func testFindOnPage() {
        launch()
        open("article.html", title: "Fixture Article")
        XCTAssertTrue(pageText("Styling: site").waitForExistence(timeout: 5))

        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["find"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(wait(for: field, "hasKeyboardFocus == true"), "typing goes to the find bar, not the page")
        field.typeText("zebraquartz")
        let notFound = app.staticTexts["Not found"]
        XCTAssertTrue(notFound.waitForExistence(timeout: 5), "a word the page does not have")

        field.typeKey("a", modifierFlags: .command)
        field.typeText("quixotic")
        XCTAssertTrue(waitForAbsence(of: notFound), "one it has")

        field.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForAbsence(of: field), "Escape closes the find bar")
    }
}
