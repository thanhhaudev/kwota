//
//  StatsTimeChartAxisTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

/// `StatsTimeChart.xTicks` — bounded x-axis tick dates for daily mode. Ticks
/// are bucket-END boundaries anchored at the domain's upper bound (the view
/// labels each with the day before it, i.e. the range's last day), striding
/// backward so the newest data is always labeled and budget truncation drops
/// the oldest edge.
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

    // 30 days: raw stride ⌈30/5⌉ = 6 > 4 → rounds up to 7. Four boundaries
    // anchored at the domain end (Jul 1), all the same weekday — the fifth
    // (Jun 3) is only 2 days from the plot edge (< half a stride) and is
    // dropped so its label can't truncate.
    func test_30DayWindow_dayTier_strideRoundsUpToWeek() {
        let t = ticks(date(2026, 6, 1), date(2026, 7, 1), .day)
        XCTAssertEqual(t, [date(2026, 6, 10), date(2026, 6, 17),
                           date(2026, 6, 24), date(2026, 7, 1)])
        let weekdays = Set(t.map { cal.component(.weekday, from: $0) })
        XCTAssertEqual(weekdays.count, 1)
    }

    // Spec's worked example — 54-day domain (2026-05-11 → 2026-07-04):
    // ⌈54/5⌉ = 11 → rounds to 14 → 4 boundaries ending at the domain end
    // (labeled Jul 3, the newest bucket).
    func test_54DayWindow_dayTier_stride14() {
        let t = ticks(date(2026, 5, 11), date(2026, 7, 4), .day)
        XCTAssertEqual(t, [date(2026, 5, 23), date(2026, 6, 6),
                           date(2026, 6, 20), date(2026, 7, 4)])
    }

    // 90 days (day tier's upper edge): ⌈90/5⌉ = 18 → rounds to 21 → 4
    // boundaries ending at the domain end; the flooring remainder (Jan 7,
    // 6 days from the edge, < half a stride) is dropped.
    func test_90DayWindow_dayTier_strideRoundsTo21() {
        let t = ticks(date(2026, 1, 1), date(2026, 4, 1), .day)
        XCTAssertEqual(t, [date(2026, 1, 28), date(2026, 2, 18),
                           date(2026, 3, 11), date(2026, 4, 1)])
    }

    // Regression for the live "0…" truncation: a 57-day domain leaves the
    // oldest boundary (May 9) one day from the plot edge; it must be dropped,
    // while May 23 (15 days in, more than half the 14-day stride) survives.
    func test_flooringRemainder_dropsSliverBoundary() {
        let t = ticks(date(2026, 5, 8), date(2026, 7, 4), .day)
        XCTAssertEqual(t, [date(2026, 5, 23), date(2026, 6, 6),
                           date(2026, 6, 20), date(2026, 7, 4)])
    }

    // 10 days: stride 2 stays as-is — no week rounding below the >4 threshold.
    func test_10DayWindow_dayTier_smallStrideNotWeekRounded() {
        let t = ticks(date(2026, 6, 1), date(2026, 6, 11), .day)
        XCTAssertEqual(t, [date(2026, 6, 3), date(2026, 6, 5), date(2026, 6, 7),
                           date(2026, 6, 9), date(2026, 6, 11)])
    }

    // Week tier, 40 weeks: stride ⌈40/5⌉ = 8 weeks; boundaries stay on week
    // starts (no day-tier rounding applied) and end at the domain end.
    func test_weekTier_strideInWeeks() {
        let start = date(2026, 1, 5)   // a Monday (firstWeekday = 2)
        let end = cal.date(byAdding: .weekOfYear, value: 40, to: start)!
        let t = ticks(start, end, .week)
        XCTAssertEqual(t.count, 5)
        XCTAssertEqual(t.first, cal.date(byAdding: .weekOfYear, value: 8, to: start))
        XCTAssertEqual(t.last, end)
    }

    // Month tier, 30 months: stride ⌈30/5⌉ = 6 → Jan/Jul boundary alternation
    // ending at the domain end.
    func test_monthTier_strideInMonths() {
        let t = ticks(date(2024, 1, 1), date(2026, 7, 1), .month)
        XCTAssertEqual(t, [date(2024, 7, 1), date(2025, 1, 1), date(2025, 7, 1),
                           date(2026, 1, 1), date(2026, 7, 1)])
    }

    // Year tier, 8 years: stride ⌈8/5⌉ = 2 → 4 boundaries; the earliest
    // boundary (2018) is excluded because a boundary AT the lower bound would
    // label a bucket outside the domain.
    func test_yearTier_strideInYears() {
        let t = ticks(date(2018, 1, 1), date(2026, 1, 1), .year)
        XCTAssertEqual(t, [date(2020, 1, 1), date(2022, 1, 1),
                           date(2024, 1, 1), date(2026, 1, 1)])
    }

    // Degenerate domain (lower == upper): no boundary can label in-domain data.
    func test_degenerateDomain_returnsEmpty() {
        let d = date(2026, 6, 1)
        XCTAssertEqual(ticks(d, d, .day), [])
    }

    // Invariants, deterministic sweep of spans 2…4000 days across the tiers
    // `StatsGranularity.forSpan` would pick: never more than maxLabels ticks,
    // never empty, the domain end is ALWAYS the last boundary (so the newest
    // data is always labeled), and no boundary sits at or before the lower
    // bound (which would label out-of-domain data).
    func test_capAndNewestAnchorInvariants() {
        let start = date(2020, 1, 1)
        for span in stride(from: 2, through: 4000, by: 37) {
            let end = cal.date(byAdding: .day, value: span, to: start)!
            let g = StatsGranularity.forSpan(days: span)
            let t = ticks(start, end, g)
            XCTAssertLessThanOrEqual(t.count, 5, "span \(span) days (\(g))")
            XCTAssertFalse(t.isEmpty, "span \(span) days (\(g))")
            XCTAssertEqual(t.last, end, "span \(span) days (\(g))")
            XCTAssertGreaterThan(t.first!, start, "span \(span) days (\(g))")
        }
    }
}
