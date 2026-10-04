import Foundation
import Testing
import WebKit

@testable import ZenticKit

@Suite struct ExtensionGrantTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func anAnswerForOneDayDoesNotComeBackAsAStandingGrant() {
        let grants = ExtensionGrants(
            permissions: ["cookies": now.addingTimeInterval(-1)],
            sites: ["*://*.a.com/*": now.addingTimeInterval(-60), "*://*.b.com/*": .distantFuture],
            deniedSites: ["*://*.c.com/*": now.addingTimeInterval(3600)])
        let live = grants.live(at: now)
        #expect(live.permissions.isEmpty)
        #expect(Array(live.sites.keys) == ["*://*.b.com/*"])
        #expect(live.deniedSites.count == 1)
    }

    @Test func aRecordKeepsItsStorageIdentityAcrossASaveAndLoad() throws {
        // A new storage ID each launch would wipe the extension's data.
        let record = ExtensionRecord(
            source: .app(bundleID: "com.example.ext", path: "/Applications/Example.app/Contents/PlugIns/E.appex"),
            isEnabled: true, grants: ExtensionGrants(sites: ["*://*.a.com/*": .distantFuture]))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ExtensionRecord.self, from: encoder.encode(record))
        #expect(decoded == record)
        #expect(decoded.id == "app:com.example.ext")
    }

    @Test func movingTheAppDoesNotMakeItADifferentExtension() {
        let before = ExtensionRecord.Source.app(bundleID: "com.example.ext", path: "/Applications/A.app/x.appex")
        let after = ExtensionRecord.Source.app(bundleID: "com.example.ext", path: "/Applications/Utils/A.app/x.appex")
        #expect(before.key == after.key)
    }
}

@Suite struct SiteAccessTests {
    let requested: Set<String> = ["<all_urls>", "*://*/*"]

    @Test func everythingRequestedGrantedIsAllSites() {
        #expect(SiteAccess(requested: requested, granted: requested.union(["*://*.a.com/*"])) == .allSites)
    }

    @Test func partOfTheRequestIsSitesByName() {
        let access = SiteAccess(requested: requested, granted: ["<all_urls>", "*://*.b.com/*", "*://*.a.com/*"])
        // One of two requested patterns is not "all sites"; the broad grant is
        // not a site to list.
        #expect(access == .whenClicked(sites: ["a.com", "b.com"]))
    }

    @Test func anExtensionThatAsksForNoSitesHasNoSiteChoice() {
        #expect(SiteAccess(requested: [], granted: []) == SiteAccess.none)
    }
}

@Suite struct SitePatternTests {
    @Test(arguments: [
        ("github.com", "*://*.github.com/*"),
        ("  GitHub.com ", "*://*.github.com/*"),
        ("https://www.github.com/apple/swift?tab=1", "*://*.github.com/*"),
        ("docs.github.com/en", "*://*.docs.github.com/*"),
        ("localhost:8080", "*://localhost/*"),
        ("http://192.168.1.10/admin", "*://192.168.1.10/*"),
    ])
    func whatPeopleTypeBecomesOneSite(input: String, pattern: String) {
        #expect(SitePattern.forSite(input) == pattern)
    }

    @Test(arguments: ["", "not a site", "ftp://example.com", "file:///Users", "example", "1.2.3", "*.com", "a..b.com"])
    func nonsenseIsRefused(input: String) {
        #expect(SitePattern.forSite(input) == nil)
    }

    @Test func aSitePatternNamesItsSiteAndABroadOneNamesNothing() {
        #expect(SitePattern.site(of: "*://*.github.com/*") == "github.com")
        #expect(SitePattern.site(of: "https://*.example.org/*") == "example.org")
        #expect(SitePattern.site(of: "*://*/*") == nil)
        #expect(SitePattern.site(of: "<all_urls>") == nil)
        #expect(SitePattern.site(of: "file:///*") == nil)
    }

    @Test func eachSiteSurvivesTheRoundTripThroughItsPattern() {
        for site in ["github.com", "news.ycombinator.com", "localhost", "10.0.0.1"] {
            #expect(SitePattern.forSite(site).flatMap(SitePattern.site(of:)) == site)
        }
    }
}

@Suite struct KeyChordTests {
    @Test func aMenusCapitalLetterIsShift() {
        // SwiftUI may write ⇧⌘T as "T" with ⌘; an extension says "t" with ⇧⌘.
        #expect(KeyChord(key: "T", modifiers: .command) == KeyChord(key: "t", modifiers: [.command, .shift]))
    }

    @Test func differentModifiersAreDifferentChords() {
        #expect(KeyChord(key: "t", modifiers: .command) != KeyChord(key: "t", modifiers: [.command, .shift]))
    }
}

