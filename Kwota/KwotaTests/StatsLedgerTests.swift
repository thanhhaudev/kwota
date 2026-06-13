import XCTest
@testable import Kwota

final class StatsLedgerTests: XCTestCase {
    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)!
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
}
