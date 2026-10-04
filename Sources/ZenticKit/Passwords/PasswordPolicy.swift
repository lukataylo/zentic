import Foundation

/// What to ask after someone signs in.
public enum PasswordOffer: Hashable, Sendable {
    /// A new account: "Save password for example.com?"
    case save(LoginOrigin, username: String, password: String)
    /// A known account with a different password. Several candidates when the
    /// form named no username (a change-password page, usually) and the site
    /// has more than one saved account — the person picks which one changed.
    case update(LoginOrigin, usernames: [String], password: String)

    public var origin: LoginOrigin {
        switch self {
        case .save(let origin, _, _), .update(let origin, _, _): origin
        }
    }
}

/// The decisions about saving and filling, kept apart from the Keychain and the
/// page so each rule can be tested on its own.
public enum PasswordPolicy {
    /// Longer than any real credential; past this a "password" is a form
    /// misread, not something to put in the Keychain.
    public static let maximumLength = 1024

    /// What to offer for a sign-in the page reported.
    ///
    /// - Parameters:
    ///   - stored: the saved password for an account, read only for accounts
    ///     on this origin and only to tell "signed in again" from "changed".
    ///   - neverSave: site keys the person said never to save for.
    ///   - isPrivate: a private window never offers. It writes nothing to
    ///     disk, and a Keychain item is the most lasting write there is.
    public static func offer(
        origin: LoginOrigin, username: String, password: String,
        saved: [SavedLogin], stored: (SavedLogin) -> String?,
        neverSave: Set<String>, isPrivate: Bool
    ) -> PasswordOffer? {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isPrivate, origin.isSecure, !neverSave.contains(origin.siteKey),
            !password.isEmpty, password.count <= maximumLength, username.count <= maximumLength
        else { return nil }

        let accounts = saved.filter { $0.origin == origin }
        if !username.isEmpty {
            guard let account = accounts.first(where: { $0.username == username }) else {
                return .save(origin, username: username, password: password)
            }
            return stored(account) == password ? nil : .update(origin, usernames: [username], password: password)
        }
        // No username on the form. Any account already holding this password
        // means a re-sign-in, not a change.
        if accounts.isEmpty { return .save(origin, username: "", password: password) }
        if accounts.contains(where: { stored($0) == password }) { return nil }
        return .update(origin, usernames: accounts.map(\.username), password: password)
    }

    /// Whether a saved password may go into a page of `page`'s origin: the
    /// exact origin it was saved for, and never over an unencrypted connection.
    public static func canFill(_ login: SavedLogin, into page: LoginOrigin?) -> Bool {
        guard let page else { return false }
        return page == login.origin && page.isSecure
    }

    /// The accounts to suggest on `page`, in a stable order.
    public static func suggestions(_ saved: [SavedLogin], for page: LoginOrigin?) -> [SavedLogin] {
        saved.filter { canFill($0, into: page) }
            .sorted { $0.username.localizedStandardCompare($1.username) == .orderedAscending }
    }
}