@Suite struct ExtensionDiscoveryTests {
    /// A fake Applications folder: one Safari extension, one other kind of
    /// app extension, and an app one folder down (as Setapp installs).
    func makeApplications() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "zentic-discovery-\(UUID().uuidString)")
        func appex(_ app: String, _ name: String, point: String, id: String) throws {
            let contents = root.appending(path: "\(app)/Contents/PlugIns/\(name).appex/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: NSDictionary = [
                "CFBundleIdentifier": id, "NSExtension": ["NSExtensionPointIdentifier": point],
            ]
            try info.write(to: contents.appending(path: "Info.plist"))
        }
        try appex("Notes Helper.app", "Share", point: "com.apple.share-services", id: "com.example.share")
        try appex("Bitwise.app", "Safari", point: ExtensionDiscovery.extensionPoint, id: "com.example.bitwise.safari")
        try appex("Setapp/Clipper.app", "Ext", point: ExtensionDiscovery.extensionPoint, id: "com.example.clipper.ext")
        return root
    }

    @Test func findsSafariExtensionsOnlyIncludingOneFolderDown() throws {
        let root = try makeApplications()
        defer { try? FileManager.default.removeItem(at: root) }
        let found = ExtensionDiscovery.appExtensions(in: [root])
        #expect(found.map(\.bundleID) == ["com.example.bitwise.safari", "com.example.clipper.ext"])
        #expect(found.map(\.appName) == ["Bitwise", "Clipper"])
    }

    @Test func theSameExtensionInTwoPlacesIsListedOnce() throws {
        let root = try makeApplications()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ExtensionDiscovery.appExtensions(in: [root, root]).count == 2)
    }
}

/// The test extension in `Tests/Fixtures/Extensions/marker`, run in a real
/// web view next to Zentic's own in-page script.
@MainActor
@Suite struct WebExtensionTests {
    static let marker = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/Extensions/marker", directoryHint: .isDirectory)

    @Test func theFixtureIsAValidExtension() async throws {
        let webExtension = try await WKWebExtension(resourceBaseURL: Self.marker)
        #expect(webExtension.errors.isEmpty)
        #expect(webExtension.displayName == "Marker")
        #expect(webExtension.hasInjectedContent)
        #expect(webExtension.requestedPermissions.contains(.tabs))
    }

    /// A page, with Zentic's in-page script installed as every tab has it.
    /// `store` decides whether WebKit sees it as private: a non-persistent
    /// store is how a private window's tabs are told apart.
    func page(_ controller: WKWebExtensionController, store: WKWebsiteDataStore) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.webExtensionController = controller
        for script in InPageScript.userScripts(SiteBook().inPageConfig(), consent: false) {
            configuration.userContentController.addUserScript(script)
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.loadHTMLString("<!doctype html><p>A page.</p>", baseURL: URL(string: "https://example.com/")!)
        // Content scripts run at document end; wait for the document.
        for _ in 0..<100 where webView.isLoading || webView.url == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(200))
        return webView
    }

    func marked(_ webView: WKWebView) async throws -> Bool {
        try await webView.evaluateJavaScript("document.documentElement.dataset.markerExtension === 'ran'") as? Bool == true
    }

    @Test func contentScriptsRunOnlyWhereAllowedAndBesideZenticsOwnScript() async throws {
        let webExtension = try await WKWebExtension(resourceBaseURL: Self.marker)
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let context = WKWebExtensionContext(for: webExtension)
        try controller.load(context)
        let storeID = UUID()
        let store = WKWebsiteDataStore(forIdentifier: storeID)

        // Turned on but not allowed on this site: the page is left alone.
        #expect(try await marked(page(controller, store: store)) == false)

        context.setPermissionStatus(.grantedExplicitly, for: try WKWebExtension.MatchPattern(string: "*://*.example.com/*"))
        let allowed = try await page(controller, store: store)
        #expect(try await marked(allowed))
        // Zentic's in-page script still loaded, and answers in its own world.
        let zentic = try await allowed.evaluateJavaScript("typeof zentic", in: nil, contentWorld: InPageScript.world)
        #expect(zentic as? String == "object")

        try? await WKWebsiteDataStore.remove(forIdentifier: storeID)
    }

    @Test func aPrivateWindowGetsAnExtensionOnlyWhenAllowedIn() async throws {
        let webExtension = try await WKWebExtension(resourceBaseURL: Self.marker)
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let context = WKWebExtensionContext(for: webExtension)
        context.setPermissionStatus(.grantedExplicitly, for: try WKWebExtension.MatchPattern(string: "*://*/*"))
        try controller.load(context)

        // Zentic gives private tabs the same controller on the strength of this.
        #expect(try await marked(page(controller, store: .nonPersistent())) == false)
        context.hasAccessToPrivateData = true
        #expect(try await marked(page(controller, store: .nonPersistent())))
    }
}

