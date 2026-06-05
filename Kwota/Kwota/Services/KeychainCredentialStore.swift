//
//  KeychainCredentialStore.swift
//  Kwota
//
//  Wraps Security.framework. Stored value: JSON-encoded `Credential`,
//  keyed by Profile.id.uuidString as kSecAttrAccount.
//

import Foundation
import Security

/// Minimal injection seam for the nuclear-reset path in `DataResetService`.
/// Production conformance is `KeychainCredentialStore`. Tests inject a stub
/// to simulate Keychain failures without touching the real Keychain.
protocol KeychainWiping {
    func deleteAll() throws
}

final class KeychainCredentialStore {
    enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case decodeFailed
    }

    static let productionService = "com.thanhhaudev.Kwota.credential"

    private let service: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(service: String) {
        self.service = service
    }

    /// Production credential store — keyed under `productionService`.
    /// Must NOT be used in tests; pass a UUID-namespaced service instead
    /// (e.g. `KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")`).
    static func live() -> KeychainCredentialStore {
        KeychainCredentialStore(service: productionService)
    }

    func write(_ credential: Credential, for id: UUID) throws {
        let data = try encoder.encode(credential)
        let account = id.uuidString

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func read(for id: UUID) throws -> Credential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.decodeFailed }
            return try decoder.decode(Credential.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func delete(for id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Wipes every entry under this service. Used by `DataResetService` for
    /// the nuclear "Reset all data" path, and by tests through UUID-namespaced
    /// services.
    ///
    /// `kSecMatchLimitAll` is required: without it, `SecItemDelete` on macOS
    /// only removes one matching item, silently leaving the rest.
    func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

extension KeychainCredentialStore.KeychainError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain error \(status)"
        case .decodeFailed:
            return "Credential data could not be decoded."
        }
    }
}

extension KeychainCredentialStore: KeychainWiping {}
