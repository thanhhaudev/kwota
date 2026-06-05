//
//  CLIAccountWatcherTests.swift
//  KwotaTests

import XCTest
@testable import Kwota

@MainActor
final class CLIAccountWatcherTests: XCTestCase {
    func test_start_emitsBaselineIdentity() async {
        let (events, _) = AsyncStream<Void>.makeStream()
        let exp = expectation(description: "emit")
        var captured: CLIIdentity?
        let watcher = CLIAccountWatcher(
            oauthRead: {
                OAuthAccountReader.Account(seatTier: "pro",
                                           emailAddress: "a@x.com",
                                           displayName: "A",
                                           organizationName: "Org",
                                           subscriptionCreatedAt: nil,
                                           organizationType: nil,
                                           organizationRateLimitTier: nil)
            },
            fileEvents: events,
            keychainPollInterval: 100,
            debounce: 0.05
        )
        watcher.onChange = { captured = $0; exp.fulfill() }
        watcher.start()
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(captured?.email, "a@x.com")
        watcher.stop()
    }

    func test_fileEvent_emitsNewIdentityWhenOauthChanges() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let lock = NSLock()
        var oauthEmail = "a@x.com"
        let exp = expectation(description: "second emit")
        exp.expectedFulfillmentCount = 2
        var captured: [String?] = []
        let watcher = CLIAccountWatcher(
            oauthRead: {
                lock.lock(); defer { lock.unlock() }
                return OAuthAccountReader.Account(seatTier: nil,
                                                  emailAddress: oauthEmail,
                                                  displayName: nil,
                                                  organizationName: nil,
                                                  subscriptionCreatedAt: nil,
                                                  organizationType: nil,
                                                  organizationRateLimitTier: nil)
            },
            fileEvents: stream,
            keychainPollInterval: 100,
            debounce: 0.05
        )
        watcher.onChange = { captured.append($0?.email); exp.fulfill() }
        watcher.start()
        try? await Task.sleep(nanoseconds: 200_000_000)
        lock.lock(); oauthEmail = "b@x.com"; lock.unlock()
        continuation.yield(())
        await fulfillment(of: [exp], timeout: 3)
        XCTAssertEqual(captured, ["a@x.com", "b@x.com"])
        watcher.stop()
    }

    func test_signedOut_emitsNil() async {
        let (stream, _) = AsyncStream<Void>.makeStream()
        let exp = expectation(description: "nil emit")
        var captured: CLIIdentity?
        var emitted = false
        let watcher = CLIAccountWatcher(
            oauthRead: { nil },
            fileEvents: stream,
            keychainPollInterval: 100,
            debounce: 0.05
        )
        watcher.onChange = { identity in
            captured = identity; emitted = true; exp.fulfill()
        }
        watcher.start()
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertTrue(emitted)
        XCTAssertNil(captured)
        watcher.stop()
    }

    func test_unchangedRewrite_doesNotEmit() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        var calls = 0
        let watcher = CLIAccountWatcher(
            oauthRead: {
                OAuthAccountReader.Account(seatTier: nil,
                                           emailAddress: "a@x.com",
                                           displayName: nil,
                                           organizationName: nil,
                                           subscriptionCreatedAt: nil,
                                           organizationType: nil,
                                           organizationRateLimitTier: nil)
            },
            fileEvents: stream,
            keychainPollInterval: 100,
            debounce: 0.05
        )
        watcher.onChange = { _ in calls += 1 }
        watcher.start()
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(calls, 1)
        continuation.yield(())
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(calls, 1, "no change in identity → no new emit")
        watcher.stop()
    }

    func test_identityCarriesSeatTierAndOrgType() async {
        // Verify the new metadata fields from oauthAccount flow into CLIIdentity.
        let (events, _) = AsyncStream<Void>.makeStream()
        let exp = expectation(description: "emit")
        var captured: CLIIdentity?
        let watcher = CLIAccountWatcher(
            oauthRead: {
                OAuthAccountReader.Account(seatTier: nil,
                                           emailAddress: "a@x.com",
                                           displayName: "Hau",
                                           organizationName: "Acme",
                                           subscriptionCreatedAt: nil,
                                           organizationType: "claude_max",
                                           organizationRateLimitTier: "tier2")
            },
            fileEvents: events,
            keychainPollInterval: 100,
            debounce: 0.05
        )
        watcher.onChange = { captured = $0; exp.fulfill() }
        watcher.start()
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertNil(captured?.seatTier)
        XCTAssertEqual(captured?.organizationType, "claude_max")
        XCTAssertEqual(captured?.organizationRateLimitTier, "tier2")
        XCTAssertEqual(captured?.displayName, "Hau")
        watcher.stop()
    }

    func test_fingerprintChanges_onPlanChange_sameAccount() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let lock = NSLock()
        var seat = "pro"
        let exp = expectation(description: "two emits")
        exp.expectedFulfillmentCount = 2
        var fingerprints: [String] = []
        let watcher = CLIAccountWatcher(
            oauthRead: {
                lock.lock(); defer { lock.unlock() }
                return OAuthAccountReader.Account(seatTier: seat,
                                                  emailAddress: "a@x.com",
                                                  displayName: nil,
                                                  organizationName: "Org",
                                                  subscriptionCreatedAt: nil,
                                                  organizationType: nil,
                                                  organizationRateLimitTier: nil,
                                                  accountUuid: "acct-1",
                                                  organizationUuid: "org-1")
            },
            fileEvents: stream,
            keychainPollInterval: 100,
            debounce: 0.05
        )
        watcher.onChange = { id in
            if let f = id?.credentialFingerprint { fingerprints.append(f) }
            exp.fulfill()
        }
        watcher.start()
        try? await Task.sleep(nanoseconds: 200_000_000)
        lock.lock(); seat = "max"; lock.unlock()
        continuation.yield(())
        await fulfillment(of: [exp], timeout: 3)
        XCTAssertEqual(fingerprints.count, 2)
        XCTAssertNotEqual(fingerprints[0], fingerprints[1],
                          "plan change within an account must change the fingerprint")
        watcher.stop()
    }

    func test_fingerprintChanges_onAccountSwitch_sameEmail() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let lock = NSLock()
        var uuid = "acct-1"
        let exp = expectation(description: "two emits")
        exp.expectedFulfillmentCount = 2
        var fingerprints: [String] = []
        let watcher = CLIAccountWatcher(
            oauthRead: {
                lock.lock(); defer { lock.unlock() }
                return OAuthAccountReader.Account(seatTier: "max",
                                                  emailAddress: "a@x.com",
                                                  displayName: nil,
                                                  organizationName: "Org",
                                                  subscriptionCreatedAt: nil,
                                                  organizationType: nil,
                                                  organizationRateLimitTier: nil,
                                                  accountUuid: uuid,
                                                  organizationUuid: "org-1")
            },
            fileEvents: stream,
            keychainPollInterval: 100,
            debounce: 0.05
        )
        watcher.onChange = { id in
            if let f = id?.credentialFingerprint { fingerprints.append(f) }
            exp.fulfill()
        }
        watcher.start()
        try? await Task.sleep(nanoseconds: 200_000_000)
        lock.lock(); uuid = "acct-2"; lock.unlock()
        continuation.yield(())
        await fulfillment(of: [exp], timeout: 3)
        XCTAssertNotEqual(fingerprints.first, fingerprints.last,
                          "different accountUuid (same email) must change the fingerprint")
        watcher.stop()
    }
}
