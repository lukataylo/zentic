import Foundation
import Testing

@testable import ZenticKit

@Suite struct LoginOriginTests {
    @Test func defaultPortsAreTheSameOriginAsNoPort() {
        // WebKit reports a default port as 0; a URL may spell out 443.
        let fromFrame = LoginOrigin(scheme: "https", host: "Example.com", port: 0)
        #expect(fromFrame == LoginOrigin(url: URL(string: "https://example.com:443/login")))
        #expect(fromFrame == LoginOrigin(url: URL(string: "https://EXAMPLE.com/")))
        #expect(fromFrame?.serialized == "https://example.com")
    }

    @Test func aDifferentPortSchemeOrSubdomainIsADifferentOrigin() {
        let origin = LoginOrigin(url: URL(string: "https://example.com"))
        #expect(origin != LoginOrigin(url: URL(string: "https://example.com:8443")))
        #expect(origin != LoginOrigin(url: URL(string: "http://example.com")))
        #expect(origin != LoginOrigin(url: URL(string: "https://accounts.example.com")))
        #expect(LoginOrigin(url: URL(string: "https://example.com:8443"))?.serialized == "https://example.com:8443")
    }

    @Test func onlyWebPagesHaveALoginOrigin() {
        #expect(LoginOrigin(url: URL(string: "file:///Users/me/login.html")) == nil)
        #expect(LoginOrigin(url: URL(string: "about:blank")) == nil)
        #expect(LoginOrigin(scheme: "https", host: "", port: 0) == nil)
    }

    @Test func plainHTTPIsInsecureExceptOnThisMac() {
        #expect(LoginOrigin(url: URL(string: "http://example.com"))?.isSecure == false)
        #expect(LoginOrigin(url: URL(string: "http://localhost:3000"))?.isSecure == true)
        #expect(LoginOrigin(url: URL(string: "http://127.0.0.1:8080"))?.isSecure == true)
        // Not a loopback address, however it is spelled.
        #expect(LoginOrigin(url: URL(string: "http://localhost.evil.example"))?.isSecure == false)
    }
}

@Suite struct PasswordPolicyTests {
    let site = LoginOrigin(url: URL(string: "https://example.com"))!

    func offer(
        username: String = "ada", password: String = "new-secret", saved: [SavedLogin] = [],
        stored: [String: String] = [:], never: Set<String> = [], isPrivate: Bool = false, on origin: LoginOrigin? = nil
    ) -> PasswordOffer? {
        PasswordPolicy.offer(
            origin: origin ?? site, username: username, password: password, saved: saved,
            stored: { stored[$0.username] }, neverSave: never, isPrivate: isPrivate)
    }

    @Test func aNewAccountIsOfferedToSave() {
        #expect(offer() == .save(site, username: "ada", password: "new-secret"))
    }

    @Test func signingInAgainWithTheSamePasswordOffersNothing() {
        let ada = SavedLogin(origin: site, username: "ada")
        #expect(offer(password: "same", saved: [ada], stored: ["ada": "same"]) == nil)
    }

    @Test func aChangedPasswordIsOfferedAsAnUpdate() {
        let ada = SavedLogin(origin: site, username: "ada")
        #expect(offer(saved: [ada], stored: ["ada": "old"]) == .update(site, usernames: ["ada"], password: "new-secret"))
    }

    @Test func anAccountOnAnotherOriginDoesNotCount() {
        // Saved for accounts.example.com: example.com is a new account, not an update.
        let elsewhere = SavedLogin(origin: LoginOrigin(url: URL(string: "https://accounts.example.com"))!, username: "ada")
        #expect(offer(saved: [elsewhere], stored: ["ada": "old"]) == .save(site, username: "ada", password: "new-secret"))
    }

    @Test func aChangeFormWithoutAUsernameAsksWhichAccountChanged() {
        let ada = SavedLogin(origin: site, username: "ada")
        let bob = SavedLogin(origin: site, username: "bob")
        #expect(offer(username: "", saved: [ada, bob], stored: ["ada": "a", "bob": "b"]) == .update(site, usernames: ["ada", "bob"], password: "new-secret"))
        // Re-entering a password one of them already has is a sign-in, not a change.
        #expect(offer(username: "", password: "b", saved: [ada, bob], stored: ["ada": "a", "bob": "b"]) == nil)
    }

    @Test func neverSaveCoversTheWholeSiteWithAndWithoutWWW() {
        let www = LoginOrigin(url: URL(string: "https://www.example.com"))!
        #expect(offer(never: ["example.com"]) == nil)
        #expect(offer(never: ["example.com"], on: www) == nil)
        #expect(offer(never: ["other.com"]) != nil)
    }

    @Test func aPrivateWindowNeverOffers() {
        #expect(offer(isPrivate: true) == nil)
    }

    @Test func plainHTTPIsNeverOffered() {
        #expect(offer(on: LoginOrigin(url: URL(string: "http://example.com"))!) == nil)
    }

    @Test func emptyOrAbsurdPasswordsAreNotOffered() {
        #expect(offer(password: "") == nil)
        #expect(offer(password: String(repeating: "x", count: PasswordPolicy.maximumLength + 1)) == nil)
    }

    @Test func fillingNeedsTheExactSecureOrigin() {
        let ada = SavedLogin(origin: site, username: "ada")
        #expect(PasswordPolicy.canFill(ada, into: site))
        #expect(!PasswordPolicy.canFill(ada, into: LoginOrigin(url: URL(string: "https://evil-example.com"))))
        #expect(!PasswordPolicy.canFill(ada, into: LoginOrigin(url: URL(string: "https://example.com.evil.net"))))
        #expect(!PasswordPolicy.canFill(ada, into: LoginOrigin(url: URL(string: "http://example.com"))))
        #expect(!PasswordPolicy.canFill(ada, into: nil))
        // Saved on http (by an older build, or Keychain Access): never filled, even there.
        let insecure = SavedLogin(origin: LoginOrigin(url: URL(string: "http://example.com"))!, username: "ada")
        #expect(!PasswordPolicy.canFill(insecure, into: insecure.origin))
    }

    @Test func suggestionsAreThisOriginsAccountsInOrder() {
        let logins = [
            SavedLogin(origin: site, username: "zoe"),
            SavedLogin(origin: LoginOrigin(url: URL(string: "https://other.com"))!, username: "ada"),
            SavedLogin(origin: site, username: "Bob"),
        ]
        #expect(PasswordPolicy.suggestions(logins, for: site).map(\.username) == ["Bob", "zoe"])
    }
}
