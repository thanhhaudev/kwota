//
//  UsageMonitorTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class UsageMonitorTests: XCTestCase {
    private func event(_ uuid: String, _ ts: String, billable: Int) -> UsageEvent {
        UsageEvent(
            uuid: uuid,
            sessionId: "s",
            timestamp: ISO8601DateFormatter().date(from: ts)!,
            tokens: TokenBreakdown(input: billable, output: 0)
        )
    }
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    func testTickIngestsEventsAndPublishesTotals() {
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        let clock = InMemoryClock(date("2026-04-26T12:00:00Z"))
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: tmp.file("ledger.json"),
            appLaunchInstant: date("2026-04-26T11:00:00Z"),
            clock: clock.dateProvider,
            legacyDailyQuotaEstimate: 1_000
        )
        reader.queue = [[
            event("a", "2026-04-26T11:30:00Z", billable: 100),
            event("b", "2026-04-26T11:31:00Z", billable: 250)
        ]]

        monitor.ownership = .init(profileId: UUID(), boundary: .distantPast)
        monitor.tick()

        XCTAssertEqual(monitor.sessionTokens, 350, "session sums events whose ts >= appLaunchInstant")
        XCTAssertEqual(monitor.dailyTokens, 350)
        XCTAssertEqual(monitor.remainingPercent, 65, "1000 quota - 350 = 65%")
    }

    func test_fileSystemEvent_triggersIngest_withoutWaitingForPoll() async {
        // FSEvents-driven: a write under the watched tree must drive a tick
        // immediately, not wait for the safety poll. Proves start() consumes
        // the injected fileEvents stream.
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        var cont: AsyncStream<Set<URL>>.Continuation!
        let stream = AsyncStream<Set<URL>> { cont = $0 }
        let clock = InMemoryClock(date("2026-04-26T12:00:00Z"))
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: tmp.file("ledger.json"),
            appLaunchInstant: date("2026-04-26T11:00:00Z"),
            clock: clock.dateProvider,
            fileEvents: stream,
            legacyDailyQuotaEstimate: 1_000
        )
        // First batch (empty) is consumed by the immediate tick in start();
        // the second batch lands only when a file event drives the next tick.
        reader.queue = [
            [],
            [event("a", "2026-04-26T11:30:00Z", billable: 100)]
        ]
        monitor.ownership = .init(profileId: UUID(), boundary: .distantPast)

        let ingested = expectation(description: "file event drives ingest")
        monitor.onNewEvents = { _ in ingested.fulfill() }
        monitor.start()
        XCTAssertEqual(monitor.sessionTokens, 0, "immediate start() tick sees only the empty batch")

        cont.yield([])   // simulate an FSEvents notification
        await fulfillment(of: [ingested], timeout: 2)
        XCTAssertEqual(monitor.sessionTokens, 100, "a file event must trigger ingestion on its own")
        monitor.stop()
    }

    func testEventsBeforeAppLaunchCountForDailyButNotSession() {
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        let clock = InMemoryClock(date("2026-04-26T12:00:00Z"))
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: tmp.file("ledger.json"),
            appLaunchInstant: date("2026-04-26T11:00:00Z"),
            clock: clock.dateProvider,
            legacyDailyQuotaEstimate: 1_000_000
        )
        reader.queue = [[
            event("old", "2026-04-26T08:00:00Z", billable: 200),
            event("new", "2026-04-26T11:30:00Z", billable: 50)
        ]]

        monitor.ownership = .init(profileId: UUID(), boundary: .distantPast)
        monitor.tick()

        XCTAssertEqual(monitor.sessionTokens, 50)
        XCTAssertEqual(monitor.dailyTokens, 250)
    }

    func testRemainingPercentClampsAtZero() {
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        let clock = InMemoryClock(date("2026-04-26T12:00:00Z"))
        let monitor = UsageMonitor(
            reader: reader, ledgerURL: tmp.file("ledger.json"),
            appLaunchInstant: date("2026-04-26T11:00:00Z"),
            clock: clock.dateProvider, legacyDailyQuotaEstimate: 100
        )
        reader.queue = [[event("a", "2026-04-26T11:30:00Z", billable: 9_999)]]
        monitor.ownership = .init(profileId: UUID(), boundary: .distantPast)
        monitor.tick()

        XCTAssertEqual(monitor.remainingPercent, 0)
    }

    func testLastTickAtIsNilBeforeFirstTickAndReflectsClockAfterTick() {
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        let clock = InMemoryClock(date("2026-04-26T12:00:00Z"))
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: tmp.file("ledger.json"),
            appLaunchInstant: date("2026-04-26T11:00:00Z"),
            clock: clock.dateProvider,
            legacyDailyQuotaEstimate: 1_000_000
        )

        XCTAssertNil(monitor.lastTickAt, "lastTickAt must be nil before the first tick")

        reader.queue = [[]]
        monitor.tick()

        XCTAssertEqual(monitor.lastTickAt, date("2026-04-26T12:00:00Z"), "lastTickAt must match the clock value at tick time")
    }

    func testLoadLedgerDropsLegacySchemaV1OnDisk() throws {
        // A pre-fix ledger written with local-tz keys must be discarded so it
        // does not silently merge with new UTC keys. After load, dailyTokens
        // starts at 0; the next ingest rebuilds with UTC-anchored buckets.
        let tmp = TempDirectory()
        let url = tmp.file("ledger.json")
        let legacy = """
        {
          "seenUUIDs": ["legacy-uuid"],
          "dailyByDay": {
            "2026-04-25": {
              "input_tokens": 999,
              "output_tokens": 0,
              "cache_creation_input_tokens": 0,
              "cache_read_input_tokens": 0
            }
          },
          "lastUpdate": 768657600.0
        }
        """.data(using: .utf8)!
        try legacy.write(to: url)

        let reader = FakeJSONLogReader()
        let clock = InMemoryClock(date("2026-04-26T12:00:00Z"))
        let monitor = UsageMonitor(
            reader: reader, ledgerURL: url,
            appLaunchInstant: date("2026-04-26T11:00:00Z"),
            clock: clock.dateProvider, legacyDailyQuotaEstimate: 1_000_000
        )

        XCTAssertEqual(monitor.dailyTokens, 0, "v1 ledger must be dropped on load")

        // Re-ingesting an event whose uuid was in the v1 seenUUIDs proves the
        // dedup set was also dropped — re-derived from JSONL on the next tick.
        reader.queue = [[event("legacy-uuid", "2026-04-26T11:30:00Z", billable: 250)]]
        monitor.ownership = .init(profileId: UUID(), boundary: .distantPast)
        monitor.tick()
        XCTAssertEqual(monitor.dailyTokens, 250, "post-drop ingest rebuilds totals from JSONL")
    }

    // MARK: - ownership filter

    func test_ownership_filtersEventsBeforeBoundary() {
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        let clock = InMemoryClock(date("2026-04-26T12:00:00Z"))
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: tmp.file("ledger.json"),
            appLaunchInstant: date("2026-04-26T10:00:00Z"),
            clock: clock.dateProvider,
            legacyDailyQuotaEstimate: 1_000_000
        )
        let boundary = date("2026-04-26T11:00:00Z")
        monitor.ownership = .init(profileId: UUID(), boundary: boundary)
        reader.queue = [[
            event("pre",  "2026-04-26T10:30:00Z", billable: 100),
            event("post", "2026-04-26T11:30:00Z", billable: 250)
        ]]
        monitor.tick()
        XCTAssertEqual(monitor.lastEvents.map(\.uuid), ["post"],
                       "pre-boundary event dropped before ingest")
        XCTAssertEqual(monitor.sessionTokens, 250)
    }

    func test_ownership_nil_skipsAllEvents() {
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        let clock = InMemoryClock(date("2026-04-26T12:00:00Z"))
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: tmp.file("ledger.json"),
            appLaunchInstant: date("2026-04-26T11:00:00Z"),
            clock: clock.dateProvider,
            legacyDailyQuotaEstimate: 1_000_000
        )
        // ownership remains nil
        reader.queue = [[event("a", "2026-04-26T11:30:00Z", billable: 100)]]
        monitor.tick()
        XCTAssertTrue(monitor.lastEvents.isEmpty)
        XCTAssertEqual(monitor.sessionTokens, 0)
        XCTAssertEqual(monitor.dailyTokens, 0)
    }

    func test_ownershipChange_resetsSessionCounter() {
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        let clock = InMemoryClock(date("2026-04-26T12:00:00Z"))
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: tmp.file("ledger.json"),
            appLaunchInstant: date("2026-04-26T10:00:00Z"),
            clock: clock.dateProvider,
            legacyDailyQuotaEstimate: 1_000_000
        )
        let profileA = UUID()
        let profileB = UUID()
        monitor.ownership = .init(profileId: profileA, boundary: .distantPast)
        reader.queue = [[event("a", "2026-04-26T11:30:00Z", billable: 100)]]
        monitor.tick()
        XCTAssertEqual(monitor.sessionTokens, 100)
        monitor.ownership = .init(profileId: profileB, boundary: .distantPast)
        XCTAssertEqual(monitor.sessionTokens, 0,
                       "switching ownership profile zeroes the session counter")
    }

    // MARK: - dailyTokens scoped to ownership

    func test_dailyTokens_reflectsPostBoundaryEventsImmediately_intraDay() {
        // Boundary lands mid-day; a single post-boundary event must show up
        // in dailyTokens on the next tick, not wait for UTC midnight.
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        let clock = InMemoryClock(date("2026-04-26T15:00:00Z"))
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: tmp.file("ledger.json"),
            appLaunchInstant: date("2026-04-26T14:00:00Z"),
            clock: clock.dateProvider,
            legacyDailyQuotaEstimate: 1_000_000
        )
        monitor.ownership = .init(
            profileId: UUID(),
            boundary: date("2026-04-26T14:30:00Z")  // intra-day boundary
        )
        reader.queue = [[event("a", "2026-04-26T14:45:00Z", billable: 100)]]
        monitor.tick()
        XCTAssertEqual(monitor.dailyTokens, 100,
                       "intra-day boundary must not zero a counter built from scoped events")
    }

    func test_dailyTokens_resetsOnOwnershipProfileChange() {
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        let clock = InMemoryClock(date("2026-04-26T15:00:00Z"))
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: tmp.file("ledger.json"),
            appLaunchInstant: date("2026-04-26T14:00:00Z"),
            clock: clock.dateProvider,
            legacyDailyQuotaEstimate: 1_000_000
        )
        let profileA = UUID()
        let profileB = UUID()
        monitor.ownership = .init(profileId: profileA, boundary: .distantPast)
        reader.queue = [[event("a", "2026-04-26T14:45:00Z", billable: 100)]]
        monitor.tick()
        XCTAssertEqual(monitor.dailyTokens, 100)

        monitor.ownership = .init(profileId: profileB, boundary: .distantPast)
        XCTAssertEqual(monitor.dailyTokens, 0,
                       "switching profile must zero the scoped daily counter")
    }

    func test_dailyTokens_resetsAtUTCMidnight() {
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        var nowValue = date("2026-04-26T23:30:00Z")
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: tmp.file("ledger.json"),
            appLaunchInstant: date("2026-04-26T22:00:00Z"),
            clock: { nowValue },
            legacyDailyQuotaEstimate: 1_000_000
        )
        monitor.ownership = .init(profileId: UUID(), boundary: .distantPast)
        reader.queue = [[event("a", "2026-04-26T23:00:00Z", billable: 200)]]
        monitor.tick()
        XCTAssertEqual(monitor.dailyTokens, 200)

        // Advance past UTC midnight.
        nowValue = date("2026-04-27T00:15:00Z")
        reader.queue = [[event("b", "2026-04-27T00:10:00Z", billable: 50)]]
        monitor.tick()
        XCTAssertEqual(monitor.dailyTokens, 50,
                       "counter must reset at UTC midnight and start over for the new day")
    }

    func test_dailyCounter_persistsAcrossMonitorRecreation() {
        let tmp = TempDirectory()
        let ledgerURL = tmp.file("ledger.json")
        let counterURL = tmp.file("daily-counter.json")
        let profileId = UUID()
        let now = date("2026-04-26T14:30:00Z")

        let m1 = UsageMonitor(
            reader: FakeJSONLogReader(),
            ledgerURL: ledgerURL,
            dailyCounterURL: counterURL,
            appLaunchInstant: now.addingTimeInterval(-100),
            clock: { now },
            legacyDailyQuotaEstimate: 1_000_000
        )
        m1.ownership = .init(profileId: profileId, boundary: .distantPast)
        let reader1 = m1.reader as? FakeJSONLogReader
        reader1?.queue = [[event("a", "2026-04-26T14:00:00Z", billable: 250)]]
        m1.tick()
        XCTAssertEqual(m1.dailyTokens, 250)
        m1.flushPersistForTesting()   // force debounced ledger write to disk before recreation

        // Recreate the monitor with the same persistence URLs. New ledger
        // load will dedupe the JSONL event — without persistence the
        // counter would start at 0 (regression). With persistence it
        // restores to 250.
        let reader2 = FakeJSONLogReader()
        let m2 = UsageMonitor(
            reader: reader2,
            ledgerURL: ledgerURL,
            dailyCounterURL: counterURL,
            appLaunchInstant: now.addingTimeInterval(-100),
            clock: { now },
            legacyDailyQuotaEstimate: 1_000_000
        )
        m2.ownership = .init(profileId: profileId, boundary: .distantPast)
        XCTAssertEqual(m2.dailyTokens, 250,
                       "persisted counter must be restored when (profileId, dayKey) matches")
    }

    func test_dailyCounter_resetsWhenPersistedDayKeyStale() {
        let tmp = TempDirectory()
        let ledgerURL = tmp.file("ledger.json")
        let counterURL = tmp.file("daily-counter.json")
        let profileId = UUID()

        // Day 1: accumulate.
        let day1 = date("2026-04-26T14:00:00Z")
        let m1 = UsageMonitor(
            reader: FakeJSONLogReader(),
            ledgerURL: ledgerURL,
            dailyCounterURL: counterURL,
            appLaunchInstant: day1.addingTimeInterval(-100),
            clock: { day1 },
            legacyDailyQuotaEstimate: 1_000_000
        )
        m1.ownership = .init(profileId: profileId, boundary: .distantPast)
        (m1.reader as? FakeJSONLogReader)?.queue = [[event("a", "2026-04-26T13:30:00Z", billable: 100)]]
        m1.tick()
        XCTAssertEqual(m1.dailyTokens, 100)
        m1.flushPersistForTesting()   // force debounced ledger write to disk before recreation

        // Day 2: new day, counter must reset even though persistence had day 1's value.
        let day2 = date("2026-04-27T01:00:00Z")
        let m2 = UsageMonitor(
            reader: FakeJSONLogReader(),
            ledgerURL: ledgerURL,
            dailyCounterURL: counterURL,
            appLaunchInstant: day1,
            clock: { day2 },
            legacyDailyQuotaEstimate: 1_000_000
        )
        m2.ownership = .init(profileId: profileId, boundary: .distantPast)
        XCTAssertEqual(m2.dailyTokens, 0,
                       "stale day key must reset the counter")
    }

    func test_dailyCounter_resetsWhenPersistedProfileIdMismatch() {
        let tmp = TempDirectory()
        let ledgerURL = tmp.file("ledger.json")
        let counterURL = tmp.file("daily-counter.json")
        let now = date("2026-04-26T14:30:00Z")

        let profileA = UUID()
        let m1 = UsageMonitor(
            reader: FakeJSONLogReader(),
            ledgerURL: ledgerURL,
            dailyCounterURL: counterURL,
            appLaunchInstant: now.addingTimeInterval(-100),
            clock: { now },
            legacyDailyQuotaEstimate: 1_000_000
        )
        m1.ownership = .init(profileId: profileA, boundary: .distantPast)
        (m1.reader as? FakeJSONLogReader)?.queue = [[event("a", "2026-04-26T14:00:00Z", billable: 100)]]
        m1.tick()
        XCTAssertEqual(m1.dailyTokens, 100)
        m1.flushPersistForTesting()   // force debounced ledger write to disk before recreation

        let profileB = UUID()
        let m2 = UsageMonitor(
            reader: FakeJSONLogReader(),
            ledgerURL: ledgerURL,
            dailyCounterURL: counterURL,
            appLaunchInstant: now.addingTimeInterval(-100),
            clock: { now },
            legacyDailyQuotaEstimate: 1_000_000
        )
        m2.ownership = .init(profileId: profileB, boundary: .distantPast)
        XCTAssertEqual(m2.dailyTokens, 0,
                       "profile id mismatch must reset the counter")
    }

    func test_dailyCounter_discardsPersistedState_whenLedgerLastUpdateMismatch() {
        // Simulates a corrupted/empty ledger after restart while the counter
        // file is still valid. Without the lastUpdate check, the counter would
        // be restored and the about-to-be-replayed JSONL events would
        // double-count into it.
        let tmp = TempDirectory()
        let ledgerURL = tmp.file("ledger.json")
        let counterURL = tmp.file("daily-counter.json")
        let profileId = UUID()
        let now = date("2026-04-26T14:30:00Z")

        // Run 1: accumulate, both files persisted with matching lastUpdate.
        let m1 = UsageMonitor(
            reader: FakeJSONLogReader(),
            ledgerURL: ledgerURL,
            dailyCounterURL: counterURL,
            appLaunchInstant: now.addingTimeInterval(-100),
            clock: { now },
            legacyDailyQuotaEstimate: 1_000_000
        )
        m1.ownership = .init(profileId: profileId, boundary: .distantPast)
        (m1.reader as? FakeJSONLogReader)?.queue = [[event("a", "2026-04-26T14:00:00Z", billable: 250)]]
        m1.tick()
        XCTAssertEqual(m1.dailyTokens, 250)
        m1.flushPersistForTesting()   // force debounced ledger write to disk before simulating ledger loss

        // Simulate ledger loss/corruption by deleting it. Counter file persists.
        try? FileManager.default.removeItem(at: ledgerURL)

        let m2 = UsageMonitor(
            reader: FakeJSONLogReader(),
            ledgerURL: ledgerURL,
            dailyCounterURL: counterURL,
            appLaunchInstant: now.addingTimeInterval(-100),
            clock: { now },
            legacyDailyQuotaEstimate: 1_000_000
        )
        m2.ownership = .init(profileId: profileId, boundary: .distantPast)
        XCTAssertEqual(m2.dailyTokens, 0,
                       "ledger lost → persisted counter must be discarded to avoid double-count after replay")

        // After replay, both ledger and counter resync.
        (m2.reader as? FakeJSONLogReader)?.queue = [[event("a", "2026-04-26T14:00:00Z", billable: 250)]]
        m2.tick()
        XCTAssertEqual(m2.dailyTokens, 250,
                       "JSONL replay populates the fresh ledger and rebuilds the counter consistently")
    }

    func test_dailyCounter_decodesOldFormatAsStale() throws {
        // An old-format counter file (without ledgerLastUpdate) must decode with
        // ledgerLastUpdate = .distantPast. When the live ledger has a real
        // lastUpdate (i.e., it contains events), the mismatch causes the counter
        // to be discarded — protecting against double-count on upgrade.
        let tmp = TempDirectory()
        let profileId = UUID()
        let now = date("2026-04-26T14:30:00Z")
        let dayKey = "2026-04-26"

        // Populate a ledger file with one real event so it has a non-distantPast lastUpdate.
        let ledgerURL = tmp.file("ledger.json")
        let m0 = UsageMonitor(
            reader: FakeJSONLogReader(),
            ledgerURL: ledgerURL,
            dailyCounterURL: tmp.file("throwaway-counter.json"),
            appLaunchInstant: now.addingTimeInterval(-100),
            clock: { now },
            legacyDailyQuotaEstimate: 1_000_000
        )
        m0.ownership = .init(profileId: profileId, boundary: .distantPast)
        (m0.reader as? FakeJSONLogReader)?.queue = [[event("z", "2026-04-26T14:00:00Z", billable: 50)]]
        m0.tick()
        m0.flushPersistForTesting()   // force debounced ledger write to disk before recreation
        // ledger now has lastUpdate = now (a real date, not distantPast)

        // Write a counter file in the old format (no ledgerLastUpdate field).
        let oldFormatJSON = """
        {
          "profileId": "\(profileId.uuidString)",
          "dayKey": "\(dayKey)",
          "count": 999
        }
        """.data(using: .utf8)!
        let counterURL = tmp.file("daily-counter.json")
        try oldFormatJSON.write(to: counterURL)

        let m = UsageMonitor(
            reader: FakeJSONLogReader(),
            ledgerURL: ledgerURL,
            dailyCounterURL: counterURL,
            appLaunchInstant: now.addingTimeInterval(-100),
            clock: { now },
            legacyDailyQuotaEstimate: 1_000_000
        )
        m.ownership = .init(profileId: profileId, boundary: .distantPast)
        // Old counter decoded with ledgerLastUpdate = .distantPast.
        // Live ledger has lastUpdate = now (a real date) → mismatch → counter reset.
        XCTAssertEqual(m.dailyTokens, 0,
                       "old-format counter (ledgerLastUpdate defaults to distantPast) must be discarded when live ledger has a real lastUpdate")
    }

    func testPersistLedger_doesNotWriteSynchronouslyInsideIngest() {
        // The on-disk file must NOT exist immediately after tick() returns
        // when a debounce window is configured. Proves persist hopped off
        // the calling actor and onto the persist queue.
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        let clock = InMemoryClock(date("2026-04-26T12:00:00Z"))
        let ledgerURL = tmp.file("ledger.json")
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: ledgerURL,
            appLaunchInstant: date("2026-04-26T11:00:00Z"),
            clock: clock.dateProvider,
            legacyDailyQuotaEstimate: 1_000,
            persistDebounce: 10.0      // long enough that the write cannot land synchronously
        )
        reader.queue = [[event("a", "2026-04-26T11:30:00Z", billable: 100)]]
        monitor.ownership = .init(profileId: UUID(), boundary: .distantPast)
        monitor.tick()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ledgerURL.path),
            "tick() must not produce a synchronous on-disk write"
        )
    }

    func testPersistLedger_coalescesBurstsIntoOneWrite() {
        // Three back-to-back ticks under a debounce window must produce
        // exactly one on-disk write after flush.
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        let clock = InMemoryClock(date("2026-04-26T12:00:00Z"))
        let ledgerURL = tmp.file("ledger.json")
        var writeCount = 0
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: ledgerURL,
            appLaunchInstant: date("2026-04-26T11:00:00Z"),
            clock: clock.dateProvider,
            legacyDailyQuotaEstimate: 1_000,
            persistDebounce: 10.0,
            persistDidWriteForTesting: { writeCount += 1 }
        )
        reader.queue = [
            [event("a", "2026-04-26T11:30:00Z", billable: 100)],
            [event("b", "2026-04-26T11:31:00Z", billable: 100)],
            [event("c", "2026-04-26T11:32:00Z", billable: 100)]
        ]
        monitor.ownership = .init(profileId: UUID(), boundary: .distantPast)
        monitor.tick()
        monitor.tick()
        monitor.tick()

        monitor.flushPersistForTesting()
        XCTAssertEqual(writeCount, 1, "three ticks within the debounce window must produce one write")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledgerURL.path))
    }

    func testFlushPersistForTesting_writesPendingState() {
        // flush executes the deferred write immediately and returns only
        // after the file is on disk.
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        let clock = InMemoryClock(date("2026-04-26T12:00:00Z"))
        let ledgerURL = tmp.file("ledger.json")
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: ledgerURL,
            appLaunchInstant: date("2026-04-26T11:00:00Z"),
            clock: clock.dateProvider,
            legacyDailyQuotaEstimate: 1_000,
            persistDebounce: 10.0
        )
        reader.queue = [[event("a", "2026-04-26T11:30:00Z", billable: 100)]]
        monitor.ownership = .init(profileId: UUID(), boundary: .distantPast)
        monitor.tick()
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path))

        monitor.flushPersistForTesting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledgerURL.path))
    }

    func testPersistDailyCounter_alsoDebouncesAndWritesOffMain() {
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        let clock = InMemoryClock(date("2026-04-26T12:00:00Z"))
        let counterURL = tmp.file("daily.json")
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: tmp.file("ledger.json"),
            dailyCounterURL: counterURL,
            appLaunchInstant: date("2026-04-26T11:00:00Z"),
            clock: clock.dateProvider,
            legacyDailyQuotaEstimate: 1_000,
            persistDebounce: 10.0
        )
        reader.queue = [[event("a", "2026-04-26T11:30:00Z", billable: 100)]]
        monitor.ownership = .init(profileId: UUID(), boundary: .distantPast)
        monitor.tick()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: counterURL.path),
            "tick() must not write the counter synchronously"
        )
        monitor.flushPersistForTesting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: counterURL.path))
    }

    func testStop_flushesPendingPersist() {
        // Pending debounced writes must land on disk by the time stop()
        // returns. Otherwise an app quit during the debounce window would
        // lose recent state.
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        let clock = InMemoryClock(date("2026-04-26T12:00:00Z"))
        let ledgerURL = tmp.file("ledger.json")
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: ledgerURL,
            appLaunchInstant: date("2026-04-26T11:00:00Z"),
            clock: clock.dateProvider,
            legacyDailyQuotaEstimate: 1_000,
            persistDebounce: 60.0    // far longer than the test
        )
        reader.queue = [[event("a", "2026-04-26T11:30:00Z", billable: 100)]]
        monitor.ownership = .init(profileId: UUID(), boundary: .distantPast)
        monitor.tick()
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path))

        monitor.stop()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ledgerURL.path),
            "stop() must flush pending debounced writes"
        )
    }

    func testRestart_restoresReaderOffsets_noDoubleEmit() {
        // After a fake restart, the new monitor must call reader.restore() with
        // the offsets the prior monitor persisted. Proves reader.state() is
        // captured into the envelope and reader.restore() is wired on init.
        let tmp = TempDirectory()
        let ledgerURL = tmp.file("ledger.json")
        let counterURL = tmp.file("daily.json")

        let reader1 = FakeJSONLogReader()
        let monitor1 = UsageMonitor(
            reader: reader1,
            ledgerURL: ledgerURL,
            dailyCounterURL: counterURL,
            appLaunchInstant: date("2026-04-26T11:00:00Z"),
            clock: InMemoryClock(date("2026-04-26T12:00:00Z")).dateProvider,
            legacyDailyQuotaEstimate: 1_000_000,
            persistDebounce: 10.0
        )
        reader1.queue = [[event("a", "2026-04-26T11:30:00Z", billable: 100)]]
        // Pretend the reader advanced its offset by 42 bytes after emitting "a".
        reader1.stateOverride = ReaderState(entries: [
            "/tmp/fake.jsonl": .init(offset: 42, mtime: date("2026-04-26T11:30:00Z"))
        ])
        monitor1.ownership = .init(profileId: UUID(), boundary: .distantPast)
        monitor1.tick()
        monitor1.flushPersistForTesting()

        // Second monitor with a fresh reader. The persisted envelope must
        // have included the offset; the new reader must receive it via
        // restore() before any read.
        let reader2 = FakeJSONLogReader()
        _ = UsageMonitor(
            reader: reader2,
            ledgerURL: ledgerURL,
            dailyCounterURL: counterURL,
            appLaunchInstant: date("2026-04-26T13:00:00Z"),
            clock: InMemoryClock(date("2026-04-26T13:00:00Z")).dateProvider,
            legacyDailyQuotaEstimate: 1_000_000
        )
        XCTAssertEqual(
            reader2.restoredState?.entries["/tmp/fake.jsonl"]?.offset,
            42,
            "UsageMonitor must call reader.restore() with the persisted state on init"
        )
    }

    func testLegacyV2Ledger_migratesAndDropsSeenUUIDs() throws {
        let tmp = TempDirectory()
        let ledgerURL = tmp.file("ledger.json")
        // Write a legacy v2 file (no envelope, top-level UsageLedger shape).
        // Field names match the existing legacy test fixture (snake_case keys
        // per TokenBreakdown.CodingKeys).
        let legacyJSON = """
        {
          "schemaVersion": 2,
          "seenUUIDs": ["legacy-uuid"],
          "dailyByDay": {
            "2026-04-25": {
              "input_tokens": 5,
              "output_tokens": 5,
              "cache_creation_input_tokens": 0,
              "cache_read_input_tokens": 0
            }
          },
          "lastUpdate": 770000000.0
        }
        """
        try legacyJSON.write(to: ledgerURL, atomically: true, encoding: .utf8)

        let reader = FakeJSONLogReader()
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: ledgerURL,
            appLaunchInstant: date("2026-04-26T11:00:00Z"),
            clock: InMemoryClock(date("2026-04-26T12:00:00Z")).dateProvider,
            legacyDailyQuotaEstimate: 1_000_000
        )

        // (a) reader.restore is called even on legacy migration → contract holds.
        XCTAssertNotNil(reader.restoredState, "UsageMonitor must always call reader.restore() on init, even on legacy migration")
        XCTAssertEqual(reader.restoredState?.entries.count, 0)

        // (b) Persisted seenUUIDs was dropped: feeding the same uuid the
        // legacy file recorded must fire onNewEvents (treated as new).
        var newCount = 0
        monitor.onNewEvents = { events in newCount += events.count }
        reader.queue = [[event("legacy-uuid", "2026-04-25T12:00:00Z", billable: 10)]]
        monitor.ownership = .init(profileId: UUID(), boundary: .distantPast)
        monitor.tick()
        XCTAssertEqual(newCount, 1, "legacy seenUUIDs must be dropped on migration")
    }

    func testLegacyV2Migration_doesNotDoubleCountDailyByDay() throws {
        // Regression: pre-fix, loadEnvelope kept the legacy dailyByDay totals
        // AND the post-restart full-tree re-walk re-emitted every event with
        // empty in-memory seenUUIDs, doubling each day's bucket. The fix
        // drops dailyByDay on migration so the re-walk rebuilds cleanly.
        let tmp = TempDirectory()
        let ledgerURL = tmp.file("ledger.json")
        // Legacy v2: pre-existing total for the day the test re-ingests into.
        let legacyJSON = """
        {
          "schemaVersion": 2,
          "seenUUIDs": ["legacy-uuid"],
          "dailyByDay": {
            "2026-04-25": {
              "input_tokens": 10,
              "output_tokens": 0,
              "cache_creation_input_tokens": 0,
              "cache_read_input_tokens": 0
            }
          },
          "lastUpdate": 770000000.0
        }
        """
        try legacyJSON.write(to: ledgerURL, atomically: true, encoding: .utf8)

        let reader = FakeJSONLogReader()
        // Hold InMemoryClock in a local — `.dateProvider` only retains it
        // weakly, so an inline `InMemoryClock(...).dateProvider` falls back to
        // wall-clock `Date()` and `ledger.prune` would silently delete the
        // 2026-04-25 bucket (today minus 7 days ≫ 2026-04-25).
        let clock = InMemoryClock(date("2026-04-26T12:00:00Z"))
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: ledgerURL,
            appLaunchInstant: date("2026-04-26T11:00:00Z"),
            clock: clock.dateProvider,
            legacyDailyQuotaEstimate: 1_000_000,
            persistDebounce: 0.0
        )
        // Replay the same event the legacy bucket was built from.
        reader.queue = [[event("legacy-uuid", "2026-04-25T12:00:00Z", billable: 10)]]
        monitor.ownership = .init(profileId: UUID(), boundary: .distantPast)
        monitor.tick()
        monitor.flushPersistForTesting()

        // After the fix: legacy dailyByDay is dropped on migration, so the
        // re-walked event lands once → bucket is 10, not 20.
        // Inspect via the persisted envelope on disk, since UsageMonitor does
        // not expose ledger.dailyByDay directly to callers.
        struct EnvelopeProbe: Decodable {
            struct LedgerProbe: Decodable {
                let dailyByDay: [String: TokenBreakdown]
            }
            let ledger: LedgerProbe
        }
        let data = try Data(contentsOf: ledgerURL)
        let probe = try JSONDecoder().decode(EnvelopeProbe.self, from: data)
        XCTAssertEqual(
            probe.ledger.dailyByDay["2026-04-25"]?.billable,
            10,
            "legacy v2 migration must not double-count dailyByDay"
        )
    }

    // MARK: - FSEvents path-aware (Phase 3)

    func testFileSystemEvent_withPaths_invokesIncrementalRead() async {
        // Production path: an FSEvents yield carrying a non-empty Set<URL>
        // must reach the reader as a read(only:) call with that exact set.
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        var cont: AsyncStream<Set<URL>>.Continuation!
        let stream = AsyncStream<Set<URL>> { cont = $0 }
        let clock = InMemoryClock(date("2026-04-26T12:00:00Z"))
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: tmp.file("ledger.json"),
            appLaunchInstant: date("2026-04-26T11:00:00Z"),
            clock: clock.dateProvider,
            fileEvents: stream,
            legacyDailyQuotaEstimate: 1_000
        )
        reader.queue = [
            [],   // consumed by the initial startup tick
            [event("a", "2026-04-26T11:30:00Z", billable: 100)]
        ]
        monitor.ownership = .init(profileId: UUID(), boundary: .distantPast)

        let ingested = expectation(description: "incremental tick ingests")
        monitor.onNewEvents = { _ in ingested.fulfill() }
        monitor.start()

        // Wait for the startup tick (full-walk; empty batch) to drain so the
        // path-aware yield below isn't dequeued ahead of the startup tick
        // and assigned the empty batch — leaving the startup full-walk to
        // dequeue the event batch and clobber `lastReadOnlyPaths` to nil.
        var spins = 0
        while monitor.lastTickAt == nil && spins < 200 {
            try? await Task.sleep(nanoseconds: 10_000_000)   // 10 ms
            spins += 1
        }
        XCTAssertNotNil(monitor.lastTickAt, "startup tick must complete before yielding path")

        let touched: Set<URL> = [URL(fileURLWithPath: "/tmp/fake.jsonl")]
        cont.yield(touched)
        await fulfillment(of: [ingested], timeout: 2)

        XCTAssertEqual(reader.lastReadOnlyPaths, touched,
                       "non-empty FSEvents yield must reach reader as read(only:) with the same set")
        monitor.stop()
    }

    func testFileSystemEvent_withEmptySet_triggersFullWalk() async {
        // Empty-set sentinel from the safety-poll backstop must reach the
        // reader as the plain read() — full walk.
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        var cont: AsyncStream<Set<URL>>.Continuation!
        let stream = AsyncStream<Set<URL>> { cont = $0 }
        let clock = InMemoryClock(date("2026-04-26T12:00:00Z"))
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: tmp.file("ledger.json"),
            appLaunchInstant: date("2026-04-26T11:00:00Z"),
            clock: clock.dateProvider,
            fileEvents: stream,
            legacyDailyQuotaEstimate: 1_000
        )
        reader.queue = [
            [],
            [event("a", "2026-04-26T11:30:00Z", billable: 100)]
        ]
        monitor.ownership = .init(profileId: UUID(), boundary: .distantPast)

        let ingested = expectation(description: "full-walk tick ingests")
        monitor.onNewEvents = { _ in ingested.fulfill() }
        monitor.start()

        cont.yield([])   // empty set = full-walk sentinel
        await fulfillment(of: [ingested], timeout: 2)

        XCTAssertNil(reader.lastReadOnlyPaths,
                     "empty-set yield must invoke the full-walk read(), not read(only:)")
        monitor.stop()
    }

    func testSafetyPollDefault_isFiveMinutes() {
        // Default safety-poll cadence rose from 60s to 300s after FSEvents
        // became path-aware. Lock that in so future edits don't silently
        // halve the residual idle-CPU savings.
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: tmp.file("ledger.json")
        )
        XCTAssertEqual(monitor.safetyPollIntervalForTesting, 300)
        _ = monitor
    }

    // MARK: - FSEvents parser (Codex Fix 3)

    func testParseFSEventsBatch_normalBatch_returnsJsonlPaths() {
        let result = UsageMonitor.parseFSEventsBatch(
            numEvents: 3,
            paths: ["/foo/a.jsonl", "/foo/dir", "/foo/b.jsonl"],
            flags: [0, 0, 0]
        )
        XCTAssertEqual(result, [
            URL(fileURLWithPath: "/foo/a.jsonl"),
            URL(fileURLWithPath: "/foo/b.jsonl")
        ])
    }

    func testParseFSEventsBatch_noJsonlPaths_returnsNil() {
        // Directory-only event: no .jsonl in the batch and no overflow.
        // Caller suppresses the yield entirely.
        let result = UsageMonitor.parseFSEventsBatch(
            numEvents: 1,
            paths: ["/foo/dir"],
            flags: [0]
        )
        XCTAssertNil(result, "no .jsonl + no overflow ⇒ caller suppresses yield")
    }

    func testParseFSEventsBatch_userDroppedFlag_returnsFullWalkSentinel() {
        let result = UsageMonitor.parseFSEventsBatch(
            numEvents: 2,
            paths: ["/foo/a.jsonl", "/foo/b.jsonl"],
            flags: [0, FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)]
        )
        XCTAssertEqual(result, [],
                       "UserDropped on any event ⇒ empty-set sentinel (full walk)")
    }

    func testParseFSEventsBatch_kernelDroppedFlag_returnsFullWalkSentinel() {
        let result = UsageMonitor.parseFSEventsBatch(
            numEvents: 1,
            paths: ["/foo/a.jsonl"],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)]
        )
        XCTAssertEqual(result, [], "KernelDropped ⇒ full-walk sentinel")
    }

    func testParseFSEventsBatch_mustScanSubDirsFlag_isNOTTreatedAsOverflow() {
        // MustScanSubDirs is deliberately excluded from the overflow mask
        // (see the doc-comment on parseFSEventsBatch). Apple's docs frame
        // it as data loss, but in practice the kernel fires it whenever
        // events are coalesced hierarchically — under load it can fire
        // every few seconds, and treating each as a full-walk request put
        // the process at >50% CPU. The 5-minute safety-poll catches any
        // truly-missed events.
        let result = UsageMonitor.parseFSEventsBatch(
            numEvents: 1,
            paths: ["/foo/a.jsonl"],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)]
        )
        XCTAssertEqual(result, [URL(fileURLWithPath: "/foo/a.jsonl")],
                       "MustScanSubDirs falls through to normal path processing")
    }

    // MARK: - tickAsync deferred-paths state (Codex Fix 1)

    func testCoalesce_pathThenPath_mergesIntoUnion() {
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        let clock = InMemoryClock(date("2026-04-26T12:00:00Z"))
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: tmp.file("ledger.json"),
            appLaunchInstant: date("2026-04-26T11:00:00Z"),
            clock: clock.dateProvider,
            legacyDailyQuotaEstimate: 1_000_000,
            persistDebounce: 10.0
        )

        monitor.coalesceForTesting([URL(fileURLWithPath: "/a.jsonl")])
        monitor.coalesceForTesting([URL(fileURLWithPath: "/b.jsonl")])

        XCTAssertEqual(monitor.pendingPathsForTesting, [
            URL(fileURLWithPath: "/a.jsonl"),
            URL(fileURLWithPath: "/b.jsonl")
        ], "two re-entrant path calls coalesce into the union")
        XCTAssertFalse(monitor.pendingFullWalkForTesting)
    }

    func testCoalesce_pathThenFullWalk_fullWalkSupersedes() {
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: tmp.file("ledger.json"),
            persistDebounce: 10.0
        )

        monitor.coalesceForTesting([URL(fileURLWithPath: "/a.jsonl")])
        monitor.coalesceForTesting(nil)   // full walk requested

        XCTAssertTrue(monitor.pendingFullWalkForTesting,
                      "full-walk request must override pending path set")
        // The pending paths set may be unchanged or cleared — either is
        // fine because the loop discards them once pendingFullWalk is true.
        // We don't assert on its contents.
    }

    func testCoalesce_fullWalkThenPath_pathSubsumed() {
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: tmp.file("ledger.json"),
            persistDebounce: 10.0
        )

        monitor.coalesceForTesting(nil)
        monitor.coalesceForTesting([URL(fileURLWithPath: "/a.jsonl")])

        XCTAssertTrue(monitor.pendingFullWalkForTesting,
                      "full-walk stays pending after a later path call")
        XCTAssertEqual(monitor.pendingPathsForTesting, [],
                       "path call after a pending full walk is subsumed")
    }

    func testTickAsync_loopConsumesPendingPaths_incrementalNotFullWalk() async {
        // The deferred-paths state primes the loop: first iteration uses
        // the call-site filter; second iteration consumes the deferred
        // path set. No `read()` (full walk) is ever called.
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        let clock = InMemoryClock(date("2026-04-26T12:00:00Z"))
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: tmp.file("ledger.json"),
            appLaunchInstant: date("2026-04-26T11:00:00Z"),
            clock: clock.dateProvider,
            legacyDailyQuotaEstimate: 1_000_000,
            persistDebounce: 10.0
        )
        monitor.ownership = .init(profileId: UUID(), boundary: .distantPast)
        reader.queue = [
            [event("a", "2026-04-26T11:30:00Z", billable: 100)],
            [event("b", "2026-04-26T11:31:00Z", billable: 100)]
        ]
        monitor.setPendingForTesting(
            fullWalk: false,
            paths: [URL(fileURLWithPath: "/b.jsonl")]
        )

        await monitor.tickAsync(only: [URL(fileURLWithPath: "/a.jsonl")])

        XCTAssertEqual(reader.readFullCount, 0,
                       "loop must not escalate to a full walk")
        XCTAssertEqual(reader.readOnlyHistory, [
            [URL(fileURLWithPath: "/a.jsonl")],
            [URL(fileURLWithPath: "/b.jsonl")]
        ], "two incremental reads in order: initial paths, then deferred paths")
        XCTAssertEqual(monitor.pendingPathsForTesting, [],
                       "deferred paths consumed")
        XCTAssertFalse(monitor.pendingFullWalkForTesting)
    }

    func testTickAsync_loopConsumesPendingFullWalk_afterIncremental() async {
        // First iteration: read(only:) with the call-site filter.
        // Deferred state has fullWalk=true, so second iteration is read().
        let tmp = TempDirectory()
        let reader = FakeJSONLogReader()
        let clock = InMemoryClock(date("2026-04-26T12:00:00Z"))
        let monitor = UsageMonitor(
            reader: reader,
            ledgerURL: tmp.file("ledger.json"),
            appLaunchInstant: date("2026-04-26T11:00:00Z"),
            clock: clock.dateProvider,
            legacyDailyQuotaEstimate: 1_000_000,
            persistDebounce: 10.0
        )
        monitor.ownership = .init(profileId: UUID(), boundary: .distantPast)
        reader.queue = [
            [event("a", "2026-04-26T11:30:00Z", billable: 100)],
            []
        ]
        monitor.setPendingForTesting(fullWalk: true, paths: [])

        await monitor.tickAsync(only: [URL(fileURLWithPath: "/a.jsonl")])

        XCTAssertEqual(reader.readFullCount, 1, "second iteration is a full walk")
        XCTAssertEqual(reader.readOnlyHistory.count, 1)
        XCTAssertFalse(monitor.pendingFullWalkForTesting,
                       "deferred full walk consumed")
    }
}
