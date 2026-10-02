import Foundation
import Security

// MARK: - KeychainServiceProtocol

protocol KeychainServiceProtocol: Sendable {
    func store(token: String) throws
    func retrieve() throws -> String?
    func delete() throws
}

// MARK: - KeychainService

struct KeychainService: KeychainServiceProtocol {
    private let service = "dev.ghbonk.pat"
    private let account = "github-pat"

    func store(token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw GhBonkError.keychainWriteFailed(errSecParam)
        }

        // Delete any existing item first (upsert behavior)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add the new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw GhBonkError.keychainWriteFailed(status)
        }
    }

    func retrieve() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let token = String(data: data, encoding: .utf8) else {
                throw GhBonkError.keychainReadFailed(errSecDecode)
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw GhBonkError.keychainReadFailed(status)
        }
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GhBonkError.keychainWriteFailed(status)
        }
    }
}
