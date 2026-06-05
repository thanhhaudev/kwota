//
//  AutoDetectFlowIntegrationTests.swift
//  KwotaTests

import XCTest
@testable import Kwota

@MainActor
final class AutoDetectFlowIntegrationTests: XCTestCase {

    /// Regression test for the chart-contamination bug:
    /// switching CLI identities A → B must NOT cause B's snapshot to be
    /// appended to A's history. The combination of (a) per-profile
    /// UsageHistoryStore, (b) the auto-detect coordinator that swaps the
    /// active profile, and (c) `guardRefresh` denying mismatched refreshes
    /// is what closes the bug; this test exercises all three.
    func test_logoutLogin_separatesChartData() async throws {
        let temp = TempDirectory()
        let dataRoot = temp.url
        let keychain = KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")
        let store = ProfileStore(
            profilesFile: temp.file("profiles.json"),
            keychain: keychain,
            profileDirectoryProvider: { id in dataRoot.appendingPathComponent(id.uuidString) }
        )

        // Mutable identity sources injected into the watcher.
        let lock = NSLock()
        var oauthEmail = "a@x.com"

        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let watcher = CLIAccountWatcher(
            oauthRead: {
                lock.lock(); defer { lock.unlock() }
                return OAuthAccountReader.Account(
                    seatTier: nil,
                    emailAddress: oauthEmail,
                    displayName: nil,
                    organizationName: nil,
                    subscriptionCreatedAt: nil,
                    organizationType: nil,
                    organizationRateLimitTier: nil
                )
            },
            fileEvents: stream,
            keychainPollInterval: 100,
            debounce: 0.05
        )
        let coord = AutoProfileCoordinator(
            watcher: watcher,
            profileStore: store,
            clock: { Date() }
        )
        coord.start()
        watcher.start()

        // Wait for baseline emit to create profile A.
        let baselineExp = expectation(description: "profile A created")
        var baselineObserved = false
        let checkInterval: TimeInterval = 0.05
        let checkTask = Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
                if store.profiles.contains(where: { $0.email == "a@x.com" }) {
                    if !baselineObserved {
                        baselineObserved = true
                        baselineExp.fulfill()
                    }
                    return
                }
            }
        }
        await fulfillment(of: [baselineExp], timeout: 3)
        checkTask.cancel()

        guard let profileA = store.profiles.first(where: { $0.email == "a@x.com" }) else {
            XCTFail("expected profile A to be auto-created from baseline emit")
            watcher.stop()
            return
        }
        XCTAssertEqual(store.activeProfileId, profileA.id)
        XCTAssertEqual(profileA.kind, .auto)
        XCTAssertNotNil(profileA.ownershipBoundary)

        // Helper that mirrors the path layout AppPaths.usageHistoryFile uses,
        // but rooted under dataRoot so the test never touches the real
        // Application Support tree. AppPaths uses profiles/<id>/usage-history.json;
        // the profileDirectoryProvider above maps id → dataRoot/<id>, so the
        // production code would write to dataRoot/<id>/usage-history.json when
        // given the overridden provider. We build the same URL here.
        func historyURL(for id: UUID) -> URL {
            dataRoot
                .appendingPathComponent(id.uuidString)
                .appendingPathComponent("usage-history.json")
        }

        // Append a snapshot for A (writeDebounce: 0 forces immediate flush).
        let storeA = UsageHistoryStore(
            historyFile: historyURL(for: profileA.id),
            writeDebounce: 0
        )
        try storeA.append(UsageHistoryEntry(
            at: Date().addingTimeInterval(-60),
            fiveHour: 0.30,
            sevenDay: nil
        ))

        // Flip CLI identity to B and trigger the watcher's file-event channel.
        lock.lock()
        oauthEmail = "b@x.com"
        lock.unlock()
        continuation.yield(())

        // Wait for profile B to appear and become active.
        let switchExp = expectation(description: "profile B created and active")
        var switchObserved = false
        let switchTask = Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
                if let b = store.profiles.first(where: { $0.email == "b@x.com" }),
                   store.activeProfileId == b.id {
                    if !switchObserved {
                        switchObserved = true
                        switchExp.fulfill()
                    }
                    return
                }
            }
        }
        await fulfillment(of: [switchExp], timeout: 3)
        switchTask.cancel()

        guard let profileB = store.profiles.first(where: { $0.email == "b@x.com" }) else {
            XCTFail("expected profile B to be auto-created on identity switch")
            watcher.stop()
            return
        }
        XCTAssertEqual(store.activeProfileId, profileB.id,
                       "active profile must follow the CLI's current identity")

        // Append a snapshot for B (writeDebounce: 0 forces immediate flush).
        let storeB = UsageHistoryStore(
            historyFile: historyURL(for: profileB.id),
            writeDebounce: 0
        )
        try storeB.append(UsageHistoryEntry(
            at: Date(),
            fiveHour: 0.55,
            sevenDay: nil
        ))

        // Reload both histories from disk fresh and assert separation.
        let aReloaded = try UsageHistoryStore(
            historyFile: historyURL(for: profileA.id),
            writeDebounce: 0
        ).load()
        let bReloaded = try UsageHistoryStore(
            historyFile: historyURL(for: profileB.id),
            writeDebounce: 0
        ).load()

        XCTAssertEqual(aReloaded.count, 1, "A must hold only its own snapshot")
        XCTAssertEqual(bReloaded.count, 1, "B must hold only its own snapshot")
        XCTAssertEqual(aReloaded.first?.fiveHour, 0.30)
        XCTAssertEqual(bReloaded.first?.fiveHour, 0.55)

        // The bug-fix gate must deny A's refresh while CLI is signed into B.
        XCTAssertFalse(coord.guardRefresh(profile: profileA),
                       "stale profile must not refresh under a new CLI identity")
        XCTAssertTrue(coord.guardRefresh(profile: profileB),
                      "live profile must refresh")

        // Tear down.
        watcher.stop()
    }

    /// Boundary semantics: a single global JSONL tail can serve two profiles
    /// IF each profile filters by its ownershipBoundary. Profile A owns
    /// pre-boundary events; profile B owns post-boundary events. Switching
    /// the monitor's ownership profile must reset the session counter and
    /// re-apply the filter so B does not inherit A's running total.
    func test_logoutLogin_jsonlEventsAttributedByBoundary() {
        let temp = TempDirectory()
        let boundary = Date(timeIntervalSince1970: 1_700_000_000)
        let now = boundary.addingTimeInterval(60)

        let reader = FakeJSONLogReader()
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: temp.file("ledger.json"),
            appLaunchInstant: boundary.addingTimeInterval(-120),
            clock: { now },
            legacyDailyQuotaEstimate: 1_000_000
        )

        let preEvent = UsageEvent(
            uuid: "pre",
            sessionId: "s",
            timestamp: boundary.addingTimeInterval(-30),
            tokens: TokenBreakdown(input: 20, output: 0)
        )
        let postEvent = UsageEvent(
            uuid: "post",
            sessionId: "s",
            timestamp: boundary.addingTimeInterval(30),
            tokens: TokenBreakdown(input: 40, output: 0)
        )

        // Profile A's perspective: boundary far in the past — A sees both events.
        monitor.ownership = .init(profileId: UUID(),
                                  boundary: boundary.addingTimeInterval(-120))
        reader.queue = [[preEvent, postEvent]]
        monitor.tick()
        XCTAssertEqual(monitor.sessionTokens, 60,
                       "A's boundary is older than both events → both counted")

        // Switch ownership to profile B at the boundary.
        // Behavior under test:
        //   1. didSet must reset sessionSinceLaunch to .zero on profileId change.
        //   2. Next tick filters events to ts >= boundary.
        // Ledger already has both events from the previous tick. Re-feeding
        // them through the reader exercises the per-tick filter; the ledger
        // dedup prevents double-counting in dailyTokens.
        monitor.ownership = .init(profileId: UUID(), boundary: boundary)
        XCTAssertEqual(monitor.sessionTokens, 0,
                       "ownership profile change must zero the session counter")

        reader.queue = [[preEvent, postEvent]]
        monitor.tick()
        XCTAssertEqual(monitor.sessionTokens, 0,
                       "B sees neither event because both are already in the ledger (dedup) — no new ingest")

        // Drive home that a freshly-arriving post-boundary event lands on B.
        let postEvent2 = UsageEvent(
            uuid: "post-2",
            sessionId: "s",
            timestamp: boundary.addingTimeInterval(45),
            tokens: TokenBreakdown(input: 70, output: 0)
        )
        reader.queue = [[postEvent2]]
        monitor.tick()
        XCTAssertEqual(monitor.sessionTokens, 70,
                       "B sees the new post-boundary event and only that event")
    }
}
