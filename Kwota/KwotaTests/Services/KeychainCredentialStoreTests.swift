//
//  KeychainCredentialStoreTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class KeychainCredentialStoreTests: XCTestCase {
    private var store: KeychainCredentialStore!
    private var testService: String!

    override func setUp() {
        super.setUp()
        testService = "com.thanhhaudev.Kwota.test.\(UUID().uuidString)"
        store = KeychainCredentialStore(service: testService)
    }

    override func tearDown() async throws {
        try? await store.deleteAll()
        try await super.tearDown()
    }

    func testWriteThenReadRoundTripsSessionKey() async throws {
        let id = UUID()
        let cred = Credential.sessionKey(value: "sk-abc123")
        try await store.write(cred, for: id)
        let loaded = try await store.read(for: id)
        XCTAssertEqual(loaded, cred)
    }

    func testReadMissingReturnsNil() async throws {
        let id = UUID()
        let loaded = try await store.read(for: id)
        XCTAssertNil(loaded)
    }

    func testWriteOverwritesExisting() async throws {
        let id = UUID()
        try await store.write(.sessionKey(value: "old"), for: id)
        try await store.write(.sessionKey(value: "new"), for: id)
        let loaded = try await store.read(for: id)
        XCTAssertEqual(loaded, .sessionKey(value: "new"))
    }

    func testDeleteRemovesEntry() async throws {
        let id = UUID()
        try await store.write(.sessionKey(value: "x"), for: id)
        try await store.delete(for: id)
        let loaded = try await store.read(for: id)
        XCTAssertNil(loaded)
    }

    func testCLITokenRoundTrips() async throws {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let cred = Credential.cliToken(accessToken: "a", refreshToken: "r", expiresAt: date)
        try await store.write(cred, for: id)
        let loaded = try await store.read(for: id)
        XCTAssertEqual(loaded, cred)
    }
}
