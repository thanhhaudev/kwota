//
//  StatsTimeChartAxisTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

/// `StatsTimeChart.xTicks` — bounded x-axis tick dates for daily mode.
/// Pure function; a fixed UTC gregorian calendar keeps results machine-independent.
final class StatsTimeChartAxisTests: XCTestCase {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func ticks(_ from: Date, _ to: Date, _ g: StatsGranularity,
                       maxLabels: Int = 5) -> [Date] {
        StatsTimeChart.xTicks(domain: from...to, granularity: g,
                              maxLabels: maxLabels, calendar: cal)
    }

    // 30 days: raw stride ⌈30/5⌉ = 6 > 4 → rounds up to 7. Five ticks, all the
    // same weekday.
    func test_30DayWindow_dayTier_strideRoundsUpToWeek() {
        let t = ticks(date(2026, 6, 1), date(2026, 7, 1), .day)
        XCTAssertEqual(t, [date(2026, 6, 1), date(2026, 6, 8), date(2026, 6, 15),
                           date(2026, 6, 22), date(2026, 6, 29)])
        let weekdays = Set(t.map { cal.component(.weekday, from: $0) })
        XCTAssertEqual(weekdays.count, 1)
    }

    // Spec's worked example — 54-day domain (2026-05-11 → 2026-07-04):
    // ⌈54/5⌉ = 11 → rounds to 14 → 4 ticks.
    func test_54DayWindow_dayTier_stride14() {
        let t = ticks(date(2026, 5, 11), date(2026, 7, 4), .day)
        XCTAssertEqual(t, [date(2026, 5, 11), date(2026, 5, 25),
                           date(2026, 6, 8), date(2026, 6, 22)])
    }

    // 90 days (day tier's upper edge): ⌈90/5⌉ = 18 → rounds to 21 → 5 ticks.
    func test_90DayWindow_dayTier_strideRoundsTo21() {
        let t = ticks(date(2026, 1, 1), date(2026, 4, 1), .day)
        XCTAssertEqual(t.count, 5)
        XCTAssertEqual(t[1], date(2026, 1, 22))
    }

    // 10 days: stride 2 stays as-is — no week rounding below the >4 threshold.
    func test_10DayWindow_dayTier_smallStrideNotWeekRounded() {
        let t = ticks(date(2026, 6, 1), date(2026, 6, 11), .day)
        XCTAssertEqual(t, [date(2026, 6, 1), date(2026, 6, 3), date(2026, 6, 5),
                           date(2026, 6, 7), date(2026, 6, 9)])
    }

    // Week tier, 40 weeks: stride ⌈40/5⌉ = 8 weeks; ticks stay on week starts
    // (no day-tier rounding applied).
    func test_weekTier_strideInWeeks() {
        let start = date(2026, 1, 5)   // a Monday (firstWeekday = 2)
        let end = cal.date(byAdding: .weekOfYear, value: 40, to: start)!
        let t = ticks(start, end, .week)
        XCTAssertEqual(t.count, 5)
        XCTAssertEqual(t[1], cal.date(byAdding: .weekOfYear, value: 8, to: start))
    }

    // Month tier, 30 months: stride ⌈30/5⌉ = 6 → Jan/Jul alternation, 5 ticks.
    func test_monthTier_strideInMonths() {
        let t = ticks(date(2024, 1, 1), date(2026, 7, 1), .month)
        XCTAssertEqual(t, [date(2024, 1, 1), date(2024, 7, 1), date(2025, 1, 1),
                           date(2025, 7, 1), date(2026, 1, 1)])
    }

    // Year tier, 8 years: stride ⌈8/5⌉ = 2 → 4 ticks.
    func test_yearTier_strideInYears() {
        let t = ticks(date(2018, 1, 1), date(2026, 1, 1), .year)
        XCTAssertEqual(t, [date(2018, 1, 1), date(2020, 1, 1),
                           date(2022, 1, 1), date(2024, 1, 1)])
    }

    // Degenerate domain (lower == upper): one tick, no crash.
    func test_degenerateDomain_returnsLowerBound() {
        let d = date(2026, 6, 1)
        XCTAssertEqual(ticks(d, d, .day), [d])
    }

    // Cap invariant: deterministic sweep of spans 2…4000 days across the tiers
    // `StatsGranularity.forSpan` would pick — never more than maxLabels ticks.
    func test_capInvariant_neverExceedsMaxLabels() {
        let start = date(2020, 1, 1)
        for span in stride(from: 2, through: 4000, by: 37) {
            let end = cal.date(byAdding: .day, value: span, to: start)!
            let g = StatsGranularity.forSpan(days: span)
            let t = ticks(start, end, g)
            XCTAssertLessThanOrEqual(t.count, 5, "span \(span) days (\(g))")
            XCTAssertFalse(t.isEmpty, "span \(span) days (\(g))")
        }
    }
}
