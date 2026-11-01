import Foundation
import Security

/// API anahtarları gibi gizli değerlerin saklandığı yer.
protocol SecretStore: AnyObject {
    func string(for key: String) -> String?
    func set(_ value: String?, for key: String)
}

/// Gizli değerleri iOS anahtar zincirinde (Keychain) saklar.
final class KeychainStore: SecretStore {
    static let shared = KeychainStore()

    private let service = "com.carmirror.assistant"

    func string(for key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, for key: String) {
        let query = baseQuery(for: key)
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("CarMirror: anahtar zincirine yazılamadı (\(status))")
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

/// Testler için bellek içi saklama.
final class InMemorySecretStore: SecretStore {
    private var values: [String: String] = [:]

    func string(for key: String) -> String? { values[key] }

    func set(_ value: String?, for key: String) {
        if let value, !value.isEmpty {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
    }
}
