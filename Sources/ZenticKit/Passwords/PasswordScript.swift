import WebKit

extension InPageScript {
    /// The sign-in watcher (`web/src/passwords-entry.ts`): reports login-field
    /// focus and sign-ins, and fills an account when asked. A few kilobytes,
    /// at document-end — it only adds listeners, and a sign-in form cannot be
    /// used before the document has parsed.
    ///
    /// - Parameter saving: whether the page reports sign-ins at all. Off in a
    ///   private window, so a password typed there never reaches Zentic.
    @MainActor public static func passwordScript(saving: Bool) -> WKUserScript {
        saving ? savingPasswordScript : fillOnlyPasswordScript
    }

    private static let passwordBundle = resource("zentic-passwords")

    // One script object per variant, shared by every tab, as with the core.
    @MainActor private static let savingPasswordScript = WKUserScript(
        source: "window.__zenticPasswordSave = true;\n" + passwordBundle,
        injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world)
    @MainActor private static let fillOnlyPasswordScript = WKUserScript(
        source: passwordBundle, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world)
}
