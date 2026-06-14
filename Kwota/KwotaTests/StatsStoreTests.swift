//
//  StatsStoreTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class StatsStoreTests: XCTestCase {
    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)!
    }

    func test_ingestEvents_bucketsByDayAndModel() {
        let store = StatsStore(reader: FakeJSONLogReader(),
                               ledgerURL: URL(fileURLWithPath: "/dev/null"),
                               clock: { self.date("2026-06-13T10:00:00.000Z") },
                               persistDebounce: 0)
        let events = [
            UsageEvent(uuid: "u1", sessionId: "s", timestamp: date("2026-06-13T01:00:00.000Z"),
                       tokens: TokenBreakdown(input: 100, output: 10, cacheRead: 5), model: "claude-opus-4-8"),
            UsageEvent(uuid: "u2", sessionId: "s", timestamp: date("2026-06-13T02:00:00.000Z"),
                       tokens: TokenBreakdown(input: 20, output: 2), model: "claude-opus-4-8"),
        ]
        store.ingest(events, provider: .claude)
        XCTAssertEqual(store.totalsByModel(provider: .claude, sinceDay: nil)["claude-opus-4-8"],
                       TokenBreakdown(input: 120, output: 12, cacheRead: 5))
    }

    func test_ingestEvents_ignoresZeroAndUsesUnknownForMissingModel() {
        let store = StatsStore(reader: FakeJSONLogReader(),
                               ledgerURL: URL(fileURLWithPath: "/dev/null"),
                               clock: { self.date("2026-06-13T10:00:00.000Z") },
                               persistDebounce: 0)
        store.ingest([
            UsageEvent(uuid: "z", sessionId: "s", timestamp: date("2026-06-13T01:00:00.000Z"), tokens: .zero, model: "x"),
            UsageEvent(uuid: "m", sessionId: "s", timestamp: date("2026-06-13T01:00:00.000Z"),
                       tokens: TokenBreakdown(input: 7), model: nil),
        ], provider: .claude)
        XCTAssertEqual(store.totalsByModel(provider: .claude, sinceDay: nil)["unknown"], TokenBreakdown(input: 7))
        XCTAssertNil(store.totalsByModel(provider: .claude, sinceDay: nil)["x"])
    }

    func test_persistThenReload_restoresLedgerAndOffsets() {
        let dir = TempDirectory()
        let url = dir.url.appendingPathComponent("stats-ledger.json")

        let store1 = StatsStore(reader: FakeJSONLogReader(),
                                ledgerURL: url,
                                clock: { self.date("2026-06-13T10:00:00.000Z") },
                                persistDebounce: 0)
        store1.ingest([UsageEvent(uuid: "u1", sessionId: "s",
                                  timestamp: date("2026-06-13T01:00:00.000Z"),
                                  tokens: TokenBreakdown(input: 100), model: "opus")],
                      provider: .claude)
        store1.flush()

        let store2 = StatsStore(reader: FakeJSONLogReader(),
                                ledgerURL: url,
                                clock: { self.date("2026-06-13T10:00:00.000Z") },
                                persistDebounce: 0)
        XCTAssertEqual(store2.total(provider: .claude, sinceDay: nil), TokenBreakdown(input: 100))
    }

    func test_ingest_retainsOldDataWithoutPruning() {
        let store = StatsStore(reader: FakeJSONLogReader(),
                               ledgerURL: URL(fileURLWithPath: "/dev/null"),
                               clock: { self.date("2026-06-13T10:00:00.000Z") },
                               persistDebounce: 0)
        // A day far older than any prior 90-day window:
        store.ingest([UsageEvent(uuid: "old", sessionId: "s",
                                 timestamp: date("2024-01-01T00:00:00.000Z"),
                                 tokens: TokenBreakdown(input: 3), model: "opus")],
                     provider: .claude)
        XCTAssertEqual(store.total(provider: .claude, sinceDay: nil), TokenBreakdown(input: 3))  // not pruned
    }

    func test_clear_emptiesProviderAndPersists() throws {
        let dir = TempDirectory()
        let url = dir.url.appendingPathComponent("stats-ledger.json")
        let store = StatsStore(reader: FakeJSONLogReader(), ledgerURL: url,
                               clock: { self.date("2026-06-13T10:00:00.000Z") }, persistDebounce: 0)
        store.ingest([UsageEvent(uuid: "u", sessionId: "s",
                                 timestamp: date("2026-06-13T01:00:00.000Z"),
                                 tokens: TokenBreakdown(input: 50), model: "opus")],
                     provider: .claude)
        store.clear(provider: .claude)
        XCTAssertEqual(store.total(provider: .claude, sinceDay: nil), .zero)
        store.flush()
        let reloaded = StatsStore(reader: FakeJSONLogReader(), ledgerURL: url,
                                  clock: { self.date("2026-06-13T10:00:00.000Z") }, persistDebounce: 0)
        XCTAssertEqual(reloaded.total(provider: .claude, sinceDay: nil), .zero)   // clear survived reload
    }

    func test_readChanged_ingestsEventsEndToEnd() async {
        // Verify the read→ingest path through the new serialized loop: seed
        // FakeJSONLogReader with one batch, call readChanged(nil), assert events land.
        let fake = FakeJSONLogReader()
        fake.queue = [[
            UsageEvent(uuid: "r1", sessionId: "s", timestamp: date("2026-06-13T03:00:00.000Z"),
                       tokens: TokenBreakdown(input: 50, output: 5), model: "claude-opus-4-8"),
            UsageEvent(uuid: "r2", sessionId: "s", timestamp: date("2026-06-13T04:00:00.000Z"),
                       tokens: TokenBreakdown(input: 30), model: "claude-opus-4-8"),
        ]]
        let store = StatsStore(reader: fake,
                               ledgerURL: URL(fileURLWithPath: "/dev/null"),
                               clock: { self.date("2026-06-13T10:00:00.000Z") },
                               persistDebounce: 0)
        await store.readChanged(nil, provider: .claude)
        XCTAssertEqual(store.total(provider: .claude, sinceDay: nil),
                       TokenBreakdown(input: 80, output: 5))
        XCTAssertEqual(fake.readFullCount, 1, "expected exactly one full-walk read")
    }

    // MARK: Hourly rollup

    func test_ingest_bucketsRecentEventsByHour() {
        let store = StatsStore(reader: FakeJSONLogReader(),
                               ledgerURL: URL(fileURLWithPath: "/dev/null"),
                               clock: { self.date("2026-06-13T10:00:00.000Z") },
                               calendar: StatsLedger.utcCalendarForKeys,
                               persistDebounce: 0)
        store.ingest([
            UsageEvent(uuid: "h1", sessionId: "s", timestamp: date("2026-06-13T01:30:00.000Z"),
                       tokens: TokenBreakdown(input: 100), model: "claude-opus-4-8"),
            UsageEvent(uuid: "h2", sessionId: "s", timestamp: date("2026-06-13T02:15:00.000Z"),
                       tokens: TokenBreakdown(input: 20), model: "claude-opus-4-8"),
            UsageEvent(uuid: "h3", sessionId: "s", timestamp: date("2026-06-13T02:45:00.000Z"),
                       tokens: TokenBreakdown(input: 5), model: "claude-opus-4-8"),
        ], provider: .claude)
        let series = store.hourlySeries(provider: .claude, dayKey: "2026-06-13")
        XCTAssertEqual(series.map(\.hour), [1, 2])
        XCTAssertEqual(series.first(where: { $0.hour == 2 })?.byModel["claude-opus-4-8"],
                       TokenBreakdown(input: 25))   // 02:15 + 02:45 merged
    }

    func test_hourly_dropsEventsOlderThanWindow_butDailyKeepsThem() {
        let store = StatsStore(reader: FakeJSONLogReader(),
                               ledgerURL: URL(fileURLWithPath: "/dev/null"),
                               clock: { self.date("2026-06-13T10:00:00.000Z") },
                               calendar: StatsLedger.utcCalendarForKeys,
                               persistDebounce: 0)
        // 3 days ago — outside the 48h hourly window.
        store.ingest([UsageEvent(uuid: "old", sessionId: "s",
                                 timestamp: date("2026-06-10T05:00:00.000Z"),
                                 tokens: TokenBreakdown(input: 9), model: "opus")],
                     provider: .claude)
        XCTAssertEqual(store.total(provider: .claude, sinceDay: nil), TokenBreakdown(input: 9))   // daily kept
        XCTAssertTrue(store.hourlySeries(provider: .claude, dayKey: "2026-06-10").isEmpty)         // hourly dropped
    }

    func test_hourly_persistsAcrossReload() {
        let dir = TempDirectory()
        let url = dir.url.appendingPathComponent("stats-ledger.json")
        let s1 = StatsStore(reader: FakeJSONLogReader(), ledgerURL: url,
                            clock: { self.date("2026-06-13T10:00:00.000Z") },
                            calendar: StatsLedger.utcCalendarForKeys, persistDebounce: 0)
        s1.ingest([UsageEvent(uuid: "h", sessionId: "s", timestamp: date("2026-06-13T03:00:00.000Z"),
                              tokens: TokenBreakdown(input: 11), model: "opus")], provider: .claude)
        s1.flush()
        let s2 = StatsStore(reader: FakeJSONLogReader(), ledgerURL: url,
                            clock: { self.date("2026-06-13T10:00:00.000Z") },
                            calendar: StatsLedger.utcCalendarForKeys, persistDebounce: 0)
        XCTAssertEqual(s2.hourlySeries(provider: .claude, dayKey: "2026-06-13").first?.hour, 3)
    }

    // MARK: Multi-reader

    func test_readChanged_routesToCodexReader() async {
        let claude = FakeJSONLogReader()
        let codex = FakeJSONLogReader()
        codex.queue = [[UsageEvent(uuid: "c1", sessionId: "s",
                                   timestamp: date("2026-06-13T03:00:00.000Z"),
                                   tokens: TokenBreakdown(input: 40), model: "gpt-5.5")]]
        let store = StatsStore(readers: [.claude: claude, .codex: codex],
                               ledgerURL: URL(fileURLWithPath: "/dev/null"),
                               clock: { self.date("2026-06-13T10:00:00.000Z") },
                               persistDebounce: 0)
        await store.readChanged(nil, provider: .codex)
        XCTAssertEqual(store.total(provider: .codex, sinceDay: nil), TokenBreakdown(input: 40))
        XCTAssertEqual(store.total(provider: .claude, sinceDay: nil), .zero)
    }

    func test_legacyEnvelope_migratesSingleReaderStateToClaude() throws {
        let dir = TempDirectory()
        let url = dir.url.appendingPathComponent("stats-ledger.json")
        let legacy = """
        {"ledger":{"entries":{}},"readerState":{"entries":{"/x/a.jsonl":{"offset":128,"mtime":0}}}}
        """
        try legacy.data(using: .utf8)!.write(to: url)
        let claude = FakeJSONLogReader()
        let store = StatsStore(readers: [.claude: claude],
                               ledgerURL: url, clock: { self.date("2026-06-13T10:00:00.000Z") },
                               persistDebounce: 0)
        _ = store
        XCTAssertEqual(claude.restoredState?.entries["/x/a.jsonl"]?.offset, 128)
    }

    /// The reason `pendingProvider` became a per-provider `pending` map: a signal
    /// for a SECOND provider that arrives while a FIRST provider's read is in
    /// flight must not be dropped. `GatedReader` blocks Claude's read inside
    /// `OffMain.run`; while it's suspended we signal Codex, then release Claude
    /// and assert Codex was still drained. Deterministic — gated on an
    /// expectation, no sleeps.
    func test_secondProviderPendingNotDroppedDuringInFlightRead() async {
        let claude = GatedReader()
        claude.events = [UsageEvent(uuid: "a1", sessionId: "s",
                                    timestamp: date("2026-06-13T03:00:00.000Z"),
                                    tokens: TokenBreakdown(input: 5), model: "claude-opus-4-8")]
        let codex = FakeJSONLogReader()
        codex.queue = [[UsageEvent(uuid: "c1", sessionId: "s",
                                   timestamp: date("2026-06-13T03:00:00.000Z"),
                                   tokens: TokenBreakdown(input: 7), model: "gpt-5.5")]]
        let store = StatsStore(readers: [.claude: claude, .codex: codex],
                               ledgerURL: URL(fileURLWithPath: "/dev/null"),
                               clock: { self.date("2026-06-13T10:00:00.000Z") },
                               persistDebounce: 0)

        let entered = expectation(description: "claude read in-flight")
        claude.onEntered = { entered.fulfill() }
        let first = Task { await store.readChanged(nil, provider: .claude) }
        await fulfillment(of: [entered], timeout: 2)

        // Claude is suspended in OffMain.run; this signal must coalesce, not drop.
        await store.readChanged(nil, provider: .codex)
        claude.proceed.signal()          // release Claude's read → loop drains Codex
        await first.value

        XCTAssertEqual(store.total(provider: .claude, sinceDay: nil), TokenBreakdown(input: 5))
        XCTAssertEqual(store.total(provider: .codex, sinceDay: nil), TokenBreakdown(input: 7))
    }

    /// A `clear(provider:)` that lands while a read is suspended off-main must
    /// not be undone by that read re-ingesting the just-wiped history. Models
    /// the dangerous case: Clear pressed during a long startup backfill.
    func test_clearDuringInFlightRead_isNotReingested() async {
        let claude = GatedReader()
        claude.events = [UsageEvent(uuid: "h1", sessionId: "s",
                                    timestamp: date("2026-06-13T03:00:00.000Z"),
                                    tokens: TokenBreakdown(input: 100), model: "claude-opus-4-8")]
        let store = StatsStore(readers: [.claude: claude],
                               ledgerURL: URL(fileURLWithPath: "/dev/null"),
                               clock: { self.date("2026-06-13T10:00:00.000Z") },
                               persistDebounce: 0)

        let entered = expectation(description: "backfill read in-flight")
        claude.onEntered = { entered.fulfill() }
        let first = Task { await store.readChanged(nil, provider: .claude) }
        await fulfillment(of: [entered], timeout: 2)

        store.clear(provider: .claude)   // wipe while the read is suspended
        claude.proceed.signal()          // let the (pre-clear) batch return
        await first.value

        XCTAssertEqual(store.total(provider: .claude, sinceDay: nil), .zero)   // stays cleared
    }

    /// `clear` (→ schedulePersist → makeEnvelope) must NOT snapshot the reader
    /// while a read is mutating its offsets off-main. The envelope is built from
    /// the cached cursor snapshot instead, so `reader.state()` is never called
    /// during the in-flight read.
    func test_clearDuringInFlightRead_doesNotSnapshotReader() async {
        let claude = GatedReader()
        claude.events = [UsageEvent(uuid: "h1", sessionId: "s",
                                    timestamp: date("2026-06-13T03:00:00.000Z"),
                                    tokens: TokenBreakdown(input: 100), model: "opus")]
        let store = StatsStore(readers: [.claude: claude],
                               ledgerURL: URL(fileURLWithPath: "/dev/null"),
                               clock: { self.date("2026-06-13T10:00:00.000Z") },
                               persistDebounce: 0)

        let entered = expectation(description: "read in-flight")
        claude.onEntered = { entered.fulfill() }
        let first = Task { await store.readChanged(nil, provider: .claude) }
        await fulfillment(of: [entered], timeout: 2)

        store.clear(provider: .claude)   // builds the envelope — must use the cache
        claude.proceed.signal()
        await first.value

        XCTAssertFalse(claude.stateCalledDuringRead, "reader was snapshotted during a live read")
    }
}

/// Test reader whose `read()` signals `onEntered` and then blocks on `proceed`,
/// so a test can hold one provider's read in flight while issuing another's.
/// `@unchecked Sendable`: the closure/semaphore are the synchronization, and
/// `read()` runs off-main via `OffMain.run` (GCD), so blocking it is safe.
private final class GatedReader: JSONLogReader, @unchecked Sendable {
    var events: [UsageEvent] = []
    var onEntered: (() -> Void)?
    let proceed = DispatchSemaphore(value: 0)
    /// True while `read()` is blocked off-main. If `state()` is observed true
    /// here, something snapshotted the reader during a live read (a data race).
    private(set) var inRead = false
    private(set) var stateCalledDuringRead = false

    func read() -> [UsageEvent] {
        inRead = true
        onEntered?()
        proceed.wait()
        inRead = false
        return events
    }
    func read(only paths: Set<URL>) -> [UsageEvent] { read() }
    func lastSeenLine() -> String? { nil }
    func state() -> ReaderState {
        if inRead { stateCalledDuringRead = true }
        return ReaderState()
    }
}
