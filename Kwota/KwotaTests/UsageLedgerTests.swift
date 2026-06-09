//
//  UsageLedgerTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class UsageLedgerTests: XCTestCase {
    private func event(_ uuid: String, _ ts: String, input: Int = 10, output: Int = 5) -> UsageEvent {
        UsageEvent(
            uuid: uuid,
            sessionId: "session-1",
            timestamp: ISO8601DateFormatter().date(from: ts)!,
            tokens: TokenBreakdown(input: input, output: output)
        )
    }

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testIngestReturnsNewlyInsertedEvents() {
        var ledger = UsageLedger()
        let e1 = event("a", "2026-04-26T10:00:00Z")
        let e2 = event("b", "2026-04-26T10:01:00Z")

        let new = ledger.ingest(events: [e1, e2], now: date("2026-04-26T10:02:00Z"))

        XCTAssertEqual(new.map(\.uuid), ["a", "b"])
        let key = ledger.dayKey(for: e1.timestamp)
        XCTAssertEqual(ledger.dailyBillable(day: key), 30)
    }

    func testIngestDedupesByUUID() {
        var ledger = UsageLedger()
        let e1 = event("a", "2026-04-26T10:00:00Z")
        _ = ledger.ingest(events: [e1, e1], now: date("2026-04-26T10:00:00Z"))

        let again = ledger.ingest(events: [e1], now: date("2026-04-26T10:00:00Z"))
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(ledger.dailyBillable(day: ledger.dayKey(for: e1.timestamp)), 15)
    }

    func testDailyBucketsBucketByEventTimestampNotNow() {
        var ledger = UsageLedger()
        // Pick UTC-distant timestamps that are guaranteed to fall on different local days
        // in any reasonable timezone (12 hours apart, straddling midnight UTC and most TZs).
        let e1 = event("a", "2026-04-25T00:01:00Z", input: 100, output: 0)
        let e2 = event("b", "2026-04-26T23:59:00Z", input: 200, output: 0)
        _ = ledger.ingest(events: [e1, e2], now: date("2026-04-26T23:59:00Z"))

        let total = ledger.dailyBillable(day: ledger.dayKey(for: e1.timestamp)) +
                    ledger.dailyBillable(day: ledger.dayKey(for: e2.timestamp))
        XCTAssertEqual(total, 300)
        XCTAssertNotEqual(ledger.dayKey(for: e1.timestamp), ledger.dayKey(for: e2.timestamp))
    }

    func testPruneDropsOldBucketsButKeepsUUIDs() {
        var ledger = UsageLedger()
        let oldEvent = event("old", "2026-04-15T12:00:00Z")
        let newEvent = event("new", "2026-04-26T12:00:00Z")
        _ = ledger.ingest(events: [oldEvent, newEvent], now: date("2026-04-26T12:00:00Z"))

        ledger.prune(olderThan: 7, now: date("2026-04-26T12:00:00Z"))

        XCTAssertEqual(ledger.dailyBillable(day: ledger.dayKey(for: oldEvent.timestamp)), 0)
        XCTAssertEqual(ledger.dailyBillable(day: ledger.dayKey(for: newEvent.timestamp)), 15)

        // Re-ingesting the old event must NOT add to today's bucket — uuid still seen.
        let reingest = ledger.ingest(events: [oldEvent], now: date("2026-04-26T12:00:00Z"))
        XCTAssertTrue(reingest.isEmpty)
    }

    func testRoundTripsThroughJSON() throws {
        var ledger = UsageLedger()
        _ = ledger.ingest(events: [event("a", "2026-04-26T10:00:00Z")],
                          now: date("2026-04-26T10:00:00Z"))

        let data = try JSONEncoder().encode(ledger)
        let decoded = try JSONDecoder().decode(UsageLedger.self, from: data)

        XCTAssertEqual(decoded.dailyBillable(day: ledger.dayKey(for: date("2026-04-26T10:00:00Z"))), 15)

        // seenUUIDs is in-memory only as of schemaVersion 3 — JSON round-trip
        // intentionally drops it. Reader-offset persistence (in UsageMonitor)
        // is the cross-restart dedup mechanism now.
        let reingest = decoded.ingestPreview(events: [event("a", "2026-04-26T10:00:00Z")])
        XCTAssertFalse(reingest.isEmpty, "decoded ledger must not carry seenUUIDs across encode/decode")
    }

    // MARK: - UTC dayKey (cross-tz invariance)

    func testDayKeyDefaultsToUTCEdgesOfDay() {
        let ledger = UsageLedger()
        // 23:59:59 UTC and 00:00:00 UTC the next day must land in adjacent
        // UTC buckets, regardless of whatever timezone the test host runs in.
        XCTAssertEqual(ledger.dayKey(for: date("2026-05-02T23:59:59Z")), "2026-05-02")
        XCTAssertEqual(ledger.dayKey(for: date("2026-05-03T00:00:00Z")), "2026-05-03")
    }

    func testDayKeyIsTimezoneStableAcrossUserCalendars() {
        // Simulate a user in GMT+7 (Vietnam) vs GMT-7 (US) by passing local
        // calendars explicitly: the default UTC anchor must produce the same
        // key for the same instant either way.
        let ledger = UsageLedger()
        let instant = date("2026-05-02T19:00:00Z") // 02:00 next day in GMT+7, 12:00 same day in GMT-7

        let utcKey = ledger.dayKey(for: instant)
        XCTAssertEqual(utcKey, "2026-05-02", "UTC key must follow the instant, not the host calendar")

        // Sanity-check the bug we are guarding against: a non-UTC calendar
        // would have produced a different key for the same Date.
        var gmtPlus7 = Calendar(identifier: .iso8601)
        gmtPlus7.timeZone = TimeZone(secondsFromGMT: 7 * 3600)!
        let localKey = ledger.dayKey(for: instant, calendar: gmtPlus7)
        XCTAssertEqual(localKey, "2026-05-03", "GMT+7 calendar would have shifted the key — proving the original Calendar.current bug")
    }

    func testPruneCutoffUsesUTCByDefault() {
        var ledger = UsageLedger()
        // Old event 8 UTC days before now — must be dropped when olderThan: 7.
        let oldEvent = event("old", "2026-04-24T12:00:00Z", input: 100, output: 0)
        let recentEvent = event("recent", "2026-04-30T12:00:00Z", input: 50, output: 0)
        let now = date("2026-05-02T12:00:00Z")
        _ = ledger.ingest(events: [oldEvent, recentEvent], now: now)

        ledger.prune(olderThan: 7, now: now)

        XCTAssertEqual(ledger.dailyBillable(day: "2026-04-24"), 0, "8-day-old UTC bucket must be pruned")
        XCTAssertEqual(ledger.dailyBillable(day: "2026-04-30"), 50, "recent UTC bucket survives")
    }

    func testDecodingLegacyLedgerMissingSchemaVersionTreatsAsV1() throws {
        // A pre-fix on-disk ledger has no schemaVersion field. Custom decoder
        // must treat that as v1 so the loader can spot it and drop the cache.
        let legacyJSON = """
        {
          "seenUUIDs": ["a", "b"],
          "dailyByDay": {
            "2026-05-01": {
              "input_tokens": 100,
              "output_tokens": 50,
              "cache_creation_input_tokens": 0,
              "cache_read_input_tokens": 0
            }
          },
          "lastUpdate": 768657600.0
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(UsageLedger.self, from: legacyJSON)

        XCTAssertEqual(decoded.schemaVersion, 1, "missing schemaVersion must decode as 1 (legacy)")
        XCTAssertEqual(decoded.seenUUIDs, [], "seenUUIDs is in-memory only — never decoded from disk")
        XCTAssertEqual(decoded.dailyBillable(day: "2026-05-01"), 150)
    }

    func testNewLedgerInstancesAreSchemaV2() {
        XCTAssertEqual(UsageLedger().schemaVersion, 2)
    }

    // MARK: - seenUUIDs is in-memory only (Phase 2)

    func testEncode_doesNotIncludeSeenUUIDs() throws {
        var ledger = UsageLedger()
        _ = ledger.ingest(
            events: [event("u1", "2026-04-26T10:00:00Z")],
            now: date("2026-04-26T10:00:00Z")
        )
        XCTAssertEqual(ledger.seenUUIDs.count, 1, "in-memory dedup still tracks UUIDs")
        let data = try JSONEncoder().encode(ledger)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("seenUUIDs"),
                       "encoded ledger must not include seenUUIDs (in-memory only)")
    }

    func testDecode_legacyV2WithSeenUUIDs_dropsTheField() throws {
        // A v2 on-disk shape carried seenUUIDs at the top level. Decoding
        // it must succeed but leave the in-memory Set empty.
        let legacy = """
        {
          "schemaVersion": 2,
          "seenUUIDs": ["a", "b", "c"],
          "dailyByDay": {
            "2026-04-26": {
              "input_tokens": 10,
              "output_tokens": 20,
              "cache_creation_input_tokens": 0,
              "cache_read_input_tokens": 0
            }
          },
          "lastUpdate": 770000000.0
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(UsageLedger.self, from: legacy)
        XCTAssertEqual(decoded.seenUUIDs, [], "legacy seenUUIDs must not populate in-memory Set")
        XCTAssertEqual(decoded.dailyBillable(day: "2026-04-26"), 30)
        XCTAssertEqual(decoded.schemaVersion, 2)
    }

}
