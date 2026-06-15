import XCTest
@testable import Kwota

final class StatsLedgerTests: XCTestCase {
    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)!
    }

    // MARK: - Key formatting (UTC daily / injected-calendar hourly)

    /// `dayKey`/`hourKey` must produce zero-padded "yyyy-MM-dd"[" HH"] in the
    /// given calendar's timezone. Characterizes the exact output so the
    /// formatter implementation can change without altering bucket keys.
    func test_dayKey_hourKey_format_acrossTimezones() {
        let l = StatsLedger()
        let d = date("2026-06-15T23:30:00.000Z")
        XCTAssertEqual(l.dayKey(for: d), "2026-06-15")        // UTC default
        XCTAssertEqual(l.hourKey(for: d), "2026-06-15 23")

        var la = Calendar(identifier: .iso8601)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!   // UTC-7 in June
        XCTAssertEqual(l.dayKey(for: d, calendar: la), "2026-06-15") // 16:30 PDT, same day
        XCTAssertEqual(l.hourKey(for: d, calendar: la), "2026-06-15 16")

        let crossMidnight = date("2026-06-16T02:00:00.000Z")        // 19:00 PDT prev day
        XCTAssertEqual(l.dayKey(for: crossMidnight, calendar: la), "2026-06-15")
        XCTAssertEqual(l.hourKey(for: crossMidnight, calendar: la), "2026-06-15 19")

        let padded = date("2026-01-05T04:08:00.000Z")              // single-digit month/day/hour
        XCTAssertEqual(l.dayKey(for: padded), "2026-01-05")
        XCTAssertEqual(l.hourKey(for: padded), "2026-01-05 04")
    }

    // MARK: - Round 1: merge + dayKey + total/totalsByModel

    func test_merge_accumulatesPerProviderDayModel() {
        var l = StatsLedger()
        let now = date("2026-06-13T10:00:00.000Z")
        l.merge(provider: .claude, day: "2026-06-13", model: "opus",
                delta: TokenBreakdown(input: 100, output: 20, cacheRead: 5), now: now)
        l.merge(provider: .claude, day: "2026-06-13", model: "opus",
                delta: TokenBreakdown(input: 10, output: 2, cacheRead: 1), now: now)
        l.merge(provider: .claude, day: "2026-06-13", model: "sonnet",
                delta: TokenBreakdown(input: 50, output: 5), now: now)

        let byModel = l.totalsByModel(provider: .claude, sinceDay: nil)
        XCTAssertEqual(byModel["opus"], TokenBreakdown(input: 110, output: 22, cacheRead: 6))
        XCTAssertEqual(byModel["sonnet"], TokenBreakdown(input: 50, output: 5))

        let total = l.total(provider: .claude, sinceDay: nil)
        XCTAssertEqual(total, TokenBreakdown(input: 160, output: 27, cacheRead: 6))
        XCTAssertEqual(l.lastUpdate, now)
    }

    func test_total_filtersBySinceDay() {
        var l = StatsLedger()
        let now = date("2026-06-13T10:00:00.000Z")
        l.merge(provider: .claude, day: "2026-06-10", model: "opus", delta: TokenBreakdown(input: 1), now: now)
        l.merge(provider: .claude, day: "2026-06-13", model: "opus", delta: TokenBreakdown(input: 9), now: now)
        XCTAssertEqual(l.total(provider: .claude, sinceDay: "2026-06-13").input, 9)
        XCTAssertEqual(l.total(provider: .claude, sinceDay: "2026-06-10").input, 10)
    }

    func test_total_isZeroForUnknownProvider() {
        let l = StatsLedger()
        XCTAssertEqual(l.total(provider: .codex, sinceDay: nil), .zero)
    }

    func test_dayKey_isUTCAnchored() {
        let l = StatsLedger()
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let d = f.date(from: "2026-06-13T23:30:00-07:00")!   // == 2026-06-14T06:30 UTC
        XCTAssertEqual(l.dayKey(for: d), "2026-06-14")
    }

    // MARK: - Round 2: dailySeries + prune

    func test_dailySeries_isSortedAscendingAndFilters() {
        var l = StatsLedger()
        let now = date("2026-06-13T10:00:00.000Z")
        l.merge(provider: .claude, day: "2026-06-13", model: "opus", delta: TokenBreakdown(input: 9), now: now)
        l.merge(provider: .claude, day: "2026-06-11", model: "opus", delta: TokenBreakdown(input: 1), now: now)
        l.merge(provider: .claude, day: "2026-06-12", model: "sonnet", delta: TokenBreakdown(input: 4), now: now)

        let series = l.dailySeries(provider: .claude, sinceDay: "2026-06-12")
        XCTAssertEqual(series.map(\.day), ["2026-06-12", "2026-06-13"])
        XCTAssertEqual(series.first?.byModel["sonnet"]?.input, 4)
    }

    func test_prune_dropsDaysOlderThanCutoff() {
        var l = StatsLedger()
        let now = date("2026-06-13T10:00:00.000Z")
        l.merge(provider: .claude, day: "2026-06-01", model: "opus", delta: TokenBreakdown(input: 1), now: now)
        l.merge(provider: .claude, day: "2026-06-13", model: "opus", delta: TokenBreakdown(input: 9), now: now)
        l.prune(olderThan: 7, now: now)
        XCTAssertEqual(l.dailySeries(provider: .claude, sinceDay: nil).map(\.day), ["2026-06-13"])
    }

    // MARK: - Round 3: codable round-trip + graceful decode

    func test_codable_roundTrip() throws {
        var l = StatsLedger()
        let now = date("2026-06-13T10:00:00.000Z")
        l.merge(provider: .claude, day: "2026-06-13", model: "opus",
                delta: TokenBreakdown(input: 100, output: 20, cacheRead: 5), now: now)
        let data = try JSONEncoder().encode(l)
        let decoded = try JSONDecoder().decode(StatsLedger.self, from: data)
        XCTAssertEqual(decoded, l)
    }

    func test_decode_missingFieldsDefaultGracefully() throws {
        let json = #"{"schemaVersion":1}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(StatsLedger.self, from: json)
        XCTAssertEqual(decoded.total(provider: .claude, sinceDay: nil), .zero)
        XCTAssertEqual(decoded.schemaVersion, 1)
    }

    // MARK: - Round 4: edge cases

    func test_merge_noOpsOnZeroDelta() {
        var l = StatsLedger()
        let now = date("2026-06-13T10:00:00.000Z")
        l.merge(provider: .claude, day: "2026-06-13", model: "opus", delta: .zero, now: now)
        XCTAssertEqual(l.total(provider: .claude, sinceDay: nil), .zero)
        XCTAssertEqual(l.lastUpdate, .distantPast)   // lastUpdate untouched on no-op
    }

    func test_merge_normalizesEmptyModelToUnknown() {
        var l = StatsLedger()
        let now = date("2026-06-13T10:00:00.000Z")
        l.merge(provider: .claude, day: "2026-06-13", model: "", delta: TokenBreakdown(input: 1), now: now)
        XCTAssertEqual(l.totalsByModel(provider: .claude, sinceDay: nil)["unknown"], TokenBreakdown(input: 1))
    }

    func test_clear_removesOnlyThatProvider() {
        var l = StatsLedger()
        let now = date("2026-06-13T10:00:00.000Z")
        l.merge(provider: .claude, day: "2026-06-13", model: "opus", delta: TokenBreakdown(input: 5), now: now)
        l.merge(provider: .codex, day: "2026-06-13", model: "gpt", delta: TokenBreakdown(input: 9), now: now)
        l.clear(provider: .claude, now: now)
        XCTAssertEqual(l.total(provider: .claude, sinceDay: nil), .zero)
        XCTAssertEqual(l.total(provider: .codex, sinceDay: nil), TokenBreakdown(input: 9))
    }

    func test_prune_appliesAcrossAllProviders() {
        var l = StatsLedger()
        let now = date("2026-06-13T10:00:00.000Z")
        l.merge(provider: .claude, day: "2026-06-01", model: "opus", delta: TokenBreakdown(input: 1), now: now)
        l.merge(provider: .codex, day: "2026-06-01", model: "gpt", delta: TokenBreakdown(input: 1), now: now)
        l.merge(provider: .codex, day: "2026-06-13", model: "gpt", delta: TokenBreakdown(input: 2), now: now)
        l.prune(olderThan: 7, now: now)
        XCTAssertTrue(l.dailySeries(provider: .claude, sinceDay: nil).isEmpty)            // old claude day pruned
        XCTAssertEqual(l.dailySeries(provider: .codex, sinceDay: nil).map(\.day), ["2026-06-13"])  // codex pruned too
    }
}
