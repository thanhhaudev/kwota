//
//  CLITokenRefresherTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class CLITokenRefresherTests: XCTestCase {
    private var store: KeychainCredentialStore!
    private var testService: String!
    private var temp: TempDirectory!
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        try await super.setUp()
        testService = "com.thanhhaudev.Kwota.refresher.test.\(UUID().uuidString)"
        store = KeychainCredentialStore(service: testService)
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        try? store.deleteAll()
        try await super.tearDown()
    }

    private func makeReader(_ probeJSON: String?) -> CLICredentialReader {
        CLICredentialReader(
            credentialsFile: temp.file("missing.json"),
            keychainProbe: { probeJSON.map { Data($0.utf8) } }
        )
    }

    private func makeRefresher(reader: CLICredentialReader, now: Date) -> CLITokenRefresher {
        CLITokenRefresher(reader: reader, store: store, now: { now })
    }

    private func cliToken(access: String, expiresAt: Date) -> Credential {
        .cliToken(accessToken: access, refreshToken: "r", expiresAt: expiresAt)
    }

    func testFreshenIsNoOpWhenStoredTokenHasMoreThanMinLifetime() throws {
        let id = UUID()
        let stored = cliToken(access: "stored", expiresAt: baseDate.addingTimeInterval(120))
        try store.write(stored, for: id)

        var probeCalled = false
        let reader = CLICredentialReader(
            credentialsFile: temp.file("missing.json"),
            keychainProbe: {
                probeCalled = true
                return nil
            }
        )
        let refresher = makeRefresher(reader: reader, now: baseDate)

        let result = try refresher.freshen(profileId: id, current: stored, minLifetime: 60)
        XCTAssertEqual(result, stored)
        XCTAssertFalse(probeCalled, "Probe must not be touched when stored token still has lifetime headroom")
    }

    func testFreshenReadsCLIWhenTokenIsWithinMinLifetime() throws {
        let id = UUID()
        let stored = cliToken(access: "stale", expiresAt: baseDate.addingTimeInterval(30))
        try store.write(stored, for: id)

        let kcJSON = #"""
        {"accessToken":"fresh","refreshToken":"r","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        let refresher = makeRefresher(reader: makeReader(kcJSON), now: baseDate)

        let result = try refresher.freshen(profileId: id, current: stored, minLifetime: 60)
        guard case .cliToken(let access, _, _) = result else { return XCTFail("expected cliToken") }
        XCTAssertEqual(access, "fresh")

        // Verify it was persisted to the store as well.
        let persisted = try store.read(for: id)
        XCTAssertEqual(persisted, result)
    }

    func testFreshenReadsCLIWhenStoredTokenAlreadyExpired() throws {
        let id = UUID()
        let stored = cliToken(access: "expired", expiresAt: baseDate.addingTimeInterval(-3600))
        try store.write(stored, for: id)

        let kcJSON = #"""
        {"accessToken":"fresh","refreshToken":"r","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        let refresher = makeRefresher(reader: makeReader(kcJSON), now: baseDate)

        let result = try refresher.freshen(profileId: id, current: stored, minLifetime: 60)
        guard case .cliToken(let access, _, _) = result else { return XCTFail("expected cliToken") }
        XCTAssertEqual(access, "fresh")
    }

    func testFreshenReturnsCurrentAndDoesNotWriteWhenAccessTokenUnchanged() throws {
        let id = UUID()
        // Stored token's expiry is past — so freshen will read CLI; CLI returns
        // the same access token (CLI hasn't rotated yet). Refresher must NOT
        // overwrite the store with a token that's already there.
        let stored = cliToken(access: "same", expiresAt: baseDate.addingTimeInterval(-10))
        try store.write(stored, for: id)

        let kcJSON = #"""
        {"accessToken":"same","refreshToken":"r","expiresAt":"2025-01-01T00:00:00Z"}
        """#
        let refresher = makeRefresher(reader: makeReader(kcJSON), now: baseDate)

        let result = try refresher.freshen(profileId: id, current: stored, minLifetime: 60)
        XCTAssertEqual(result, stored, "Same access token → return the supplied current credential unchanged")
    }

    func testFreshenRethrowsWhenReaderFails() throws {
        let id = UUID()
        let stored = cliToken(access: "stale", expiresAt: baseDate.addingTimeInterval(-10))
        try store.write(stored, for: id)

        // Empty file path + nil keychain probe → reader.read() throws.
        let reader = CLICredentialReader(
            credentialsFile: temp.file("missing.json"),
            keychainProbe: { nil }
        )
        let refresher = makeRefresher(reader: reader, now: baseDate)

        XCTAssertThrowsError(try refresher.freshen(profileId: id, current: stored, minLifetime: 60))
    }

    func testFreshenReturnsCurrentWhenCredentialIsNotCLIToken() throws {
        let id = UUID()
        let stored: Credential = .sessionKey(value: "sk-xyz")

        var probeCalled = false
        let reader = CLICredentialReader(
            credentialsFile: temp.file("missing.json"),
            keychainProbe: {
                probeCalled = true
                return nil
            }
        )
        let refresher = makeRefresher(reader: reader, now: baseDate)

        let result = try refresher.freshen(profileId: id, current: stored, minLifetime: 60)
        XCTAssertEqual(result, stored)
        XCTAssertFalse(probeCalled)
    }

    func testForceRefreshReadsAndWritesWhenNoPreviousProvided() throws {
        let id = UUID()
        // Stored token is fresh (would skip on freshen). forceRefresh must read anyway.
        let stored = cliToken(access: "stored", expiresAt: baseDate.addingTimeInterval(3600))
        try store.write(stored, for: id)

        let kcJSON = #"""
        {"accessToken":"forced","refreshToken":"r","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        let refresher = makeRefresher(reader: makeReader(kcJSON), now: baseDate)

        let result = try refresher.forceRefresh(profileId: id)
        guard case .cliToken(let access, _, _)? = result else { return XCTFail("expected cliToken") }
        XCTAssertEqual(access, "forced")

        let persisted = try store.read(for: id)
        XCTAssertEqual(persisted, result)
    }

    func testForceRefreshReturnsNilWhenReaderFails() throws {
        let id = UUID()
        let reader = CLICredentialReader(
            credentialsFile: temp.file("missing.json"),
            keychainProbe: { nil }
        )
        let refresher = makeRefresher(reader: reader, now: baseDate)

        XCTAssertNil(try refresher.forceRefresh(profileId: id))
    }

    func testForceRefreshReturnsNilAndSkipsWriteWhenAccessTokenUnchanged() throws {
        // Important: after a 401, the call site passes the credential that
        // just failed. If the CLI keychain still holds the same token, we
        // must short-circuit so the caller does not retry the API with the
        // same bad bearer.
        let id = UUID()
        let previous = cliToken(access: "same", expiresAt: baseDate.addingTimeInterval(3600))

        let kcJSON = #"""
        {"accessToken":"same","refreshToken":"r","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        let refresher = makeRefresher(reader: makeReader(kcJSON), now: baseDate)

        let result = try refresher.forceRefresh(profileId: id, previous: previous)
        XCTAssertNil(result, "Identical token after 401 → return nil instead of bouncing the same token back")

        // Store must remain untouched (we never wrote anything for this id).
        XCTAssertNil(try store.read(for: id), "Store must not be written when CLI hasn't rotated")
    }

    func testFreshenMemoizesReaderReadWithinCacheWindow() throws {
        // Coordinator tick + popoverDidOpen() có thể fire sát nhau. Cả 2 lần
        // đều thấy stored token sắp expire → cả 2 đều gọi reader.read().
        // Reader chạm Touch ID-protected keychain → 2 OS prompt liên tiếp.
        // Memoization phải skip reader.read() trong window 10s.
        let id = UUID()
        let stored = cliToken(access: "stale", expiresAt: baseDate.addingTimeInterval(-10))
        try store.write(stored, for: id)

        let kcJSON = #"""
        {"accessToken":"fresh","refreshToken":"r","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        var readCallCount = 0
        let reader = CLICredentialReader(
            credentialsFile: temp.file("missing.json"),
            keychainProbe: {
                readCallCount += 1
                return Data(kcJSON.utf8)
            }
        )
        let refresher = makeRefresher(reader: reader, now: baseDate)

        // 3 lần gọi liên tiếp với cùng `current` (đã expire) — chỉ lần đầu
        // được phép đụng keychain.
        let r1 = try refresher.freshen(profileId: id, current: stored, minLifetime: 60)
        let r2 = try refresher.freshen(profileId: id, current: stored, minLifetime: 60)
        let r3 = try refresher.freshen(profileId: id, current: stored, minLifetime: 60)

        XCTAssertEqual(readCallCount, 1, "Subsequent freshen calls within TTL must reuse cached credential")
        guard case .cliToken(let a1, _, _) = r1,
              case .cliToken(let a2, _, _) = r2,
              case .cliToken(let a3, _, _) = r3 else {
            return XCTFail("expected cliToken")
        }
        XCTAssertEqual(a1, "fresh")
        XCTAssertEqual(a2, "fresh")
        XCTAssertEqual(a3, "fresh")
    }

    func testFreshenCacheExpiresAfterTTL() throws {
        // Sau TTL, cache phải invalidate → reader.read() lại được gọi.
        let id = UUID()
        let stored = cliToken(access: "stale", expiresAt: baseDate.addingTimeInterval(-10))
        try store.write(stored, for: id)

        let kcJSON = #"""
        {"accessToken":"fresh","refreshToken":"r","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        var readCallCount = 0
        let reader = CLICredentialReader(
            credentialsFile: temp.file("missing.json"),
            keychainProbe: {
                readCallCount += 1
                return Data(kcJSON.utf8)
            }
        )
        // now() cần advance qua TTL (10s) cho lần gọi thứ 2.
        var currentNow = baseDate
        let refresher = CLITokenRefresher(reader: reader, store: store, now: { currentNow })

        _ = try refresher.freshen(profileId: id, current: stored, minLifetime: 60)
        XCTAssertEqual(readCallCount, 1)

        // Advance past TTL.
        currentNow = baseDate.addingTimeInterval(15)
        _ = try refresher.freshen(profileId: id, current: stored, minLifetime: 60)
        XCTAssertEqual(readCallCount, 2, "After cache TTL, reader must be re-consulted")
    }

    func testForceRefreshWritesAndReturnsRotatedTokenWhenPreviousDiffers() throws {
        let id = UUID()
        let previous = cliToken(access: "old", expiresAt: baseDate.addingTimeInterval(3600))

        let kcJSON = #"""
        {"accessToken":"new","refreshToken":"r","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        let refresher = makeRefresher(reader: makeReader(kcJSON), now: baseDate)

        let result = try refresher.forceRefresh(profileId: id, previous: previous)
        guard case .cliToken(let access, _, _)? = result else { return XCTFail("expected cliToken") }
        XCTAssertEqual(access, "new")

        let persisted = try store.read(for: id)
        XCTAssertEqual(persisted, result)
    }
}
