import Foundation
import Security

enum CredentialStore {
    private static let service = "run.kandot.oh-my-openclaw.credentials"

    private static func itemQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    static func read<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        var query = itemQuery(key)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialError(status: status) }
        return try JSONDecoder().decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        let query = itemQuery(key)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            let status = SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
            guard status == errSecSuccess else { throw CredentialError(status: status) }
        } else if update != errSecSuccess { throw CredentialError(status: update) }
    }

    static func delete(key: String) throws {
        let status = SecItemDelete(itemQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError(status: status, operation: "削除") }
    }

    private struct CredentialError: LocalizedError {
        let status: OSStatus
        var operation = "保存"
        var errorDescription: String? { "接続情報を\(operation)できませんでした（\(status)）。端末のロックを解除してやり直してください。" }
    }
}
