//
//  StatsTimeChartAxisTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

/// `StatsTimeChart.xTicks` — bounded x-axis ticks for daily mode. Ticks are
/// bucket-END boundaries anchored at the domain's upper bound (the view labels
/// each with the day before it, i.e. the range's last day), striding backward
/// so the newest data is always labeled. Gridlines keep the even stride all
/// the way to the oldest edge; a boundary closer than half a stride to the
/// lower bound keeps its gridline but drops its label (`isLabeled == false`)
/// because a right-anchored label would truncate against the plot edge there.
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
                       maxLabels: Int = 5) -> [StatsTimeChart.XTick] {
        StatsTimeChart.xTicks(domain: from...to, granularity: g,
                              maxLabels: maxLabels, calendar: cal)
    }

    private func tick(_ y: Int, _ m: Int, _ d: Int, labeled: Bool = true)
        -> StatsTimeChart.XTick {
        .init(date: date(y, m, d), isLabeled: labeled)
    }

    // 30 days: raw stride ⌈30/5⌉ = 6 > 4 → rounds up to 7. Five gridlines on
    // the even stride, all the same weekday; the oldest (Jun 3, 2 days from
    // the plot edge, < half a stride) keeps its gridline but drops its label.
    func test_30DayWindow_dayTier_strideRoundsUpToWeek() {
        let t = ticks(date(2026, 6, 1), date(2026, 7, 1), .day)
        XCTAssertEqual(t, [tick(2026, 6, 3, labeled: false), tick(2026, 6, 10),
                           tick(2026, 6, 17), tick(2026, 6, 24), tick(2026, 7, 1)])
        let weekdays = Set(t.map { cal.component(.weekday, from: $0.date) })
        XCTAssertEqual(weekdays.count, 1)
    }

    // Spec's worked example — 54-day domain (2026-05-11 → 2026-07-04):
    // ⌈54/5⌉ = 11 → rounds to 14 → 4 boundaries ending at the domain end
    // (labeled Jul 3, the newest bucket); the next candidate (May 9) falls
    // outside the domain entirely, so no fifth gridline.
    func test_54DayWindow_dayTier_stride14() {
        let t = ticks(date(2026, 5, 11), date(2026, 7, 4), .day)
        XCTAssertEqual(t, [tick(2026, 5, 23), tick(2026, 6, 6),
                           tick(2026, 6, 20), tick(2026, 7, 4)])
    }

    // 90 days (day tier's upper edge): ⌈90/5⌉ = 18 → rounds to 21 → 5
    // gridlines; the flooring remainder (Jan 7, 6 days from the edge,
    // < half a stride) is gridlined but unlabeled.
    func test_90DayWindow_dayTier_strideRoundsTo21() {
        let t = ticks(date(2026, 1, 1), date(2026, 4, 1), .day)
        XCTAssertEqual(t, [tick(2026, 1, 7, labeled: false), tick(2026, 1, 28),
                           tick(2026, 2, 18), tick(2026, 3, 11), tick(2026, 4, 1)])
    }

    // 10 days: stride 2 stays as-is — no week rounding below the >4 threshold;
    // the oldest boundary is a full stride in, so everything is labeled.
    func test_10DayWindow_dayTier_smallStrideNotWeekRounded() {
        let t = ticks(date(2026, 6, 1), date(2026, 6, 11), .day)
        XCTAssertEqual(t, [tick(2026, 6, 3), tick(2026, 6, 5), tick(2026, 6, 7),
                           tick(2026, 6, 9), tick(2026, 6, 11)])
    }

    // Regression for the live "0…"/"05…" truncations: a 57-day domain leaves
    // the oldest boundary (May 9) one day from the plot edge — gridline kept
    // for uniform ranges, label suppressed.
    func test_flooringRemainder_unlabelsSliverBoundary() {
        let t = ticks(date(2026, 5, 8), date(2026, 7, 4), .day)
        XCTAssertEqual(t, [tick(2026, 5, 9, labeled: false), tick(2026, 5, 23),
                           tick(2026, 6, 6), tick(2026, 6, 20), tick(2026, 7, 4)])
    }

    // Week tier, 40 weeks: stride ⌈40/5⌉ = 8 weeks; boundaries stay on week
    // starts (no day-tier rounding applied), all labeled, ending at the
    // domain end.
    func test_weekTier_strideInWeeks() {
        let start = date(2026, 1, 5)   // a Monday (firstWeekday = 2)
        let end = cal.date(byAdding: .weekOfYear, value: 40, to: start)!
        let t = ticks(start, end, .week)
        XCTAssertEqual(t.count, 5)
        XCTAssertTrue(t.allSatisfy(\.isLabeled))
        XCTAssertEqual(t.first?.date, cal.date(byAdding: .weekOfYear, value: 8, to: start))
        XCTAssertEqual(t.last?.date, end)
    }

    // Month tier, 30 months: stride ⌈30/5⌉ = 6 → Jan/Jul boundary alternation
    // ending at the domain end, all labeled.
    func test_monthTier_strideInMonths() {
        let t = ticks(date(2024, 1, 1), date(2026, 7, 1), .month)
        XCTAssertEqual(t, [tick(2024, 7, 1), tick(2025, 1, 1), tick(2025, 7, 1),
                           tick(2026, 1, 1), tick(2026, 7, 1)])
    }

    // Year tier, 8 years: stride ⌈8/5⌉ = 2 → 4 boundaries; the earliest
    // candidate (2018) sits exactly on the lower bound and is excluded — a
    // gridline at the plot edge would double the chart border.
    func test_yearTier_strideInYears() {
        let t = ticks(date(2018, 1, 1), date(2026, 1, 1), .year)
        XCTAssertEqual(t, [tick(2020, 1, 1), tick(2022, 1, 1),
                           tick(2024, 1, 1), tick(2026, 1, 1)])
    }

    // Degenerate domain (lower == upper): no boundary can label in-domain data.
    func test_degenerateDomain_returnsEmpty() {
        let d = date(2026, 6, 1)
        XCTAssertEqual(ticks(d, d, .day), [])
    }

    // Invariants, deterministic sweep of spans 2…4000 days across the tiers
    // `StatsGranularity.forSpan` would pick: never more than maxLabels ticks,
    // never empty, the domain end is ALWAYS the last tick and labeled (so the
    // newest data is always labeled), every gridline is strictly inside the
    // domain, and only the oldest tick may go unlabeled.
    func test_capAndNewestAnchorInvariants() {
        let start = date(2020, 1, 1)
        for span in stride(from: 2, through: 4000, by: 37) {
            let end = cal.date(byAdding: .day, value: span, to: start)!
            let g = StatsGranularity.forSpan(days: span)
            let t = ticks(start, end, g)
            XCTAssertLessThanOrEqual(t.count, 5, "span \(span) days (\(g))")
            XCTAssertFalse(t.isEmpty, "span \(span) days (\(g))")
            XCTAssertEqual(t.last?.date, end, "span \(span) days (\(g))")
            XCTAssertEqual(t.last?.isLabeled, true, "span \(span) days (\(g))")
            XCTAssertGreaterThan(t.first!.date, start, "span \(span) days (\(g))")
            XCTAssertTrue(t.dropFirst().allSatisfy(\.isLabeled), "span \(span) days (\(g))")
        }
    }
}
