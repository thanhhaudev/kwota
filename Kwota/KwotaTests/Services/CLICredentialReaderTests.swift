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
            keychainProbe: { nil }
        )
        XCTAssertFalse(reader.isAvailable)
    }

    func testIsAvailableTrueWhenFileExists() throws {
        let url = temp.file("creds.json")
        try Data("{}".utf8).write(to: url)
        let reader = CLICredentialReader(credentialsFile: url, keychainProbe: { nil })
        XCTAssertTrue(reader.isAvailable)
    }

    func testIsAvailableFalseWhenOnlyKeychainHasPayload() {
        // isAvailable is file-only — a Keychain payload alone does not count.
        let reader = CLICredentialReader(
            credentialsFile: temp.file("missing.json"),
            keychainProbe: { Data("{}".utf8) }
        )
        XCTAssertFalse(reader.isAvailable)
    }

    func test_isAvailable_doesNotProbeKeychain() {
        var probed = false
        let reader = CLICredentialReader(
            credentialsFile: URL(fileURLWithPath: "/nonexistent/.credentials.json"),
            keychainProbe: { probed = true; return Data("x".utf8) }
        )
        _ = reader.isAvailable
        XCTAssertFalse(probed, "isAvailable must not read the Keychain")
        XCTAssertFalse(reader.isAvailable, "no file present → not available")
    }

    func testReadFromFileReturnsCLIToken() async throws {
        let url = temp.file("creds.json")
        let json = #"""
        {"accessToken":"a-token","refreshToken":"r-token","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        try Data(json.utf8).write(to: url)
        let reader = CLICredentialReader(credentialsFile: url, keychainProbe: { nil })
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
            keychainProbe: { Data(kcJSON.utf8) }
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
            keychainProbe: { Data(kcJSON.utf8) }
        )
        let result = try await reader.read()
        guard case .cliToken(let access, _, _) = result.credential else { return XCTFail("expected cliToken") }
        XCTAssertEqual(access, "flat")
    }

    func testReadThrowsWhenFileMalformedAndKeychainEmpty() async throws {
        let url = temp.file("creds.json")
        try Data("not json".utf8).write(to: url)
        let reader = CLICredentialReader(credentialsFile: url, keychainProbe: { nil })
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
            keychainProbe: {
                started.signal()
                Thread.sleep(forTimeInterval: 0.5)
                return nil
            }
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
                keychainProbe: {
                    probeCount.lock(); probes += 1; probeCount.unlock()
                    Thread.sleep(forTimeInterval: 2.0)   // longer than the timeout below
                    return nil
                }
            ),
            timeout: 0.2
        )

        _ = try? await reader.readFresh()   // times out at 0.2 s, probe still parked
        _ = try? await reader.readFresh()   // must piggyback, not start a second probe
        _ = try? await reader.readFresh()

        probeCount.lock(); let count = probes; probeCount.unlock()
        XCTAssertEqual(count, 1, "an unanswered dialog must never park more than one thread")
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
