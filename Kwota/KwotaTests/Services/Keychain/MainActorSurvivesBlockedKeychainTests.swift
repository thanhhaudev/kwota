//
//  MainActorSurvivesBlockedKeychainTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class MainActorSurvivesBlockedKeychainTests: XCTestCase {

    /// Reproduces 2026-08-04: an unanswered consent dialog parks the thread
    /// inside SecItemCopyMatching. Before the gateway, that thread was the main
    /// one and every main-actor deadline died with it.
    @MainActor
    func test_aKeychainProbeThatNeverAnswersDoesNotStallTheMainActor() async throws {
        let primitives = KeychainPrimitives(
            copyMatching: { _ in
                Thread.sleep(forTimeInterval: 60)
                return (errSecSuccess, nil)
            },
            add: { _ in errSecSuccess },
            update: { _, _ in errSecSuccess },
            delete: { _ in errSecSuccess },
            setInteractionAllowed: { _ in }
        )
        let gateway = KeychainGateway(primitives: primitives, timeout: 0.2)
        let store = KeychainCredentialStore(
            service: "com.thanhhaudev.Kwota.test.\(UUID().uuidString)",
            gateway: gateway
        )

        let readTask = Task { @MainActor in
            _ = try? await store.read(for: UUID())
        }

        // While that read is outstanding, ordinary main-actor work must still
        // run promptly. `Task.yield` proves the actor is not blocked.
        let started = Date()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0,
                          "main actor was blocked by an outstanding keychain read")

        _ = await readTask.value
    }
}
