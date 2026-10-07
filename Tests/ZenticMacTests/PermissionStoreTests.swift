import Foundation
import Testing
import WebKit

@testable import ZenticKit
@testable import ZenticMac

extension AppIntegration {
    /// Invariant 10 through the app's own objects: a tab's questions, the
    /// store they are remembered in, and the file it writes.
    @MainActor
    @Suite struct Permissions {
        /// A site no other test uses, so the shared store starts clean for it.
        let site = "permissions-\(UUID().uuidString.prefix(8)).example"

        func tab(in browser: Browser) -> Tab {
            let tab = Tab(url: nil)
            browser.insert(tab, after: nil, select: false)
            return tab
        }

        /// Ask whether a download may start, as `TabDelegate` does, without
        /// waiting for the answer.
        func askForDownload(_ tab: Tab) -> Task<Bool, Never> {
            let site = site
            return Task { await tab.permissions.allowsDownload(named: "report.zip", site: site) }
        }

        func onDisk() -> PermissionBook? {
            JSONFile<PermissionBook>(name: "permissions.json").load()
        }

        @Test func aQuestionLeftOpenIsAnsweredNoWhenThePageGoes() async throws {
            let tab = tab(in: Browser(isPrivate: false, dataStore: .nonPersistent()))
            let first = askForDownload(tab)
            let second = askForDownload(tab)
            try await eventually("the question") { tab.permissions.current != nil }
            // A page asking twice gets one question, not a stack of them.
            try await eventually("both asks to be waiting") { tab.permissions.queue.count == 1 }

            tab.permissions.documentChanged()
            #expect(await first.value == false)
            #expect(await second.value == false)
            #expect(tab.permissions.queue.isEmpty)
            #expect(SitePermissionStore.shared.book.decision(.downloads, explicitlyFor: site) == nil, "and nothing is remembered")
        }

        @Test func aRememberedAnswerIsSavedAndNotAskedAgain() async throws {
            let browser = Browser(isPrivate: false, dataStore: .nonPersistent())
            let tab = tab(in: browser)
            let asked = askForDownload(tab)
            try await eventually("the question") { tab.permissions.current != nil }

            tab.permissions.answer(try #require(tab.permissions.current).id, allow: true, remember: true)
            #expect(await asked.value)
            #expect(SitePermissionStore.shared.book.decision(.downloads, explicitlyFor: site) == .allow)
            try await eventually("permissions.json to have it") {
                onDisk()?.decision(.downloads, explicitlyFor: site) == .allow
            }

            // The next download from the site starts without a question.
            #expect(await askForDownload(tab).value)
            #expect(tab.permissions.queue.isEmpty)
            SitePermissionStore.shared.forget(site)
        }

        @Test func aPrivateWindowsAnswerStaysInTheWindow() async throws {
            let browser = Browser(isPrivate: true)
            let tab = tab(in: browser)
            let asked = askForDownload(tab)
            try await eventually("the question") { tab.permissions.current != nil }
            tab.permissions.answer(try #require(tab.permissions.current).id, allow: true, remember: true)
            #expect(await asked.value)

            // Remembered for this window only.
            #expect(browser.permissions.decision(.downloads, for: site) == .allow)
            #expect(SitePermissionStore.shared.book.decision(.downloads, explicitlyFor: site) == nil)
            #expect(PermissionScope(isPrivate: false).decision(.downloads, for: site) == .ask)
            // And nothing reaches the file. An ordinary change after it makes
            // the store write, so the file is known to be current.
            let marker = "marker-\(site)"
            SitePermissionStore.shared.set(.deny, .popups, for: marker)
            try await eventually("the store to write") { onDisk()?.decision(.popups, explicitlyFor: marker) == .deny }
            #expect(onDisk()?.decision(.downloads, explicitlyFor: site) == nil)
            SitePermissionStore.shared.forget(marker)
        }

        @Test func aDecisionEqualToTheDefaultIsKept() async throws {
            // "Ask" for the camera is consent withheld, and must survive a
            // later change of default to "Allow".
            SitePermissionStore.shared.set(.ask, .camera, for: site)
            SitePermissionStore.shared.setDefault(.allow, for: .camera)
            defer {
                SitePermissionStore.shared.setDefault(.ask, for: .camera)
                SitePermissionStore.shared.forget(site)
            }
            #expect(PermissionScope(isPrivate: false).decision(.camera, for: site) == .ask)
            try await eventually("the file to have both") {
                let book = onDisk()
                return book?.decision(.camera, explicitlyFor: site) == .ask && book?.defaultDecision(for: .camera) == .allow
            }
        }
    }
}
