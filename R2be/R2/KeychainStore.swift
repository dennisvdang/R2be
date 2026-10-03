import Foundation
import Security

/// Stores every saved R2 connection as one JSON array in the iOS Keychain (device-only, after first unlock).
enum KeychainStore {
    private static let service = "R2be.credentials"
    private static let account = "default"

    static func load() -> [R2Credentials] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return [] }
        if let list = try? JSONDecoder().decode([R2Credentials].self, from: data) { return list }

        // Builds before multi-bucket support saved a single connection.
        return (try? JSONDecoder().decode(R2Credentials.self, from: data)).map { [$0] } ?? []
    }

    @discardableResult
    static func save(_ creds: [R2Credentials]) -> Bool {
        guard let data = try? JSONEncoder().encode(creds) else { return false }
        delete()
        if creds.isEmpty { return true }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
