import Foundation
import Testing
import WebKit

@testable import ZenticKit
@testable import ZenticMac

extension AppIntegration {
    /// A real `Tab` in a real `Browser`, loading pages from the fixture server.
    @MainActor
    @Suite struct Tabs {
        /// A window of its own, with cookies that die with it.
        let browser = Browser(isPrivate: false, dataStore: .nonPersistent())

        func open(_ path: String) async throws -> Tab {
            let url = try await AppIntegration.server().url(path)
            let tab = browser.openTab(url)
            sized(tab)
            try await loaded(tab, at: url)
            return tab
        }

        /// What the window does when it shows a tab, in the same turn as the
        /// web view is made. A web view of no size has nowhere to scroll back to.
        func sized(_ tab: Tab) {
            tab.webView?.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        }

        func loaded(_ tab: Tab, at url: URL? = nil) async throws {
            try await eventually("the tab's web view") { tab.webView != nil }
            try await tab.webView!.waitForLoad(of: url)
        }

        func text(_ id: String, in tab: Tab) async throws -> String? {
            try await tab.webView?.page("return document.getElementById('\(id)').textContent") as? String
        }

        /// The fixture's own report of whether its ad is shown: what the
        /// content blocker's cosmetic rule does to the page.
        func adState(_ tab: Tab) async throws -> String? { try await text("ad-state", in: tab) }

        // MARK: - Content blocking

        @Test func originalLoadsWithoutTheBlockerAndCleanWithIt() async throws {
            let url = try await AppIntegration.server().url("article.html")
            browser.setMode(.clean, for: url)
            let tab = try await open("article.html")
            #expect(try await adState(tab) == "Ad: hidden")

            // Crossing to Original changes blocking, which needs a new document.
            browser.choose(.original)
            try await eventually("the page to come back unblocked") { try await adState(tab) == "Ad: visible" }
            #expect(tab.mode == .original)

            browser.choose(.clean)
            try await eventually("the page to come back blocked") { try await adState(tab) == "Ad: hidden" }
        }

        /// Attaching waits on compiled lists and detaching does not; two
        /// quick changes must still land in the order they were made.
        @Test func quickChangesEndOnTheLastChoice() async throws {
            let url = try await AppIntegration.server().url("article.html")
            browser.setMode(.clean, for: url)
            let tab = try await open("article.html")

            browser.choose(.original)
            browser.choose(.clean)
            browser.choose(.original)
            try await eventually("the last choice to win") {
                guard let webView = tab.webView, !webView.isLoading else { return false }
                return try await adState(tab) == "Ad: visible"
            }
            // And it stays there once every reload has run.
            try await loaded(tab)
            #expect(try await adState(tab) == "Ad: visible")
            #expect(tab.mode == .original)
        }

        @Test func modesThatKeepBlockingSwitchWithoutAReload() async throws {
            let url = try await AppIntegration.server().url("article.html")
            browser.setMode(.clean, for: url)
            let tab = try await open("article.html")
            // Gone if the document is replaced.
            _ = try await tab.webView!.page("window.sameDocument = true")

            browser.choose(.minimal)
            try await eventually("Minimal to take over") { try await text("styling", in: tab) == "Styling: Zentic" }
            browser.choose(.clean)
            try await eventually("the site's styling back") { try await text("styling", in: tab) == "Styling: site" }

            #expect(try await tab.webView!.page("return window.sameDocument") as? Bool == true)
            #expect(try await adState(tab) == "Ad: hidden")
        }

        // MARK: - Suspension

        @Test func aSuspendedTabComesBackWhereItWas() async throws {
            let tab = try await open("article.html")
            let second = try await AppIntegration.server().url("second.html")
            tab.load(second)
            try await loaded(tab, at: second)
            let unscrolled = tab.webView!.interactionState as? Data
            _ = try await tab.webView!.page("window.scrollTo(0, 1200)")
            // The page scrolls in its own process; the app's record of where
            // it is (what suspending keeps) catches up a moment later.
            try await eventually("WebKit to record the scroll") { tab.webView!.interactionState as? Data != unscrolled }

            tab.suspend()
            #expect(!tab.isRealized)
            #expect(tab.webView == nil)
            #expect(tab.url == second, "a suspended tab still says where it is")

            tab.realize()
            sized(tab)
            try await loaded(tab, at: second)
            #expect(tab.canGoBack, "the back list survives")
            try await eventually("the scroll position") {
                try await tab.webView!.page("return window.scrollY") as? Double == 1200
            }

            tab.goBack()
            try await eventually("back to the first page") { tab.url?.lastPathComponent == "article.html" }
        }

        /// After a crash there is no live web view to ask: the state written
        /// to disk is all a relaunch has.
        @Test func aTabRestoredFromDiskHasItsHistory() async throws {
            let tab = try await open("article.html")
            let second = try await AppIntegration.server().url("second.html")
            tab.load(second)
            try await loaded(tab, at: second)
            tab.persistStateNow()
            let saved = await Windows.tabStates.read(tab.id)
            #expect(saved != nil)

            // A relaunch: the session names the tab and its page, nothing more.
            let restored = Tab(id: tab.id, url: second, title: tab.title)
            restored.hasStateOnDisk = true
            tab.suspend(persisting: false)
            browser.insert(restored, after: nil, select: true)
            sized(restored)
            try await loaded(restored, at: second)
            #expect(restored.canGoBack, "the back list came back from disk")

            browser.close(restored)
            #expect(await Windows.tabStates.read(tab.id) == nil, "closing a tab deletes its state")
        }
    }
}
