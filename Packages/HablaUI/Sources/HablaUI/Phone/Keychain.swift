import Foundation
import Security

/// The pairing token lives in the iPhone Keychain (this device only, never in backups).
enum Keychain {
    static let service = "com.habla.pairing"

    static func set(_ value: String, for account: String) {
        #if os(iOS)
        delete(account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
        #else
        UserDefaults.standard.set(value, forKey: "\(service).\(account)")   // Mac builds are tests/snapshots only
        #endif
    }

    static func get(_ account: String) -> String? {
        #if os(iOS)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
        #else
        return UserDefaults.standard.string(forKey: "\(service).\(account)")
        #endif
    }

    static func delete(_ account: String) {
        #if os(iOS)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        #else
        UserDefaults.standard.removeObject(forKey: "\(service).\(account)")
        #endif
    }
}
