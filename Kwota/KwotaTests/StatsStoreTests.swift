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
}
