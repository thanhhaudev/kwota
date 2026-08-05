//
//  CLICredentialReaderTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class CLICredentialReaderTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() {
        super.setUp()
        temp = TempDirectory()
    }

    func testIsAvailableFalseWhenNeitherSourceExists() {
        let reader = CLICredentialReader(
            credentialsFile: temp.file("missing.json"),
            gateway: StubKeychainGateway(read: { nil })
        )
        XCTAssertFalse(reader.isAvailable)
    }

    func testIsAvailableTrueWhenFileExists() throws {
        let url = temp.file("creds.json")
        try Data("{}".utf8).write(to: url)
        let reader = CLICredentialReader(credentialsFile: url, gateway: StubKeychainGateway(read: { nil }))
        XCTAssertTrue(reader.isAvailable)
    }

    func testIsAvailableFalseWhenOnlyKeychainHasPayload() {
        // isAvailable is file-only — a Keychain payload alone does not count.
        let reader = CLICredentialReader(
            credentialsFile: temp.file("missing.json"),
            gateway: StubKeychainGateway(read: { Data("{}".utf8) })
        )
        XCTAssertFalse(reader.isAvailable)
    }

    func test_isAvailable_doesNotProbeKeychain() {
        let gateway = StubKeychainGateway(read: { Data("x".utf8) })
        let reader = CLICredentialReader(
            credentialsFile: URL(fileURLWithPath: "/nonexistent/.credentials.json"),
            gateway: gateway
        )
        _ = reader.isAvailable
        XCTAssertEqual(gateway.readCount, 0, "isAvailable must not read the Keychain")
        XCTAssertFalse(reader.isAvailable, "no file present → not available")
    }

    func testReadFromFileReturnsCLIToken() async throws {
        let url = temp.file("creds.json")
        let json = #"""
        {"accessToken":"a-token","refreshToken":"r-token","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        try Data(json.utf8).write(to: url)
        let reader = CLICredentialReader(credentialsFile: url, gateway: StubKeychainGateway(read: { nil }))
        let result = try await reader.read()
        guard case .cliToken(let access, let refresh, let expires) = result.credential else {
            return XCTFail("expected cliToken")
        }
        XCTAssertEqual(access, "a-token")
        XCTAssertEqual(refresh, "r-token")
        XCTAssertEqual(expires, ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z"))
        XCTAssertNil(result.subscriptionPlan)
    }

    func testReadFromKeychainEnvelopePrefersKeychainOverFile() async throws {
        let url = temp.file("creds.json")
        let fileJSON = #"""
        {"accessToken":"file","refreshToken":"file","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        try Data(fileJSON.utf8).write(to: url)

        let kcJSON = #"""
        {"claudeAiOauth":{"accessToken":"kc","refreshToken":"kc-r","expiresAt":1893456000000,"subscriptionType":"max"}}
        """#
        let reader = CLICredentialReader(
            credentialsFile: url,
            gateway: StubKeychainGateway(read: { Data(kcJSON.utf8) })
        )
        let result = try await reader.read()
        guard case .cliToken(let access, _, _) = result.credential else { return XCTFail("expected cliToken") }
        XCTAssertEqual(access, "kc")
        XCTAssertEqual(result.subscriptionPlan, "max")
    }

    func testReadFromKeychainFlatPayload() async throws {
        let kcJSON = #"""
        {"accessToken":"flat","refreshToken":"r","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        let reader = CLICredentialReader(
            credentialsFile: temp.file("missing.json"),
            gateway: StubKeychainGateway(read: { Data(kcJSON.utf8) })
        )
        let result = try await reader.read()
        guard case .cliToken(let access, _, _) = result.credential else { return XCTFail("expected cliToken") }
        XCTAssertEqual(access, "flat")
    }

    func testReadThrowsWhenFileMalformedAndKeychainEmpty() async throws {
        let url = temp.file("creds.json")
        try Data("not json".utf8).write(to: url)
        let reader = CLICredentialReader(credentialsFile: url, gateway: StubKeychainGateway(read: { nil }))
        await assertThrows { _ = try await reader.read() }
    }

    func testCachedReaderReusesSuccessfulReadWithinTTL() async throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let source = CountingCredentialReader(results: [
            .success(syncResult(access: "first")),
            .success(syncResult(access: "second"))
        ])
        let reader = CachedCLICredentialReader(reader: source, ttl: 10, now: { now })

        let first = try await reader.read()
        now = now.addingTimeInterval(5)
        let second = try await reader.read()

        XCTAssertEqual(source.readCount, 1)
        XCTAssertEqual(accessToken(first.credential), "first")
        XCTAssertEqual(accessToken(second.credential), "first")
    }

    func testCachedReaderCachesFailureWithinTTL() async {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let source = CountingCredentialReader(results: [
            .failure(NSError(domain: "test", code: 1)),
            .success(syncResult(access: "second"))
        ])
        let reader = CachedCLICredentialReader(reader: source, ttl: 10, now: { now })

        await assertThrows { _ = try await reader.read() }
        now = now.addingTimeInterval(5)
        await assertThrows { _ = try await reader.read() }

        XCTAssertEqual(source.readCount, 1)
    }

    func testCachedReaderReadFreshBypassesCache() async throws {
        let source = CountingCredentialReader(results: [
            .success(syncResult(access: "first")),
            .success(syncResult(access: "second"))
        ])
        let reader = CachedCLICredentialReader(reader: source, ttl: 10)

        let first = try await reader.read()
        let second = try await reader.readFresh()

        XCTAssertEqual(source.readCount, 2)
        XCTAssertEqual(accessToken(first.credential), "first")
        XCTAssertEqual(accessToken(second.credential), "second")
    }

    func test_readDoesNotBlockTheMainActor() async throws {
        // A reader whose probe sleeps stands in for an unanswered Keychain
        // consent dialog — the shape that froze every release path in F-003.
        let started = DispatchSemaphore(value: 0)
        let reader = CLICredentialReader(
            credentialsFile: URL(fileURLWithPath: "/nonexistent"),
            gateway: StubKeychainGateway(read: {
                started.signal()
                Thread.sleep(forTimeInterval: 0.5)
                return nil
            })
        )

        let task = Task { try? await reader.read() }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)

        // If the read were still inline on the main actor, this would not run
        // until the probe returned.
        let mainRan = await MainActor.run { true }
        XCTAssertTrue(mainRan)
        _ = await task.value
    }

    /// The probe must block LONGER than the injected timeout, and a second read
    /// must be attempted while it is still parked. A probe shorter than the
    /// timeout never enters the timeout path, so it would pass against a guard
    /// that clears on caller completion — i.e. against a guard that does not
    /// actually bound anything.
    func test_hungProbeIsNotRetriedWhileStillParked() async throws {
        let probeCount = NSLock()
        var probes = 0
        let reader = CachedCLICredentialReader(
            reader: CLICredentialReader(
                credentialsFile: URL(fileURLWithPath: "/nonexistent"),
                gateway: StubKeychainGateway(read: {
                    probeCount.lock(); probes += 1; probeCount.unlock()
                    Thread.sleep(forTimeInterval: 2.0)   // longer than the timeout below
                    return nil
                })
            ),
            timeout: 0.2
        )

        _ = try? await reader.readFresh()   // times out at 0.2 s, probe still parked
        _ = try? await reader.readFresh()   // must piggyback, not start a second probe
        _ = try? await reader.readFresh()

        probeCount.lock(); let count = probes; probeCount.unlock()
        XCTAssertEqual(count, 1, "an unanswered dialog must never park more than one thread")
    }

    /// A piggybacked result must populate the cache like any other.
    ///
    /// The discriminating case is a stuck-then-recovered Keychain: the first
    /// caller gives up at its deadline and caches `.failure(timeout)`, and the
    /// probe answers a moment later while a second caller is piggybacked on it.
    /// If the piggyback path returns without writing, that stale timeout stays
    /// cached for the whole TTL — so every `read()` in that window fails even
    /// though a perfectly good credential was just obtained, and the read after
    /// the TTL opens a fresh cross-app probe. Reachable in production: the
    /// auto-detect coordinator's credential import and a `freshen` tick share
    /// one instance and can now overlap, since the import became asynchronous.
    ///
    /// A naive version of this test (both callers succeed) proves nothing — the
    /// *primary* caller writes the cache on its way out, so the assertion passes
    /// whether or not the piggyback path writes anything.
    func test_piggybackedSuccessPopulatesTheCache() async throws {
        let gated = GatedCredentialReader(access: "shared")
        let reader = CachedCLICredentialReader(reader: gated, ttl: 60, timeout: 1.0)

        // First caller: parked on the gate, gives up at its 1 s deadline and
        // caches the failure.
        do {
            _ = try await reader.readFresh()
            XCTFail("expected the first caller to time out against an unreleased gate")
        } catch is CLICredentialTimeout {
            // expected
        }

        // Second caller arrives while the read is still parked, so it piggybacks
        // rather than probing again. Releasing the gate right after lets it
        // answer with roughly a second of slack before its own deadline.
        // An unstructured task, not `async let`: this models an independent
        // subsystem calling in, and it keeps the piggybacked read out of the
        // test task's own cancellation scope.
        let piggyback = Task { try await reader.readFresh() }
        try await Task.sleep(nanoseconds: 50_000_000)
        gated.release()

        let result = try await piggyback.value
        XCTAssertEqual(accessToken(result.credential), "shared")
        XCTAssertEqual(gated.calls, 1, "the second caller must piggyback, not start a second read")

        // The piggybacked success must have replaced the cached timeout.
        // Caught rather than propagated so a regression reports itself here
        // instead of surfacing as an anonymous throw out of the test body.
        do {
            let cached = try await reader.read()
            XCTAssertEqual(accessToken(cached.credential), "shared",
                           "a piggybacked success must populate the cache")
        } catch {
            XCTFail("cache still holds the pre-piggyback outcome: \(error)")
        }
        XCTAssertEqual(gated.calls, 1, "the cached read must not touch the Keychain again")
    }

    /// `TimeoutGate` is what stops the losing racer from resuming an already
    /// resumed `CheckedContinuation`. A double resume traps the whole process,
    /// and it would trap whenever the abandoned read finally answers — possibly
    /// hours later, inside some unrelated test, with nothing pointing back here.
    /// Assert the one-shot directly rather than leaving it to incidental cleanup.
    func test_timeoutGate_dropsEverySettleAfterTheFirst() async {
        do {
            _ = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
                let gate = TimeoutGate(c)
                gate.settle(.failure(CLICredentialTimeout()))   // deadline wins
                gate.settle(.success(42))                       // late read: must be dropped
                gate.settle(.failure(CLICredentialTimeout()))   // and again
            }
            XCTFail("expected the first settle to win")
        } catch is CLICredentialTimeout {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_timeoutGate_deliversTheFirstResultWhenWorkWins() async throws {
        let value = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
            let gate = TimeoutGate(c)
            gate.settle(.success(7))
            gate.settle(.failure(CLICredentialTimeout()))   // deadline lost: must be dropped
        }
        XCTAssertEqual(value, 7)
    }

    /// The same hazard end-to-end through the real path, and deliberately
    /// outliving its own deadline: the read is still parked when the timeout
    /// resolves the caller, and the test stays alive past the moment the
    /// abandoned racer answers, so a double resume would trap *here* rather
    /// than somewhere unattributable.
    func test_lateAnsweringProbeDoesNotResumeTheContinuationTwice() async throws {
        let reader = CachedCLICredentialReader(
            reader: CLICredentialReader(
                credentialsFile: URL(fileURLWithPath: "/nonexistent"),
                gateway: StubKeychainGateway(read: {
                    Thread.sleep(forTimeInterval: 0.4)
                    return nil
                })
            ),
            timeout: 0.1
        )

        do {
            _ = try await reader.readFresh()
            XCTFail("expected the deadline to win over a 0.4 s probe")
        } catch is CLICredentialTimeout {
            // expected
        }

        // Outlive the loser: it settles roughly 0.3 s from here.
        try await Task.sleep(nanoseconds: 900_000_000)
    }

    /// `XCTAssertThrowsError` has no async overload, so the async read paths
    /// need this to keep asserting "this must throw" at the call site.
    private func assertThrows(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ work: () async throws -> Void
    ) async {
        do {
            try await work()
            XCTFail("expected an error", file: file, line: line)
        } catch {
            // expected
        }
    }

    private func syncResult(access: String) -> CLICredentialReader.SyncResult {
        CLICredentialReader.SyncResult(
            credential: .cliToken(
                accessToken: access,
                refreshToken: "refresh",
                expiresAt: Date(timeIntervalSince1970: 1_900_000_000)
            ),
            subscriptionPlan: nil
        )
    }

    private func accessToken(_ credential: Credential) -> String? {
        guard case .cliToken(let access, _, _) = credential else { return nil }
        return access
    }

    func test_readDoesNotPromptOnBackgroundPaths() async throws {
        let recorded = InteractionRecorder()
        let reader = CLICredentialReader(
            credentialsFile: URL(fileURLWithPath: "/nonexistent/.credentials.json"),
            gateway: recorded
        )
        _ = try? await reader.read()
        XCTAssertEqual(recorded.lastInteraction, .deny)
    }

    private final class InteractionRecorder: KeychainGateways, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: KeychainInteraction?
        var lastInteraction: KeychainInteraction? {
            lock.lock(); defer { lock.unlock() }; return storage
        }
        func read(service: String, account: String?, interaction: KeychainInteraction) async throws -> Data? {
            lock.lock(); storage = interaction; lock.unlock()
            return nil
        }
        func write(_ data: Data, service: String, account: String) async throws {}
        func delete(service: String, account: String) async throws {}
        func deleteAll(service: String) async throws {}
    }
}

/// A reader that parks off the main thread until the test releases it, so the
/// "read is still outstanding" window can be entered and left deliberately
/// instead of being approximated with sleeps. Parking goes through `OffMain.run`
/// for the same reason the real reader does: blocking on the main thread would
/// wedge the whole test host.
private final class GatedCredentialReader: CLICredentialReading {
    private let gate = DispatchSemaphore(value: 0)
    private let result: CLICredentialReader.SyncResult
    private let counter = NSLock()
    private nonisolated(unsafe) var callCount = 0

    var calls: Int {
        counter.lock(); defer { counter.unlock() }
        return callCount
    }

    init(access: String) {
        result = CLICredentialReader.SyncResult(
            credential: .cliToken(
                accessToken: access,
                refreshToken: "refresh",
                expiresAt: Date(timeIntervalSince1970: 1_900_000_000)
            ),
            subscriptionPlan: nil
        )
    }

    func read() async throws -> CLICredentialReader.SyncResult {
        counter.lock(); callCount += 1; counter.unlock()
        let gate = gate
        await OffMain.run { gate.wait() }
        return result
    }

    func release() { gate.signal() }
}

private final class CountingCredentialReader: CLICredentialReading {
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
