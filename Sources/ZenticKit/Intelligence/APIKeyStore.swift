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

    /// What the Keychain last told us, per provider, for this process.
    ///
    /// `has(_:)` is asked on every menu validation — which AppKit runs on every
    /// menu update and every key equivalent — and each ask used to be a real
    /// `SecItemCopyMatching`. On a Mac whose Keychain wants confirmation for this
    /// item that is an authorisation prompt per keystroke, which is what the user
    /// saw. The value is small, already in this process's memory the moment it is
    /// read once, and every mutation goes through `save`/`remove` here, so the
    /// cache cannot go stale behind our back.
    ///
    /// A `nil` *entry* means "asked, and there is no key" — distinct from no entry
    /// at all, which means "never asked". Without that distinction the absent case
    /// re-hits the Keychain forever, and the absent case is the common one.
    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [Provider: String?] = [:]

        func value(for provider: Provider, orLoad load: () -> String?) -> String? {
            lock.lock()
            if let cached = entries[provider] {
                lock.unlock()
                return cached
            }
            lock.unlock()

            // Deliberately outside the lock: a Keychain read can block on a user
            // prompt, and holding a lock across that would stall every caller.
            let fresh = load()

            lock.lock()
            entries[provider] = fresh
            lock.unlock()
            return fresh
        }

        func set(_ value: String?, for provider: Provider) {
            lock.lock()
            entries[provider] = value
            lock.unlock()
        }
    }

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
            cache.set(nil, for: provider)
            throw APIKeyError.keychain(status)
        }
        cache.set(trimmed, for: provider)
    }

    public static func load(_ provider: Provider) -> String? {
        cache.value(for: provider) { readFromKeychain(provider) }
    }

    private static func readFromKeychain(_ provider: Provider) -> String? {
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
        cache.set(nil, for: provider)
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
