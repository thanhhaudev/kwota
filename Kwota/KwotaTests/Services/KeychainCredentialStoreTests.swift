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

    /// Regression: `KeychainCredentialStore` is `nonisolated`, so `write`/
    /// `read` can genuinely run concurrently from overlapping async calls
    /// (multiple profiles refreshing at once, a switcher fetch overlapping a
    /// token refresh). Before the fix, `encoder`/`decoder` were shared
    /// instance properties — `JSONEncoder`/`JSONDecoder` aren't documented
    /// as safe for concurrent use on the same instance. This fires many
    /// concurrent write-then-read round trips, each with its own id and a
    /// distinct payload, and asserts every single one comes back exactly as
    /// written — a shared, trampled encoder/decoder would risk cross-call
    /// corruption (one call's encoded bytes or decode result bleeding into
    /// another's) surfacing as a mismatch here, even though a hang or crash
    /// from actual internal-state corruption isn't reliably reproducible in
    /// a unit test.
    ///
    /// Deliberately built on an in-memory `KeychainGateways` double, NOT the
    /// default `KeychainGateway.shared` the other tests in this file use:
    /// `.shared` is a process-wide singleton, and firing 25 real concurrent
    /// Keychain calls through it risks real contention tripping its own
    /// `timeout`/`wedged` machinery — which would then fail-fast every OTHER
    /// test in this process that touches the real Keychain for the rest of
    /// the run. This test's target is `KeychainCredentialStore`'s own
    /// encoder/decoder, not `KeychainGateway`'s serialization, so a fast,
    /// hermetic double is the right seam here (see this repo's own
    /// "inject seams for process-wide state" convention).
    func testConcurrentWriteReadRoundTripsDoNotCorruptEachOther() async throws {
        let concurrentStore = KeychainCredentialStore(service: testService, gateway: InMemoryKeychainGateway())
        let iterations = 25
        try await withThrowingTaskGroup(of: (UUID, Credential, Credential?).self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let id = UUID()
                    let cred = Credential.sessionKey(value: "concurrent-\(i)")
                    try await concurrentStore.write(cred, for: id)
                    let loaded = try await concurrentStore.read(for: id)
                    return (id, cred, loaded)
                }
            }
            for try await (id, expected, loaded) in group {
                XCTAssertEqual(loaded, expected, "id \(id) must read back exactly what it wrote, not another call's payload")
            }
        }
    }
}

/// In-memory `KeychainGateways` double for the concurrency test above — a
/// real dictionary keyed by account, guarded by a lock, standing in for the
/// real Keychain without touching the process-wide `KeychainGateway.shared`
/// singleton or real Security.framework contention.
private final class InMemoryKeychainGateway: KeychainGateways, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func read(service: String, account: String?, interaction: KeychainInteraction) async throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let account else { return nil }
        return storage[account]
    }
    func write(_ data: Data, service: String, account: String) async throws {
        lock.lock(); storage[account] = data; lock.unlock()
    }
    func delete(service: String, account: String) async throws {
        lock.lock(); storage.removeValue(forKey: account); lock.unlock()
    }
    func deleteAll(service: String) async throws {
        lock.lock(); storage.removeAll(); lock.unlock()
    }
}
