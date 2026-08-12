import Foundation
import Security

enum ProviderKeychain {
    private static let service = "com.leetcode-ai-assistant.provider-key"

    static func marker(for providerID: String) -> String {
        "keychain:v1:\(providerID)"
    }

    static func store(_ secret: String, providerID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(secret.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var inserted = query
            inserted[kSecValueData as String] = Data(secret.utf8)
            let addStatus = SecItemAdd(inserted as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ProviderKeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw ProviderKeychainError.status(status)
        }
    }

    static func read(providerID: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw ProviderKeychainError.status(status)
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func readIfPresent(providerID: String) throws -> String? {
        do { return try read(providerID: providerID) }
        catch ProviderKeychainError.status(errSecItemNotFound) { return nil }
    }

    static func delete(providerID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderKeychainError.status(status)
        }
    }
}

enum ProviderKeychainError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let status):
            SecCopyErrorMessageString(status, nil) as String? ?? "无法访问 macOS 钥匙串（\(status)）"
        }
    }
}
