//
//  KeychainGateway.swift
//  Kwota
//
//  The single place in the app that talks to Security.framework.
//
//  Two properties make this type worth existing:
//
//  1. Every call leaves the main thread. A Keychain consent dialog blocks the
//     thread that asked, for as long as it takes a human to answer — two hours,
//     on 2026-08-04. On the main actor that froze the whole app, and with it
//     keep-awake, so the Mac stopped being held awake while agents were working.
//
//  2. Calls are serialised. The flag that suppresses the consent dialog is
//     process-global, so two concurrent Keychain calls would trample each
//     other's setting and a background read could still raise a dialog.
//
//  Because the queue is serial, a probe parked inside SecItemCopyMatching would
//  otherwise block every later call forever. `wedged` breaks that: once a call
//  misses its deadline the gateway fails subsequent calls immediately rather
//  than enqueuing them behind the parked one, and clears itself when the parked
//  work finally answers.
//

import Foundation
import Security

nonisolated enum KeychainInteraction: Sendable {
    /// Background paths. A consent dialog is a defect here, not a prompt.
    case deny
    /// User-initiated paths only — the person is at the machine to answer.
    case allow
}

nonisolated enum KeychainGatewayError: Error, Equatable {
    case interactionNotAllowed
    case timedOut
    case status(OSStatus)
}

/// The raw Security.framework calls, injectable so tests never touch the real
/// Keychain and can simulate a probe that never answers.
nonisolated struct KeychainPrimitives: Sendable {
    var copyMatching: @Sendable ([String: Any]) -> (OSStatus, AnyObject?)
    var add: @Sendable ([String: Any]) -> OSStatus
    var update: @Sendable ([String: Any], [String: Any]) -> OSStatus
    var delete: @Sendable ([String: Any]) -> OSStatus
    var setInteractionAllowed: @Sendable (Bool) -> Void

    static let live = KeychainPrimitives(
        copyMatching: { query in
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        },
        add: { SecItemAdd($0 as CFDictionary, nil) },
        update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
        delete: { SecItemDelete($0 as CFDictionary) },
        setInteractionAllowed: { SecKeychainSetUserInteractionAllowed($0) }
    )
}

nonisolated protocol KeychainGateways: Sendable {
    func read(service: String, account: String?, interaction: KeychainInteraction) async throws -> Data?
    func write(_ data: Data, service: String, account: String) async throws
    func delete(service: String, account: String) async throws
    func deleteAll(service: String) async throws
}

nonisolated final class KeychainGateway: KeychainGateways, @unchecked Sendable {
    static let shared = KeychainGateway()

    private let queue = DispatchQueue(label: "com.thanhhaudev.kwota.keychain")
    private let primitives: KeychainPrimitives
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var wedged = false

    init(primitives: KeychainPrimitives = .live, timeout: TimeInterval = 10) {
        self.primitives = primitives
        self.timeout = timeout
    }

    func read(service: String, account: String?, interaction: KeychainInteraction) async throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        let primitives = self.primitives
        return try await run(interaction: interaction) { () throws -> Data? in
            let (status, result) = primitives.copyMatching(query)
            switch status {
            case errSecSuccess: return result as? Data
            case errSecItemNotFound: return nil
            case errSecInteractionNotAllowed, errSecUserCanceled:
                throw KeychainGatewayError.interactionNotAllowed
            default: throw KeychainGatewayError.status(status)
            }
        }
    }

    func write(_ data: Data, service: String, account: String) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let primitives = self.primitives
        // Writes are only reached from user-initiated paths, but they are still
        // sent with `.deny`: a write that would need consent is a signal, not
        // something to silently prompt for behind a save button.
        try await run(interaction: .deny) {
            let status = primitives.update(query, [kSecValueData as String: data])
            switch status {
            case errSecSuccess: return
            case errSecItemNotFound:
                var insert = query
                insert[kSecValueData as String] = data
                let addStatus = primitives.add(insert)
                guard addStatus == errSecSuccess else {
                    throw KeychainGatewayError.status(addStatus)
                }
            case errSecInteractionNotAllowed, errSecUserCanceled:
                throw KeychainGatewayError.interactionNotAllowed
            default: throw KeychainGatewayError.status(status)
            }
        }
    }

    func delete(service: String, account: String) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        try await deleteMatching(query)
    }

    /// `kSecMatchLimitAll` is required: without it `SecItemDelete` removes one
    /// matching item on macOS and silently leaves the rest.
    func deleteAll(service: String) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        try await deleteMatching(query)
    }

    private func deleteMatching(_ query: [String: Any]) async throws {
        let primitives = self.primitives
        try await run(interaction: .deny) {
            let status = primitives.delete(query)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainGatewayError.status(status)
            }
        }
    }

    /// Hands `work` to the serial queue, applies the interaction policy around
    /// it, and returns to the caller at the deadline whether or not the work
    /// answered. The parked thread is not cancellable — `SecItemCopyMatching`
    /// answers no cancellation — so the deadline protects the caller, and
    /// `wedged` protects everyone behind it.
    private func run<T: Sendable>(
        interaction: KeychainInteraction,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        lock.lock()
        let isWedged = wedged
        lock.unlock()
        if isWedged { throw KeychainGatewayError.timedOut }

        let primitives = self.primitives
        let deadline = timeout
        return try await withCheckedThrowingContinuation { continuation in
            let settled = Settled()
            queue.async { [weak self] in
                primitives.setInteractionAllowed(interaction == .allow)
                let outcome = Result { try work() }
                primitives.setInteractionAllowed(true)
                self?.lock.lock()
                self?.wedged = false
                self?.lock.unlock()
                if settled.claim() { continuation.resume(with: outcome) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline) { [weak self] in
                guard settled.claim() else { return }
                self?.lock.lock()
                self?.wedged = true
                self?.lock.unlock()
                continuation.resume(throwing: KeychainGatewayError.timedOut)
            }
        }
    }
}

/// One-shot winner election between the work and its deadline. A
/// `CheckedContinuation` must be resumed exactly once.
private final class Settled: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
