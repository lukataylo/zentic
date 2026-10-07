import XCTest

/// Every UI test launches Zentic the same way: on a data directory of its own,
/// with `--ui-testing` (nothing fetched that the test did not load itself), and
/// with its pages served by `FixtureServer` on 127.0.0.1.
///
/// Waits are for conditions — an element appearing, a value changing — never a
/// fixed time: a test that sleeps is slow on a fast Mac and flaky on a slow one.
@MainActor
class ZenticUITestCase: XCTestCase {
    var app: XCUIApplication!
    /// Where this test's Zentic keeps everything it writes.
    var dataDirectory: URL!

    private static var server: FixtureServer?

    func url(_ path: String) -> URL { Self.server!.url(path) }

    override func setUp() async throws {
        continueAfterFailure = false
        if Self.server == nil {
            let server = try FixtureServer()
            try await server.start()
            Self.server = server
        }
        // Not the runner's own temporary folder: that is inside its sandbox
        // container, and Zentic reaching into another app's container asks
        // the person for permission.
        dataDirectory = URL(filePath: "/private/tmp/zentic-ui-tests", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        if let app, app.state != .notRunning { app.terminate() }
        if let dataDirectory { try? FileManager.default.removeItem(at: dataDirectory) }
    }

    /// Launch on this test's data directory. `welcome` leaves the first-run
    /// tour to the data directory, as on a new Mac; otherwise it counts as seen.
    func launch(welcome: Bool = false) {
        app.launchEnvironment["ZENTIC_DATA_DIR"] = dataDirectory.path
        // `-key value` pairs (the argument domain, which `DataDirectory.defaults`
        // reads through) before the flag: AppKit reads `--ui-testing` as a key
        // too, and would take the next argument as its value, leaving the one
        // after as a file to open — and then opens no window.
        app.launchArguments = (welcome ? [] : ["-onboardingVersionSeen", "1"]) + ["--ui-testing"]
        app.launch()
        XCTAssertTrue(browserWindow.waitForExistence(timeout: 15), "a browser window opens")
    }

    /// Quit as a person does, so everything is saved on the way out.
    func quit() {
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Zentic quits")
    }

    // MARK: - The window

    /// SwiftUI names a window of the `browser` group `browser-AppWindow-<n>`.
    var browserWindows: XCUIElementQuery {
        app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'browser'"))
    }
    var browserWindow: XCUIElement { browserWindows.firstMatch }

    var addressField: XCUIElement { app.textFields["address"] }
    var siteVersion: XCUIElement { app.buttons["Site version"] }
    var compactToolbar: XCUIElement { app.buttons["toolbar.compact"] }

    /// A sidebar row, by its page's title (", pinned" after it for a pinned tab).
    func tabRow(_ label: String, in window: XCUIElement? = nil) -> XCUIElement {
        (window ?? app).descendants(matching: .any).matching(identifier: "sidebar.tab")
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Text on the page itself, through WebKit's accessibility tree.
    func pageText(_ text: String) -> XCUIElement {
        app.webViews.staticTexts.matching(NSPredicate(format: "value == %@", text)).firstMatch
    }

    // MARK: - Doing things

    /// ⌘L (or ⌘T for a new tab), the fixture's address, Return; wait for the
    /// page's title in the sidebar.
    func open(_ path: String, title: String, newTab: Bool = false) {
        app.typeKey(newTab ? "t" : "l", modifierFlags: .command)
        XCTAssertTrue(addressField.waitForExistence(timeout: 5), "the address bar opens")
        XCTAssertTrue(wait(for: addressField, "hasKeyboardFocus == true"), "typing goes to the address bar")
        addressField.typeKey("a", modifierFlags: .command)
        let address = url(path).absoluteString
        type(address, into: addressField)
        // Return on anything else would search the web.
        XCTAssertEqual(addressField.value as? String, address)
        addressField.typeText("\r")
        XCTAssertTrue(tabRow(title).waitForExistence(timeout: 15), "\(title) loads in a tab")
    }

    /// `typeText` drops ":" on some keyboard layouts (British among them);
    /// on Apple's English layouts it is a shifted semicolon.
    func type(_ text: String, into element: XCUIElement) {
        for (index, part) in text.split(separator: ":", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { element.typeKey(";", modifierFlags: .shift) }
            if !part.isEmpty { element.typeText(String(part)) }
        }
    }

    func menu(_ menu: String, _ item: String) {
        let bar = app.menuBars.menuBarItems[menu]
        bar.click()
        bar.menuItems[item].click()
    }

    /// Wait for an element to go, as `waitForExistence` waits for one to come.
    @discardableResult
    func waitForAbsence(of element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        wait(for: element, "exists == false", timeout: timeout)
    }

    func wait(for object: Any, _ predicate: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: object)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Wait for something outside the app — a file — to become true.
    func wait(_ what: String, timeout: TimeInterval = 10, until condition: @escaping @Sendable () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        expectation.expectationDescription = what
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
