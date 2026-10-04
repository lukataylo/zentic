import Foundation
import Testing

@testable import ZenticKit

@Suite struct PermissionBookTests {
    @Test func everythingAsksUntilDecided() {
        let book = PermissionBook()
        for permission in SitePermission.allCases {
            #expect(book.outcome(permission, for: "example.com") == .prompt)
        }
    }

    @Test func anExplicitAnswerSurvivesAChangeOfDefault() {
        // "Ask" chosen for one site is consent withheld; making the default
        // "Allow" later must not quietly turn that site's camera on.
        var book = PermissionBook()
        book.set(.ask, .camera, for: "bank.com")
        book.setDefault(.allow, for: .camera)
        #expect(book.outcome(.camera, for: "bank.com") == .prompt)
        #expect(book.outcome(.camera, for: "other.com") == .grant)
    }

    @Test func aDefaultBackAtTheBuiltInIsNotStored() {
        // Otherwise every file would pin today's built-in default forever.
        var book = PermissionBook()
        book.setDefault(.deny, for: .location)
        book.setDefault(.ask, for: .location)
        #expect(book.defaults.isEmpty)
    }

    @Test func removingTheLastDecisionForgetsTheSite() {
        var book = PermissionBook()
        book.set(.allow, .camera, for: "meet.com")
        book.set(.deny, .location, for: "meet.com")
        book.set(nil, .camera, for: "meet.com")
        #expect(book.sites(for: .camera).isEmpty)
        #expect(book.sites(for: .location).map(\.site) == ["meet.com"])
        book.set(nil, .location, for: "meet.com")
        #expect(book.sites.isEmpty)
    }

    @Test func aClickedPopupOpensEvenWhereBlocked() {
        var book = PermissionBook()
        book.set(.deny, .popups, for: "news.com")
        #expect(book.outcome(.popups, for: "news.com", userInitiated: true) == .grant)
        #expect(book.outcome(.popups, for: "news.com", userInitiated: false) == .deny)
        // And only pop-ups: a click is not consent to the camera.
        book.set(.deny, .camera, for: "news.com")
        #expect(book.outcome(.camera, for: "news.com", userInitiated: true) == .deny)
    }

    @Test func onlyAFreshClickOnThisDocumentOpensAPopup() {
        // Clicked half a second ago, on this page: a "Sign in with…" pop-up.
        #expect(UserGesture.counts(inputAt: 10, now: 10.5, documentStart: 5))
        // The click that loaded the page is not the new page's gesture, or a
        // pop-up fired at load would ride on it.
        #expect(!UserGesture.counts(inputAt: 10, now: 10.5, documentStart: 10.2))
        // A timer firing long after the last click.
        #expect(!UserGesture.counts(inputAt: 10, now: 12, documentStart: 5))
        // No input yet at all.
        #expect(!UserGesture.counts(inputAt: -.infinity, now: 10, documentStart: 0))
    }

    @Test func aPrivateWindowsAnswersWinWithoutTouchingTheBook() {
        var shared = PermissionBook()
        shared.set(.allow, .camera, for: "meet.com")
        shared.set(.deny, .location, for: "meet.com")
        let overlaid = shared.overlaying(["meet.com": [.camera: .deny], "new.com": [.microphone: .allow]])
        #expect(overlaid.decision(.camera, for: "meet.com") == .deny)
        // The site's other decisions still apply in the private window.
        #expect(overlaid.decision(.location, for: "meet.com") == .deny)
        #expect(overlaid.decision(.microphone, for: "new.com") == .allow)
        #expect(shared.decision(.camera, for: "meet.com") == .allow)
    }

    @Test func savedAsReadableObjects() throws {
        // Enum-keyed dictionaries encode as a flat [key, value, …] array
        // unless the key is CodingKeyRepresentable — unreadable, and fragile.
        var book = PermissionBook()
        book.set(.allow, .camera, for: "meet.com")
        book.setDefault(.deny, for: .popups)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any]
        #expect((json?["sites"] as? [String: [String: String]])?["meet.com"] == ["camera": "allow"])
        #expect((json?["defaults"] as? [String: String]) == ["popups": "deny"])
        #expect(try JSONDecoder().decode(PermissionBook.self, from: JSONEncoder().encode(book)) == book)
    }

    @Test func aFileFromANewerZenticKeepsWhatThisOneUnderstands() throws {
        // Failing to decode would make JSONFile set the whole file aside and
        // every site would be asked again.
        let json = """
            {"defaults": {"camera": "allow", "bluetooth": "deny"},
             "sites": {"meet.com": {"camera": "allow", "midi": "allow"},
                       "usb.dev": {"usb": "allow"},
                       "odd.com": {"camera": "sometimes"}}}
            """
        let book = try JSONDecoder().decode(PermissionBook.self, from: Data(json.utf8))
        #expect(book.defaultDecision(for: .camera) == .allow)
        #expect(book.decision(.camera, explicitlyFor: "meet.com") == .allow)
        // A site left with nothing this version knows is not kept as an empty entry.
        #expect(book.sites.keys.sorted() == ["meet.com"])
    }
}
