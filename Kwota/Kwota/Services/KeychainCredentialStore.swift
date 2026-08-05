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
    func deleteAll() async throws
}

/// `nonisolated`: none of the work below touches MainActor-only state —
/// every call just awaits the (also `nonisolated`) gateway.
nonisolated final class KeychainCredentialStore {
    enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case decodeFailed
        /// The read needed a consent dialog and the caller did not permit one.
        /// This means "unknown", never "the user signed out" — see
        /// AutoProfileCoordinator and MenuBarViewModel for why that matters.
        case interactionNotAllowed
        case timedOut
    }

    static let productionService = "com.thanhhaudev.Kwota.credential"

    private let service: String
    private let gateway: any KeychainGateways
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(service: String, gateway: any KeychainGateways = KeychainGateway.shared) {
        self.service = service
        self.gateway = gateway
    }

    /// Production credential store — keyed under `productionService`.
    /// Must NOT be used in tests; pass a UUID-namespaced service instead
    /// (e.g. `KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")`).
    static func live() -> KeychainCredentialStore {
        KeychainCredentialStore(service: productionService)
    }

    func write(_ credential: Credential, for id: UUID) async throws {
        let data = try encoder.encode(credential)
        do {
            try await gateway.write(data, service: service, account: id.uuidString)
        } catch let error as KeychainGatewayError {
            throw Self.map(error)
        }
    }

    func read(
        for id: UUID,
        interaction: KeychainInteraction = .deny
    ) async throws -> Credential? {
        do {
            guard let data = try await gateway.read(
                service: service,
                account: id.uuidString,
                interaction: interaction
            ) else { return nil }
            do {
                return try decoder.decode(Credential.self, from: data)
            } catch {
                throw KeychainError.decodeFailed
            }
        } catch let error as KeychainGatewayError {
            throw Self.map(error)
        }
    }

    func delete(for id: UUID) async throws {
        do {
            try await gateway.delete(service: service, account: id.uuidString)
        } catch let error as KeychainGatewayError {
            throw Self.map(error)
        }
    }

    /// Wipes every entry under this service. Used by `DataResetService` for
    /// the nuclear "Reset all data" path, and by tests through UUID-namespaced
    /// services.
    func deleteAll() async throws {
        do {
            try await gateway.deleteAll(service: service)
        } catch let error as KeychainGatewayError {
            throw Self.map(error)
        }
    }

    private static func map(_ error: KeychainGatewayError) -> KeychainError {
        switch error {
        case .interactionNotAllowed: return .interactionNotAllowed
        case .timedOut: return .timedOut
        case .status(let status): return .unexpectedStatus(status)
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
        case .interactionNotAllowed:
            return "Keychain access needs your approval."
        case .timedOut:
            return "The keychain did not respond in time."
        }
    }
}

extension KeychainCredentialStore: KeychainWiping {}
