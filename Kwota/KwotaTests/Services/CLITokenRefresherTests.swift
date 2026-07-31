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

    private func makeRefresher(reader: any CLICredentialReading, now: Date) -> CLITokenRefresher {
        CLITokenRefresher(reader: reader, store: store, now: { now })
    }

    private func cliToken(access: String, expiresAt: Date) -> Credential {
        .cliToken(accessToken: access, refreshToken: "r", expiresAt: expiresAt)
    }

    func testFreshenIsNoOpWhenStoredTokenHasMoreThanMinLifetime() async throws {
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

        let result = try await refresher.freshen(profileId: id, current: stored, minLifetime: 60)
        XCTAssertEqual(result, stored)
        XCTAssertFalse(probeCalled, "Probe must not be touched when stored token still has lifetime headroom")
    }

    func testFreshenReadsCLIWhenTokenIsWithinMinLifetime() async throws {
        let id = UUID()
        let stored = cliToken(access: "stale", expiresAt: baseDate.addingTimeInterval(30))
        try store.write(stored, for: id)

        let kcJSON = #"""
        {"accessToken":"fresh","refreshToken":"r","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        let refresher = makeRefresher(reader: makeReader(kcJSON), now: baseDate)

        let result = try await refresher.freshen(profileId: id, current: stored, minLifetime: 60)
        guard case .cliToken(let access, _, _) = result else { return XCTFail("expected cliToken") }
        XCTAssertEqual(access, "fresh")

        // Verify it was persisted to the store as well.
        let persisted = try store.read(for: id)
        XCTAssertEqual(persisted, result)
    }

    func testFreshenReadsCLIWhenStoredTokenAlreadyExpired() async throws {
        let id = UUID()
        let stored = cliToken(access: "expired", expiresAt: baseDate.addingTimeInterval(-3600))
        try store.write(stored, for: id)

        let kcJSON = #"""
        {"accessToken":"fresh","refreshToken":"r","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        let refresher = makeRefresher(reader: makeReader(kcJSON), now: baseDate)

        let result = try await refresher.freshen(profileId: id, current: stored, minLifetime: 60)
        guard case .cliToken(let access, _, _) = result else { return XCTFail("expected cliToken") }
        XCTAssertEqual(access, "fresh")
    }

    func testFreshenReturnsCurrentAndDoesNotWriteWhenAccessTokenUnchanged() async throws {
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

        let result = try await refresher.freshen(profileId: id, current: stored, minLifetime: 60)
        XCTAssertEqual(result, stored, "Same access token → return the supplied current credential unchanged")
    }

    func testFreshenRethrowsWhenReaderFails() async throws {
        let id = UUID()
        let stored = cliToken(access: "stale", expiresAt: baseDate.addingTimeInterval(-10))
        try store.write(stored, for: id)

        // Empty file path + nil keychain probe → reader.read() throws.
        let reader = CLICredentialReader(
            credentialsFile: temp.file("missing.json"),
            keychainProbe: { nil }
        )
        let refresher = makeRefresher(reader: reader, now: baseDate)

        do {
            _ = try await refresher.freshen(profileId: id, current: stored, minLifetime: 60)
            XCTFail("expected freshen to rethrow the reader failure")
        } catch {
            // expected
        }
    }

    func testFreshenReturnsCurrentWhenCredentialIsNotCLIToken() async throws {
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

        let result = try await refresher.freshen(profileId: id, current: stored, minLifetime: 60)
        XCTAssertEqual(result, stored)
        XCTAssertFalse(probeCalled)
    }

    func testForceRefreshReadsAndWritesWhenNoPreviousProvided() async throws {
        let id = UUID()
        // Stored token is fresh (would skip on freshen). forceRefresh must read anyway.
        let stored = cliToken(access: "stored", expiresAt: baseDate.addingTimeInterval(3600))
        try store.write(stored, for: id)

        let kcJSON = #"""
        {"accessToken":"forced","refreshToken":"r","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        let refresher = makeRefresher(reader: makeReader(kcJSON), now: baseDate)

        let result = try await refresher.forceRefresh(profileId: id)
        guard case .cliToken(let access, _, _)? = result else { return XCTFail("expected cliToken") }
        XCTAssertEqual(access, "forced")

        let persisted = try store.read(for: id)
        XCTAssertEqual(persisted, result)
    }

    func testForceRefreshReturnsNilWhenReaderFails() async throws {
        let id = UUID()
        let reader = CLICredentialReader(
            credentialsFile: temp.file("missing.json"),
            keychainProbe: { nil }
        )
        let refresher = makeRefresher(reader: reader, now: baseDate)

        let forced = try await refresher.forceRefresh(profileId: id)
        XCTAssertNil(forced)
    }

    func testForceRefreshReturnsNilAndSkipsWriteWhenAccessTokenUnchanged() async throws {
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

        let result = try await refresher.forceRefresh(profileId: id, previous: previous)
        XCTAssertNil(result, "Identical token after 401 → return nil instead of bouncing the same token back")

        // Store must remain untouched (we never wrote anything for this id).
        XCTAssertNil(try store.read(for: id), "Store must not be written when CLI hasn't rotated")
    }

    func testFreshenMemoizesReaderReadWithinCacheWindow() async throws {
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
        let r1 = try await refresher.freshen(profileId: id, current: stored, minLifetime: 60)
        let r2 = try await refresher.freshen(profileId: id, current: stored, minLifetime: 60)
        let r3 = try await refresher.freshen(profileId: id, current: stored, minLifetime: 60)

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

    func testFreshenCacheExpiresAfterTTL() async throws {
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

        _ = try await refresher.freshen(profileId: id, current: stored, minLifetime: 60)
        XCTAssertEqual(readCallCount, 1)

        // Advance past TTL.
        currentNow = baseDate.addingTimeInterval(15)
        _ = try await refresher.freshen(profileId: id, current: stored, minLifetime: 60)
        XCTAssertEqual(readCallCount, 2, "After cache TTL, reader must be re-consulted")
    }

    func testForceRefreshWritesAndReturnsRotatedTokenWhenPreviousDiffers() async throws {
        let id = UUID()
        let previous = cliToken(access: "old", expiresAt: baseDate.addingTimeInterval(3600))

        let kcJSON = #"""
        {"accessToken":"new","refreshToken":"r","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        let refresher = makeRefresher(reader: makeReader(kcJSON), now: baseDate)

        let result = try await refresher.forceRefresh(profileId: id, previous: previous)
        guard case .cliToken(let access, _, _)? = result else { return XCTFail("expected cliToken") }
        XCTAssertEqual(access, "new")

        let persisted = try store.read(for: id)
        XCTAssertEqual(persisted, result)
    }

    // MARK: - Post-read identity gate

    /// `MenuBarViewModel.refresh` checks the CLI identity once, before the
    /// fetch chain starts. The read below happens after that check and is only
    /// bounded by the reader's own timeout, so a `claude login` into another
    /// account can land inside it. Writing what comes back would persist the
    /// other account's token under this profile and immediately fetch with it —
    /// account B's usage recorded under account A.
    func testFreshenSkipsWriteWhenTheCLIAccountChangesDuringTheRead() async throws {
        let id = UUID()
        let stored = cliToken(access: "mine", expiresAt: baseDate.addingTimeInterval(-10))
        try store.write(stored, for: id)

        let kcJSON = #"""
        {"accessToken":"other-account","refreshToken":"r","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        // The switch happens *inside* the read, which is what makes a pre-check
        // insufficient and this gate necessary.
        var identityStillMatches = true
        let reader = CLICredentialReader(
            credentialsFile: temp.file("missing.json"),
            keychainProbe: {
                identityStillMatches = false
                return Data(kcJSON.utf8)
            }
        )
        let refresher = CLITokenRefresher(
            reader: reader, store: store, now: { self.baseDate },
            identityCheck: { _ in identityStillMatches }
        )

        let result = try await refresher.freshen(profileId: id, current: stored, minLifetime: 60)

        XCTAssertEqual(result, stored,
                       "must hand back this profile's own token, not the other account's")
        XCTAssertEqual(try store.read(for: id), stored,
                       "the other account's token must never be persisted under this profile")
    }

    func testFreshenStillWritesWhenTheIdentityCheckPasses() async throws {
        // The gate must not become "never rotate": the ordinary path, where the
        // account is unchanged across the read, still has to write.
        let id = UUID()
        let stored = cliToken(access: "stale", expiresAt: baseDate.addingTimeInterval(-10))
        try store.write(stored, for: id)

        let kcJSON = #"""
        {"accessToken":"fresh","refreshToken":"r","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        let refresher = CLITokenRefresher(
            reader: makeReader(kcJSON), store: store, now: { self.baseDate },
            identityCheck: { _ in true }
        )

        let result = try await refresher.freshen(profileId: id, current: stored, minLifetime: 60)
        guard case .cliToken(let access, _, _) = result else { return XCTFail("expected cliToken") }
        XCTAssertEqual(access, "fresh")
        XCTAssertEqual(try store.read(for: id), result)
    }

    /// Same race on the 401 recovery path. Here the credential is not only
    /// persisted but handed straight back for an immediate retry, so a
    /// mismatched token would be used against the API as well as stored.
    func testForceRefreshReturnsNilWhenTheCLIAccountChangesDuringTheRead() async throws {
        let id = UUID()
        let previous = cliToken(access: "mine", expiresAt: baseDate.addingTimeInterval(3600))

        let kcJSON = #"""
        {"accessToken":"other-account","refreshToken":"r","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        var identityStillMatches = true
        let reader = CLICredentialReader(
            credentialsFile: temp.file("missing.json"),
            keychainProbe: {
                identityStillMatches = false
                return Data(kcJSON.utf8)
            }
        )
        let refresher = CLITokenRefresher(
            reader: reader, store: store, now: { self.baseDate },
            identityCheck: { _ in identityStillMatches }
        )

        let result = try await refresher.forceRefresh(profileId: id, previous: previous)

        XCTAssertNil(result, "a token from another account must not be retried with")
        XCTAssertNil(try store.read(for: id),
                     "nor persisted under this profile on the way past")
    }

    func testForceRefreshBypassesSharedCredentialCache() async throws {
        let id = UUID()
        let previous = cliToken(access: "old", expiresAt: baseDate.addingTimeInterval(3600))
        let source = CountingRefreshCredentialReader(results: [
            .success(CLICredentialReader.SyncResult(
                credential: previous,
                subscriptionPlan: nil
            )),
            .success(CLICredentialReader.SyncResult(
                credential: cliToken(access: "new", expiresAt: baseDate.addingTimeInterval(7200)),
                subscriptionPlan: nil
            ))
        ])
        let cachedReader = CachedCLICredentialReader(reader: source, ttl: 60, now: { self.baseDate })

        _ = try await cachedReader.read()
        let refresher = makeRefresher(reader: cachedReader, now: baseDate)
        let result = try await refresher.forceRefresh(profileId: id, previous: previous)

        XCTAssertEqual(source.readCount, 2)
        guard case .cliToken(let access, _, _)? = result else { return XCTFail("expected cliToken") }
        XCTAssertEqual(access, "new")
    }
}

private final class CountingRefreshCredentialReader: CLICredentialReading {
    // Driven from one test at a time, each call joined by an `await`.
    private nonisolated(unsafe) var results: [Result<CLICredentialReader.SyncResult, Error>]
    private(set) nonisolated(unsafe) var readCount = 0

    init(results: [Result<CLICredentialReader.SyncResult, Error>]) {
        self.results = results
    }

    func read() async throws -> CLICredentialReader.SyncResult {
        readCount += 1
        guard !results.isEmpty else {
            throw NSError(domain: "test", code: 404)
        }
        return try results.removeFirst().get()
    }
}
