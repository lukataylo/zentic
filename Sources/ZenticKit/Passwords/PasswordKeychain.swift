import Foundation
import Security

/// Saved passwords, as internet-password items in the login Keychain.
///
/// The Keychain and nowhere else: no file, no `UserDefaults`, no cache of
/// secrets in memory. Each item is a standard web-form password — server is
/// the host, account the username — so it shows up in Keychain Access as what
/// it is, and macOS encrypts it at rest.
///
/// Every call blocks on `securityd` and can wait on a system prompt, so call
/// these off the main thread.
public enum PasswordKeychain {
    /// Marks Zentic's items among every other app's internet passwords in the
    /// same keychain, so listing never shows (or deletes) someone else's.
    /// An isolated run (`ZENTIC_DATA_DIR`) gets a domain of its own.
    static let domain = DataDirectory.isIsolated ? "zentic.\(DataDirectory.isolationID)" : "zentic"

    /// Every saved account, attributes only. Reads no secret, so it never prompts.
    public static func logins() throws -> [SavedLogin] {
        var query = base
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw PasswordKeychainError(status: status)
        }
        return items.compactMap { item in
            guard let server = item[kSecAttrServer as String] as? String,
                let origin = LoginOrigin(
                    scheme: scheme(for: item[kSecAttrProtocol as String]), host: server,
                    port: (item[kSecAttrPort as String] as? NSNumber)?.intValue)
            else { return nil }
            return SavedLogin(origin: origin, username: item[kSecAttrAccount as String] as? String ?? "")
        }
    }

    /// The password for one account, or nil if it is gone.
    public static func password(for login: SavedLogin) -> String? {
        var query = self.query(for: login)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Save a password for an account, replacing the one stored if it exists.
    public static func save(_ password: String, for login: SavedLogin) throws {
        let data = Data(password.utf8)
        let update = SecItemUpdate(query(for: login) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw PasswordKeychainError(status: update) }
        var item = query(for: login)
        item[kSecValueData as String] = data
        // What Keychain Access shows in its Name column.
        item[kSecAttrLabel as String] = login.origin.displayName
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw PasswordKeychainError(status: status) }
    }

    /// Change an account's username and password in one step. Refuses to
    /// rename onto another saved account rather than silently merging the two.
    public static func edit(_ login: SavedLogin, username: String, password: String) throws {
        let changes: [String: Any] = [
            kSecAttrAccount as String: username,
            kSecValueData as String: Data(password.utf8),
        ]
        let status = SecItemUpdate(query(for: login) as CFDictionary, changes as CFDictionary)
        guard status == errSecSuccess else { throw PasswordKeychainError(status: status) }
    }

    public static func delete(_ login: SavedLogin) throws {
        let status = SecItemDelete(query(for: login) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PasswordKeychainError(status: status) }
    }

    // MARK: -

    private static var base: [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: domain,
        ]
    }

    private static func query(for login: SavedLogin) -> [String: Any] {
        var query = base
        query[kSecAttrServer as String] = login.origin.host
        query[kSecAttrAccount as String] = login.username
        query[kSecAttrProtocol as String] = login.origin.scheme == "https" ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP
        query[kSecAttrAuthenticationType as String] = kSecAttrAuthenticationTypeHTMLForm
        query[kSecAttrPort as String] = login.origin.port ?? 0
        return query
    }

    private static func scheme(for protocolAttribute: Any?) -> String {
        (protocolAttribute as? String) == (kSecAttrProtocolHTTP as String) ? "http" : "https"
    }
}

public struct PasswordKeychainError: Error, Equatable, Sendable, LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        switch status {
        case errSecDuplicateItem: "A password for that username is already saved for this site."
        case errSecUserCanceled, errSecAuthFailed: "The Keychain didn’t allow it."
        default: (SecCopyErrorMessageString(status, nil) as String?) ?? "The Keychain reported error \(status)."
        }
    }
}
