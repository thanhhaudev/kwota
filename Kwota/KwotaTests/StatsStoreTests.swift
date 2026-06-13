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
}
