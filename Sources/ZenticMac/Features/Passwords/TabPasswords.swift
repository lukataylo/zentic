import AppKit
import Observation
import SwiftUI
import WebKit
import ZenticKit

/// One tab's side of passwords: the suggestion menu under a sign-in field,
/// and the offer to save after a sign-in.
@MainActor
@Observable
final class TabPasswords {
    /// The accounts offered under the focused sign-in field.
    struct Menu: Equatable {
        var origin: LoginOrigin
        var logins: [SavedLogin]
        /// The field, in the web view's coordinates.
        var anchor: CGRect
        /// Arrow keys move this; nil until the first one.
        var highlighted: Int?
        /// The page is plain http: the menu warns instead of offering.
        var insecure: Bool { !origin.isSecure }
    }

    enum Prompt: Equatable {
        case offer(PasswordOffer)
        /// The moment after Save: a check mark, then gone.
        case saved(PasswordOffer)
        case failed(PasswordOffer, String)
    }

    private(set) var menu: Menu?
    private(set) var prompt: Prompt?

    @ObservationIgnored private weak var tab: Tab?
    /// Bumped by every request to show or close the menu. Showing waits on the
    /// Keychain, so a request answered after a newer one is dropped, not shown.
    @ObservationIgnored private var menuRequest = 0
    /// When the offer was made. It outlives the sign-in's own redirects, not
    /// the next page the person goes to.
    @ObservationIgnored private var offeredAt: ContinuousClock.Instant?
    private var webView: WKWebView? { tab?.webView }
    private var isPrivate: Bool { tab?.browser?.isPrivate == true }

    init(tab: Tab) { self.tab = tab }

    // MARK: Messages from the page

    /// A `login-*` message from the in-page script. `origin` is WebKit's
    /// record of the frame that sent it, never anything the page says.
    func receive(_ message: [String: Any], from frame: WKSecurityOrigin) {
        let origin = LoginOrigin(scheme: frame.protocol, host: frame.host, port: frame.port)
        switch message["type"] as? String {
        case "login-field":
            guard Passwords.shared.autoFill, let origin, let rect = Self.rect(message["rect"]) else { return }
            Task { await showMenu(on: origin, field: rect) }
        case "login-dismiss":
            closeMenu(tellingPage: false)
        case "login-key":
            key(message["key"] as? String)
        case "login-submit":
            guard let origin, !isPrivate,
                let username = message["username"] as? String, let password = message["password"] as? String
            else { return }
            Task {
                guard let offer = await Passwords.shared.offer(
                    origin: origin, username: username, password: password, isPrivate: isPrivate)
                else { return }
                prompt = .offer(offer)
                offeredAt = .now
                AccessibilityNotification.Announcement(Self.title(for: offer)).post()
            }
        default:
            break
        }
    }

    /// A new document: a menu under the old one's field means nothing now.
    /// An offer stays through the redirects that follow a sign-in, then goes,
    /// rather than hang over unrelated pages holding the password.
    func pageChanged() {
        closeMenu(tellingPage: false)
        if case .offer = prompt, let offeredAt, ContinuousClock.now - offeredAt > Self.offerLifetime { prompt = nil }
    }

    static let offerLifetime: Duration = .seconds(30)

    // MARK: Menu

    /// ⇧⌘A: find the page's sign-in, focus it and offer its accounts —
    /// whatever the AutoFill setting, since this is the person asking.
    func showMenuOnPage() {
        guard let webView else { return NSSound.beep() }
        Task {
            let found = try? await webView.callAsyncJavaScript(
                "const p = window.zenticPasswords; return p ? p.locate() : null;",
                contentWorld: InPageScript.world) as? [String: Any]
            guard let found, let rect = Self.rect(found["rect"]), let origin = LoginOrigin(url: webView.url) else {
                return NSSound.beep()
            }
            await showMenu(on: origin, field: rect, evenIfEmpty: true)
        }
    }

    private func showMenu(on origin: LoginOrigin, field: CGRect, evenIfEmpty: Bool = false) async {
        menuRequest += 1
        let request = menuRequest
        await Passwords.shared.loadIfNeeded()
        guard request == menuRequest, let webView else { return }
        let logins = Passwords.shared.suggestions(for: origin)
        // A plain-http sign-in is warned about whether or not anything is saved.
        guard !logins.isEmpty || !origin.isSecure || evenIfEmpty else {
            menu = nil
            return tellPage(menu: "closed")
        }
        // CSS pixels to the web view's points.
        let scale = webView.pageZoom * webView.magnification
        let anchor = CGRect(
            x: field.minX * scale, y: field.minY * scale + webView.obscuredContentInsets.top,
            width: field.width * scale, height: field.height * scale)
        // Keep the highlight across a re-report of the same field, but only
        // while it still points at an account.
        let kept = menu?.origin == origin ? menu?.highlighted.flatMap { logins.indices.contains($0) ? $0 : nil } : nil
        let next = Menu(origin: origin, logins: logins, anchor: anchor, highlighted: kept)
        // The page keeps arrow keys and Return only while there is something to pick.
        tellPage(menu: next.logins.isEmpty ? "shown" : kept == nil ? "open" : "highlighted")
        if menu == nil, !logins.isEmpty {
            // Focus stays in the page, so say there is something to pick.
            AccessibilityNotification.Announcement(
                logins.count == 1 ? "1 saved password. Press Down Arrow to choose it."
                    : "\(logins.count) saved passwords. Press Down Arrow to choose one."
            ).post()
        }
        menu = next
    }

