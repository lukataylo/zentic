import Foundation
import Security

/// Keychain storage for a bring-your-own API key.
///
/// The Keychain and nowhere else. A key in `UserDefaults` is world-readable to
/// anything running as the user; a key in a source file or a dotfile ends up in a
/// commit, a screenshot, or a support log — this project has already had one
/// near-miss where a desktop screenshot captured a key in a terminal. The only
/// storage that is right by construction is the one the OS encrypts.
///
/// Note this is *not* a contradiction of invariant 7. A BYO key is a credential
/// the user chose to supply so their own requests reach their own account; it is
/// not browsing data, and nothing about what they read is stored here.
public enum APIKeyStore {
    public enum Provider: String, Sendable, CaseIterable {
        case openAI = "openai"

        public var title: String {
            switch self {
            case .openAI: "OpenAI"
            }
        }
    }

    private static let service = "com.zentic.apikeys"

    public static func save(_ key: String, for provider: Provider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            remove(provider)
            return
        }
        // Delete first: SecItemUpdate needs a different query shape, and add-only
        // fails with errSecDuplicateItem on a key that is being replaced.
        remove(provider)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecValueData as String: Data(trimmed.utf8),
            // Never syncs, and unavailable until the Mac has been unlocked once.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw APIKeyError.keychain(status)
        }
    }

    public static func load(_ provider: Provider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let key = String(data: data, encoding: .utf8)
        else { return nil }
        return key
    }

    public static func remove(_ provider: Provider) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }

    public static func has(_ provider: Provider) -> Bool { load(provider) != nil }

    /// A key with its middle removed, for showing in a preferences field.
    public static func redacted(_ provider: Provider) -> String? {
        guard let key = load(provider), key.count > 12 else { return nil }
        return "\(key.prefix(7))…\(key.suffix(4))"
    }
}

public enum APIKeyError: Error, Sendable, Equatable {
    case keychain(OSStatus)
    case missing(APIKeyStore.Provider)
}
