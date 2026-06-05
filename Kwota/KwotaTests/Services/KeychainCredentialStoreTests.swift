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

    override func tearDown() {
        try? store.deleteAll()
        super.tearDown()
    }

    func testWriteThenReadRoundTripsSessionKey() throws {
        let id = UUID()
        let cred = Credential.sessionKey(value: "sk-abc123")
        try store.write(cred, for: id)
        let loaded = try store.read(for: id)
        XCTAssertEqual(loaded, cred)
    }

    func testReadMissingReturnsNil() throws {
        let id = UUID()
        XCTAssertNil(try store.read(for: id))
    }

    func testWriteOverwritesExisting() throws {
        let id = UUID()
        try store.write(.sessionKey(value: "old"), for: id)
        try store.write(.sessionKey(value: "new"), for: id)
        XCTAssertEqual(try store.read(for: id), .sessionKey(value: "new"))
    }

    func testDeleteRemovesEntry() throws {
        let id = UUID()
        try store.write(.sessionKey(value: "x"), for: id)
        try store.delete(for: id)
        XCTAssertNil(try store.read(for: id))
    }

    func testCLITokenRoundTrips() throws {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let cred = Credential.cliToken(accessToken: "a", refreshToken: "r", expiresAt: date)
        try store.write(cred, for: id)
        XCTAssertEqual(try store.read(for: id), cred)
    }
}