    func closeMenu() { closeMenu(tellingPage: true) }

    private func closeMenu(tellingPage: Bool) {
        // Also drops a menu still waiting on the Keychain.
        menuRequest += 1
        guard menu != nil else { return }
        menu = nil
        if tellingPage { tellPage(menu: "closed") }
    }

    private func key(_ key: String?) {
        // A key the page held for a menu that is gone: give the keys back.
        guard var menu, !menu.logins.isEmpty else { return tellPage(menu: "closed") }
        let count = menu.logins.count
        switch key {
        case "down": menu.highlighted = ((menu.highlighted ?? -1) + 1) % count
        case "up": menu.highlighted = ((menu.highlighted ?? count) - 1 + count) % count
        case "enter":
            if let index = menu.highlighted { fill(menu.logins[index]) }
            return
        case "escape":
            return closeMenu(tellingPage: false)
        default:
            return
        }
        self.menu = menu
        tellPage(menu: "highlighted")
    }

    /// Fill the account the person picked. Asks for Touch ID or the login
    /// password first (unless just given), then checks once more that the
    /// page is still the exact secure origin the account was saved for — the
    /// prompt takes long enough for a page to navigate underneath it.
    func fill(_ login: SavedLogin) {
        closeMenu(tellingPage: false)
        tellPage(menu: "closed")
        Task {
            guard PasswordPolicy.canFill(login, into: LoginOrigin(url: webView?.url)),
                let password = await Passwords.shared.password(
                    for: login, reason: "fill your password for \(login.origin.displayName)"),
                let webView, PasswordPolicy.canFill(login, into: LoginOrigin(url: webView.url))
            else { return }
            // A click on the menu, or the Touch ID sheet, took focus from the
            // page; the person goes on typing in the form just filled.
            webView.window?.makeFirstResponder(webView)
            _ = try? await webView.callAsyncJavaScript(
                "const p = window.zenticPasswords; return p ? p.fill(origin, username, password) : false;",
                arguments: ["origin": login.origin.serialized, "username": login.username, "password": password],
                contentWorld: InPageScript.world)
        }
    }

    private func tellPage(menu state: String) {
        Task {
            _ = try? await webView?.callAsyncJavaScript(
                "window.zenticPasswords?.menu(state)", arguments: ["state": state], contentWorld: InPageScript.world)
        }
    }

    // MARK: Save prompt

    func save(_ offer: PasswordOffer, as username: String? = nil) {
        let (origin, name, password): (LoginOrigin, String, String) =
            switch offer {
            case .save(let origin, let username, let password): (origin, username, password)
            case .update(let origin, let usernames, let password): (origin, username ?? usernames[0], password)
            }
        Task {
            do {
                try await Passwords.shared.save(password, for: SavedLogin(origin: origin, username: name))
                withAnimation(.smooth(duration: 0.3)) { prompt = .saved(offer) }
                try? await Task.sleep(for: .seconds(1.4))
                if prompt == .saved(offer) { withAnimation(.smooth(duration: 0.3)) { prompt = nil } }
            } catch {
                prompt = .failed(offer, error.localizedDescription)
            }
        }
    }

    func neverSave(_ offer: PasswordOffer) {
        Passwords.shared.neverSave(offer.origin.siteKey)
        prompt = nil
    }

    func dismissPrompt() { prompt = nil }

    static func title(for offer: PasswordOffer) -> String {
        switch offer {
        case .save(let origin, _, _): "Save password for \(origin.displayName)?"
        case .update(let origin, let usernames, _) where usernames.count == 1:
            "Update password for \(usernames[0].isEmpty ? origin.displayName : usernames[0])?"
        case .update(let origin, _, _): "Update a password for \(origin.displayName)?"
        }
    }

    private static func rect(_ value: Any?) -> CGRect? {
        guard let rect = value as? [String: Any],
            let x = (rect["x"] as? NSNumber)?.doubleValue, let y = (rect["y"] as? NSNumber)?.doubleValue,
            let width = (rect["width"] as? NSNumber)?.doubleValue, let height = (rect["height"] as? NSNumber)?.doubleValue
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
