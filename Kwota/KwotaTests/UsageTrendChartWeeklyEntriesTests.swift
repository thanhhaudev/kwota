//
//  UsageTrendChartWeeklyEntriesTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class UsageTrendChartWeeklyEntriesTests: XCTestCase {
    private func date(_ ts: TimeInterval) -> Date { Date(timeIntervalSince1970: ts) }

    fileprivate func snapshot(util: Double, resetsAt: Date?) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsageBucket(utilization: 0, resetsAt: nil),
            sevenDay: UsageBucket(utilization: util, resetsAt: resetsAt),
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            sevenDayOmelette: nil,
            fetchedAt: date(0)
        )
    }

    private func entry(_ at: Date, _ sevenDay: Double) -> UsageHistoryEntry {
        UsageHistoryEntry(id: UUID(), at: at, fiveHour: nil, sevenDay: sevenDay)
    }

    func testProducesSevenBars() {
        let now = date(1_000_000)
        let result = UsageTrendChart.weeklyEntries(
            snapshot: snapshot(util: 30, resetsAt: now.addingTimeInterval(3 * 86_400)),
            history: [],
            now: now
        )
        XCTAssertEqual(result.count, 7)
    }

    func testBarsAnchoredToCycleStartNotCalendarMonday() {
        // resetsAt is 3 days ahead → cycleStart = now - 4d. First bar's
        // date must equal cycleStart's startOfDay, NOT Monday-of-week.
        let now = date(1_000_000)
        let resetsAt = now.addingTimeInterval(3 * 86_400)
        let expectedCycleStart = resetsAt.addingTimeInterval(-7 * 86_400)
        let result = UsageTrendChart.weeklyEntries(
            snapshot: snapshot(util: 30, resetsAt: resetsAt),
            history: [],
            now: now
        )
        let cal = Calendar.current
        XCTAssertTrue(
            cal.isDate(result[0].at, inSameDayAs: expectedCycleStart),
            "first bar at \(result[0].at), expected day-of \(expectedCycleStart)"
        )
    }

    func testFutureDaysMarkedIsFutureWithZeroValue() {
        // 4 days into a 7-day cycle (resetsAt 3d ahead → cycleStart = now-4d)
        // → D1..D5 (offsets 0..4) are past/today, D6 and D7 (offsets 5..6) are future.
        let now = date(1_000_000)
        let resetsAt = now.addingTimeInterval(3 * 86_400)   // cycleStart = now - 4d
        let result = UsageTrendChart.weeklyEntries(
            snapshot: snapshot(util: 60, resetsAt: resetsAt),
            history: [],
            now: now
        )
        XCTAssertFalse(result[0].isFuture)
        XCTAssertFalse(result[4].isFuture)   // today (offset 4 = now)
        XCTAssertTrue(result[5].isFuture)
        XCTAssertTrue(result[6].isFuture)
        XCTAssertEqual(result[5].value, 0)
        XCTAssertEqual(result[6].value, 0)
    }

    func testCrossCycleSamplesAreFiltered() {
        // History contains a sample from BEFORE cycleStart that, if not
        // filtered, would carry forward (LOCF) into the current cycle's D1.
        let now = date(1_000_000)
        let resetsAt = now.addingTimeInterval(3 * 86_400)
        let cycleStart = resetsAt.addingTimeInterval(-7 * 86_400)
        let beforeCycle = cycleStart.addingTimeInterval(-86_400)  // 1d before cycle
        let inCycle = cycleStart.addingTimeInterval(2 * 86_400)   // D3
        let history = [
            entry(beforeCycle, 92),   // would pollute D1 via LOCF if not filtered
            entry(inCycle, 18),
        ]
        let result = UsageTrendChart.weeklyEntries(
            snapshot: snapshot(util: 18, resetsAt: resetsAt),
            history: history,
            now: now
        )
        // D1 (offset 0) has no in-cycle sample and no carryable prior — should be 0, not 92.
        XCTAssertEqual(result[0].value, 0)
        XCTAssertEqual(result[2].value, 18)  // D3 carries the in-cycle sample
    }

    func testStaleApiAnchorRendersFreshCycleAtNow() {
        // resetsAt is in the past → cycleStart = now. D1 = today.
        let now = date(1_000_000)
        let result = UsageTrendChart.weeklyEntries(
            snapshot: snapshot(util: 0, resetsAt: now.addingTimeInterval(-3_600)),
            history: [],
            now: now
        )
        let cal = Calendar.current
        XCTAssertTrue(cal.isDate(result[0].at, inSameDayAs: now))
        // D2..D7 should all be future.
        for i in 1..<7 { XCTAssertTrue(result[i].isFuture, "bar \(i) should be future") }
    }

    func testFallbackToMondayWhenNoApiAndNoHistory() {
        let now = date(1_000_000)
        let result = UsageTrendChart.weeklyEntries(
            snapshot: snapshot(util: 30, resetsAt: nil),
            history: [],
            now: now
        )
        let monday = UsageTrendChart.currentWeekStart(now: now)
        let cal = Calendar.current
        XCTAssertTrue(cal.isDate(result[0].at, inSameDayAs: monday))
    }

    func testLOCFCarriesForwardNonZeroSampleAcrossSparseDays() {
        // The LOCF path: a sample lands on D3 but D4 and D5 have no in-cycle
        // samples. They must inherit D3's value via the `lastSeen` carry,
        // NOT fall back to 0. The cross-cycle test passes vacuously
        // because its LOCF carry is 0 → 0; this test exercises 45 → 45.
        let now = date(1_000_000)
        let resetsAt = now.addingTimeInterval(2 * 86_400)  // 2d ahead
        let cycleStart = resetsAt.addingTimeInterval(-7 * 86_400)
        // D3 = cycleStart + 2d. Place a single sample mid-day on D3.
        let d3 = cycleStart.addingTimeInterval(2 * 86_400 + 3_600)
        let history = [entry(d3, 45)]
        let result = UsageTrendChart.weeklyEntries(
            snapshot: snapshot(util: 45, resetsAt: resetsAt),
            history: history,
            now: now
        )
        XCTAssertEqual(result[2].value, 45, "D3 should carry the actual sample")
        XCTAssertEqual(result[3].value, 45, "D4 has no sample but must LOCF from D3")
        XCTAssertEqual(result[4].value, 45, "D5 also LOCFs from D3")
        // Days before D3 had no sample and no carryable prior — should be 0.
        XCTAssertEqual(result[0].value, 0)
        XCTAssertEqual(result[1].value, 0)
    }

    func testFinalBucketIncludesPostMidnightSamplesBeforeReset() throws {
        var cal = Calendar.current
        cal.timeZone = .current

        let now = try XCTUnwrap(cal.date(from: DateComponents(
            year: 2026, month: 6, day: 27, hour: 0, minute: 30
        )))
        let resetsAt = try XCTUnwrap(cal.date(from: DateComponents(
            year: 2026, month: 6, day: 27, hour: 6
        )))
        let previousNight = try XCTUnwrap(cal.date(from: DateComponents(
            year: 2026, month: 6, day: 26, hour: 23, minute: 58
        )))

        let history = [
            entry(previousNight, 80),
            entry(now, 91),
        ]

        let result = UsageTrendChart.weeklyEntries(
            snapshot: snapshot(util: 91, resetsAt: resetsAt),
            history: history,
            now: now
        )

        XCTAssertEqual(result.count, 7)
        XCTAssertEqual(result[6].value, 91)
    }

    // MARK: - weekAverageForChart anchor

    func testWeeklyAverageReturnsNilWhenUseAvgLineFalse() {
        // Direct test of the guard clause in `weeklyAverage`. Even with
        // a perfectly-shaped history that would yield a real value, the
        // guard must short-circuit when useAvgLine is false (Monday
        // fallback). Catches a future refactor that drops the guard.
        let samples: [(at: Date, value: Double)] = [
            (date(0), 10), (date(1), 30), (date(2), 60), (date(3), 95),
            (date(4), 5),  (date(5), 25), (date(6), 55), (date(7), 90),
            (date(8), 15),
        ]
        let history = samples.map { entry($0.at, $0.value) }
        let result = UsageTrendChart.weeklyAverage(
            history: history,
            cycleStart: date(8),
            useAvgLine: false,
            now: date(9)
        )
        XCTAssertNil(result)
    }

    func testWeeklyAverageReturnsMidCycleValueAtCycleAnchoredElapsed() {
        // End-to-end: same series as the calculator-level sibling test
        // above. After weeklyTimelines drops the fake-first and trailing
        // groups, one cycle survives — its LOCF at elapsed=1 is 25.
        // Mean of {25} = 25.
        let samples: [(at: Date, value: Double)] = [
            (date(0), 10), (date(1), 30), (date(2), 60), (date(3), 95),
            (date(4), 5),  (date(5), 25), (date(6), 55), (date(7), 90),
            (date(8), 15),
        ]
        let history = samples.map { entry($0.at, $0.value) }
        let result = UsageTrendChart.weeklyAverage(
            history: history,
            cycleStart: date(8),
            useAvgLine: true,
            now: date(9)
        )
        XCTAssertEqual(result, 25)
    }

    func testWeekAvgCalculatorLOCFReturnsMidCycleNotPeak() {
        // Three sample-groups: a pre-first-drop "fake" group, one fully
        // completed cycle anchored by a real drop, and a trailing
        // in-progress sample. After the fake-first and trailing drops
        // imposed by weeklyTimelines, only the middle cycle remains:
        //   completed cycle: t=[4..7] values [5, 25, 55, 90]
        //   anchored at t=4, so elapsed within the cycle is [0,1,2,3]
        //
        // With cycleStart=8 and now=9 (elapsed=1), the LOCF lookup
        // returns the elapsed=1 sample = 25. Mean of {25} = 25 — a
        // mid-cycle value, NOT the peak (90). The renamed test pins
        // the calculator-level invariant the redesign relies on.
        let samples: [(at: Date, value: Double)] = [
            (date(0), 10), (date(1), 30), (date(2), 60), (date(3), 95),
            (date(4), 5),  (date(5), 25), (date(6), 55), (date(7), 90),
            (date(8), 15),
        ]
        let timelines = WeekAvgCalculator.weeklyTimelines(from: samples)
        let elapsed: TimeInterval = 1
        let avg = WeekAvgCalculator.avgAtElapsed(elapsed, in: timelines)
        XCTAssertEqual(avg, 25)
    }
}
