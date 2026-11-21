import Foundation
import Security

/// Keeps the user's Claude API key in the iOS Keychain.
///
/// How the key is protected:
/// - Stored only in the Keychain, never in the database, files, UserDefaults or logs.
/// - `WhenUnlockedThisDeviceOnly`: readable only while the iPad is unlocked,
///   never synced to iCloud Keychain and never included in backups, so it
///   can't leave this device.
/// - Read at the moment a request is made and never kept in app state.
enum APIKeyStore {
    private static let service = "com.denasohrabi.memor.claude"
    private static let account = "anthropic-api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    static var hasKey: Bool {
        var query = baseQuery
        query[kSecReturnData as String] = false
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// The saved key, or nil. Call only right before sending a request.
    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A safe hint for showing which key is saved, like "sk-ant-…a1B2".
    static func maskedHint() -> String? {
        guard let key = read(), key.count > 10 else { return nil }
        return "\(key.prefix(7))…\(key.suffix(4))"
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let data = Data(key.utf8)
        delete()
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
