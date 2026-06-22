import Foundation
import Security

/// Minimal generic-password Keychain wrapper (TECH §8.1).
///
/// Slice 3 stores only the OpenAI API key. Auth session/refresh tokens land in a
/// later slice and can reuse the same get/set/delete helpers with another
/// account. Nothing secret ever touches `UserDefaults`, disk, or logs.
struct KeychainStore {

    /// Generic-password account for the user's OpenAI API key.
    static let openAIKeyAccount = "openai-api-key"

    /// Keychain service scope for all of this app's items.
    static let service = "com.cdcupt.translator-everywhere"

    private let service: String

    init(service: String = KeychainStore.service) {
        self.service = service
    }

    /// Reads the string value for `account`, or `nil` if absent / unreadable.
    func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return value
    }

    /// Writes (or overwrites) `value` for `account`. Empty/whitespace input
    /// deletes the item instead so a blank key never lingers.
    func set(_ value: String, for account: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try delete(account)
            return
        }

        let data = Data(trimmed.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let updateStatus = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    /// Removes the item for `account`. Succeeds even when nothing was stored.
    func delete(_ account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

/// Errors surfaced by `KeychainStore`.
enum KeychainError: Error, Equatable {
    /// A `SecItem*` call returned an unexpected `OSStatus`.
    case unexpectedStatus(OSStatus)
}
