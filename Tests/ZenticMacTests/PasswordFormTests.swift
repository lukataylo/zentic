import AppKit
import Foundation
import Testing
import WebKit

@testable import ZenticKit

extension AppIntegration {
    /// The sign-in script in WebKit, where `isTrusted` is real. jsdom cannot
    /// make a trusted event, so `web/test/passwords.test.ts` stubs the check;
    /// this is the half of invariant 11 that only a browser engine can test:
    /// a page that fills and sends its own form is never taken for a person.
    @MainActor
    @Suite struct PasswordForms {
        /// What the script posts, as `TabDelegate` receives it.
        final class Messages: NSObject, WKScriptMessageHandler {
            var received: [[String: Any]] = []
            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
                if let body = message.body as? [String: Any] { received.append(body) }
            }
            func of(_ type: String) -> [[String: Any]] { received.filter { $0["type"] as? String == type } }
        }

        let messages = Messages()

        /// The sign-in page in a web view that has a window, so it can be the
        /// first responder and take typing. The window is never shown.
        func signInPage(saving: Bool = true) async throws -> (WKWebView, NSWindow) {
            let server = try await AppIntegration.server()
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(messages, contentWorld: InPageScript.world, name: InPageScript.handlerName)
            configuration.userContentController.addUserScript(InPageScript.passwordScript(saving: saving))
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = webView
            window.makeFirstResponder(webView)
            try await webView.loadAndWait(server.url("login.html"))
            // The script is injected at document-end; it is there once its global is.
            try await eventually("the sign-in script") {
                try await webView.zentic("return typeof zenticPasswords") as? String == "object"
            }
            return (webView, window)
        }

        func focus(_ id: String, in webView: WKWebView) async throws {
            _ = try await webView.page("document.getElementById('\(id)').focus()")
        }

        /// Key presses through AppKit, as the keyboard sends them: WebKit
        /// makes them trusted `keydown`s and `input`s.
        func type(_ text: String, into webView: WKWebView, window: NSWindow) async throws {
            for character in text {
                let key = String(character)
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                    isARepeat: false, keyCode: 0))
                webView.keyDown(with: event)
            }
            try await eventually("the typed password") {
                try await webView.page("return document.activeElement.value") as? String == text
            }
        }

        @Test func reportsSignInFieldsAndNothingElse() async throws {
            let (webView, window) = try await signInPage()
            defer { window.close() }

            try await focus("query", in: webView)
            try await focus("new-email", in: webView)
            try await focus("new-password", in: webView)
            try await focus("username", in: webView)
            try await eventually("the username field's report") { !messages.of("login-field").isEmpty }
            try await focus("password", in: webView)
            try await eventually("the password field's report") { messages.of("login-field").count == 2 }

            let roles = messages.of("login-field").map { $0["role"] as? String }
            #expect(roles == ["username", "password"], "a search box and a sign-up form are not sign-ins")
            let rect = try #require(messages.of("login-field").last?["rect"] as? [String: Any])
            #expect((rect["width"] as? NSNumber)?.doubleValue ?? 0 > 0, "the menu needs the field's place")
        }

        @Test func aPageThatSignsInByItselfIsNeverOfferedForSaving() async throws {
            let (webView, window) = try await signInPage()
            defer { window.close() }

            _ = try await webView.page("""
                document.getElementById("username").value = "ada";
                const password = document.getElementById("password");
                password.value = "planted";
                password.dispatchEvent(new Event("input", { bubbles: true }));
                document.getElementById("login").requestSubmit();
                """)
            // The page's submit is trusted, so the script has run by the time
            // this round trip to the page comes back; give it one more turn.
            _ = try await webView.page("await new Promise((resolve) => setTimeout(resolve, 0))")
            #expect(messages.of("login-submit").isEmpty)
        }

        /// `execCommand` edits go through the editor, and WebKit marks the
        /// `input` they fire trusted: without a key press behind it, a page
        /// could type a password of its choosing "for" the person.
        @Test func aPageTypingThroughTheEditorIsNotAPerson() async throws {
            let (webView, window) = try await signInPage()
            defer { window.close() }

            _ = try await webView.page("""
                document.getElementById("username").value = "ada";
                document.getElementById("password").focus();
                document.execCommand("insertText", false, "planted");
                document.getElementById("login").requestSubmit();
                """)
            _ = try await webView.page("await new Promise((resolve) => setTimeout(resolve, 0))")
            #expect(try await webView.page("return document.getElementById('password').value") as? String == "planted")
            #expect(messages.of("login-submit").isEmpty)
        }

        @Test func aPersonTypingAPasswordIsOfferedIt() async throws {
            let (webView, window) = try await signInPage()
            defer { window.close() }

            _ = try await webView.page("document.getElementById('username').value = 'ada'")
            try await focus("password", in: webView)
            try await type("correct horse", into: webView, window: window)
            _ = try await webView.page("document.getElementById('login').requestSubmit()")
            try await eventually("the sign-in to be reported") { !messages.of("login-submit").isEmpty }

            let sent = try #require(messages.of("login-submit").first)
            #expect(sent["username"] as? String == "ada")
            #expect(sent["password"] as? String == "correct horse")
        }

        @Test func aPrivateWindowNeverReportsASignIn() async throws {
            let (webView, window) = try await signInPage(saving: false)
            defer { window.close() }

            _ = try await webView.page("document.getElementById('username').value = 'ada'")
            try await focus("password", in: webView)
            try await type("correct horse", into: webView, window: window)
            _ = try await webView.page("document.getElementById('login').requestSubmit()")
            _ = try await webView.page("await new Promise((resolve) => setTimeout(resolve, 0))")
            #expect(messages.of("login-submit").isEmpty)
            // AutoFill still works there: fields are reported, sign-ins are not.
            #expect(!messages.of("login-field").isEmpty)
        }
    }
}
