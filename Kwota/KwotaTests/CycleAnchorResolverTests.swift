//
//  CycleAnchorResolverTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class CycleAnchorResolverTests: XCTestCase {
    private func date(_ ts: TimeInterval) -> Date { Date(timeIntervalSince1970: ts) }

    private func snapshot(resetsAt: Date?) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsageBucket(utilization: 0, resetsAt: nil),
            sevenDay: UsageBucket(utilization: 50, resetsAt: resetsAt),
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            sevenDayOmelette: nil,
            fetchedAt: date(0)
        )
    }

    func testApiAnchorWhenResetInFutureWithinSevenDays() {
        let now = date(1_000_000)
        let resetsAt = now.addingTimeInterval(3 * 86_400)  // 3 days ahead
        let anchor = UsageTrendChart.resolveCycleStart(
            snapshot: snapshot(resetsAt: resetsAt),
            history: [],
            now: now
        )
        XCTAssertEqual(anchor.cycleStart, resetsAt.addingTimeInterval(-7 * 86_400))
        XCTAssertFalse(anchor.isHeuristic)
        XCTAssertTrue(anchor.useAvgLine)
    }

    func testStaleApiAnchorShortCircuitsToNow() {
        // resetsAt <= now means the server hasn't refreshed past a known reset.
        // We treat as a fresh cycle starting at `now` (D1 = today at 0%).
        let now = date(1_000_000)
        let resetsAt = now.addingTimeInterval(-3600)  // an hour in the past
        let anchor = UsageTrendChart.resolveCycleStart(
            snapshot: snapshot(resetsAt: resetsAt),
            history: [],
            now: now
        )
        XCTAssertEqual(anchor.cycleStart, now)
        XCTAssertFalse(anchor.isHeuristic)
        XCTAssertTrue(anchor.useAvgLine)
    }

    func testPathologicalFutureResetFallsThroughToHistory() {
        // resetsAt > now + 7d is treated as missing; history heuristic kicks in.
        let now = date(1_000_000)
        let pathological = now.addingTimeInterval(30 * 86_400)
        // Build a history with one detectable reset 2 days ago.
        let twoDaysAgo = now.addingTimeInterval(-2 * 86_400)
        let history: [UsageHistoryEntry] = [
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-5 * 86_400), fiveHour: nil, sevenDay: 60),
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-3 * 86_400), fiveHour: nil, sevenDay: 90),
            // reset drop here
            UsageHistoryEntry(id: UUID(), at: twoDaysAgo, fiveHour: nil, sevenDay: 5),
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-86_400), fiveHour: nil, sevenDay: 30),
        ]
        let anchor = UsageTrendChart.resolveCycleStart(
            snapshot: snapshot(resetsAt: pathological),
            history: history,
            now: now
        )
        XCTAssertEqual(anchor.cycleStart, twoDaysAgo)
        XCTAssertTrue(anchor.isHeuristic)
        XCTAssertTrue(anchor.useAvgLine)
    }

    func testHistoryHeuristicUsedWhenResetsAtNil() {
        let now = date(1_000_000)
        let resetMoment = now.addingTimeInterval(-86_400)  // 1 day ago
        let history: [UsageHistoryEntry] = [
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-3 * 86_400), fiveHour: nil, sevenDay: 70),
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-2 * 86_400), fiveHour: nil, sevenDay: 95),
            // reset
            UsageHistoryEntry(id: UUID(), at: resetMoment, fiveHour: nil, sevenDay: 3),
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-3600), fiveHour: nil, sevenDay: 15),
        ]
        let anchor = UsageTrendChart.resolveCycleStart(
            snapshot: snapshot(resetsAt: nil),
            history: history,
            now: now
        )
        XCTAssertEqual(anchor.cycleStart, resetMoment)
        XCTAssertTrue(anchor.isHeuristic)
        XCTAssertTrue(anchor.useAvgLine)
    }

    func testMondayFallbackWhenNoApiAndNoHistory() {
        let now = date(1_000_000)
        let anchor = UsageTrendChart.resolveCycleStart(
            snapshot: snapshot(resetsAt: nil),
            history: [],
            now: now
        )
        XCTAssertEqual(anchor.cycleStart, UsageTrendChart.currentWeekStart(now: now))
        XCTAssertFalse(anchor.isHeuristic)
        XCTAssertFalse(anchor.useAvgLine)
    }

    func testStaleApiBoundaryExactlyNowShortCircuits() {
        // Boundary: resetsAt == now. The `<=` in the stale-API branch
        // means this case must short-circuit to `cycleStart = now`, not
        // fall through to the normal-API branch.
        let now = date(1_000_000)
        let anchor = UsageTrendChart.resolveCycleStart(
            snapshot: snapshot(resetsAt: now),
            history: [],
            now: now
        )
        XCTAssertEqual(anchor.cycleStart, now)
        XCTAssertFalse(anchor.isHeuristic)
        XCTAssertTrue(anchor.useAvgLine)
    }

    func testApiAnchorBoundaryExactlySevenDaysAhead() {
        // Boundary: resetsAt == now + 7d. The upper-bound `<=` in the
        // normal-API branch is inclusive, so this case must use the API
        // anchor (cycleStart = now), not fall through to the heuristic.
        let now = date(1_000_000)
        let resetsAt = now.addingTimeInterval(7 * 86_400)
        let anchor = UsageTrendChart.resolveCycleStart(
            snapshot: snapshot(resetsAt: resetsAt),
            history: [],
            now: now
        )
        XCTAssertEqual(anchor.cycleStart, now)
        XCTAssertFalse(anchor.isHeuristic)
        XCTAssertTrue(anchor.useAvgLine)
    }

    // MARK: - Branch 1.5: strict drop overrides API anchor

    func testStrictDropAfterApiAnchor_overridesApiAnchor() {
        // Mirrors the user-reported scenario: API claims cycle started a
        // week ago (Sat) and resets next Sat, but history shows a clean
        // 65% → 0% drop two days ago (Thu). The strict-threshold override
        // should anchor the chart on the observed drop, not the API
        // claim, and mark itself heuristic.
        let now = date(1_000_000)
        let resetsAt = now.addingTimeInterval(86_400)  // ~Sat next day
        let twoDaysAgo = now.addingTimeInterval(-2 * 86_400)
        let history: [UsageHistoryEntry] = [
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-5 * 86_400), fiveHour: nil, sevenDay: 30),
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-4 * 86_400), fiveHour: nil, sevenDay: 55),
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-3 * 86_400), fiveHour: nil, sevenDay: 65),
            // strict drop here: prev 65% > 40 AND current 0% < 10
            UsageHistoryEntry(id: UUID(), at: twoDaysAgo, fiveHour: nil, sevenDay: 0),
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-86_400), fiveHour: nil, sevenDay: 2),
        ]
        let anchor = UsageTrendChart.resolveCycleStart(
            snapshot: snapshot(resetsAt: resetsAt),
            history: history,
            now: now
        )
        XCTAssertEqual(anchor.cycleStart, twoDaysAgo,
                       "strict drop later than API anchor must win — Kwota's own observation is newer truth")
        XCTAssertTrue(anchor.isHeuristic,
                      "override is inferred; isHeuristic=true surfaces the 'calibrating' suffix")
        XCTAssertTrue(anchor.useAvgLine)
    }

    func testLooseDropDoesNotOverrideApiAnchor() {
        // A 35% → 5% drop satisfies the loose ≥5pp heuristic but NOT the
        // strict prev>40 AND curr<10 threshold (35 is below 40). API
        // anchor wins.
        let now = date(1_000_000)
        let resetsAt = now.addingTimeInterval(3 * 86_400)
        let expectedApiAnchor = resetsAt.addingTimeInterval(-7 * 86_400)
        let history: [UsageHistoryEntry] = [
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-3 * 86_400), fiveHour: nil, sevenDay: 35),
            // loose drop (35→5) but not strict (prev not > 40)
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-2 * 86_400), fiveHour: nil, sevenDay: 5),
        ]
        let anchor = UsageTrendChart.resolveCycleStart(
            snapshot: snapshot(resetsAt: resetsAt),
            history: history,
            now: now
        )
        XCTAssertEqual(anchor.cycleStart, expectedApiAnchor)
        XCTAssertFalse(anchor.isHeuristic)
    }

    func testStrictDropBeforeApiAnchor_doesNotOverride() {
        // Drop happened 10 days ago — before the API's claimed cycle
        // start. That's a previous cycle's reset, not the current one.
        // API anchor wins.
        let now = date(1_000_000)
        let resetsAt = now.addingTimeInterval(2 * 86_400)
        let expectedApiAnchor = resetsAt.addingTimeInterval(-7 * 86_400)
        let history: [UsageHistoryEntry] = [
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-12 * 86_400), fiveHour: nil, sevenDay: 70),
            // strict drop 10 days ago — before this cycle's API anchor
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-10 * 86_400), fiveHour: nil, sevenDay: 2),
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-3 * 86_400), fiveHour: nil, sevenDay: 30),
        ]
        let anchor = UsageTrendChart.resolveCycleStart(
            snapshot: snapshot(resetsAt: resetsAt),
            history: history,
            now: now
        )
        XCTAssertEqual(anchor.cycleStart, expectedApiAnchor)
        XCTAssertFalse(anchor.isHeuristic)
    }

    func testStrictDropInsideGraceWindow_doesNotOverride() {
        // Real-world bug: Mac asleep / app closed during the cycle's
        // normal reset. First post-wake poll lands a few hours after
        // `resets_at - 7d` and records the drop there, so the strict
        // override would falsely fire and stamp the footer with
        // "calibrating" even though the API anchor is correct. The 24h
        // grace window absorbs this: a drop landing 3.5h after the API
        // anchor describes the same reset event.
        let now = date(1_000_000)
        let resetsAt = now.addingTimeInterval(7 * 86_400 - 3 * 3600)
        let apiAnchor = resetsAt.addingTimeInterval(-7 * 86_400)
        let dropAt = apiAnchor.addingTimeInterval(3.5 * 3600)
        let history: [UsageHistoryEntry] = [
            UsageHistoryEntry(id: UUID(), at: apiAnchor.addingTimeInterval(-2 * 86_400), fiveHour: nil, sevenDay: 86),
            UsageHistoryEntry(id: UUID(), at: dropAt, fiveHour: nil, sevenDay: 2),
        ]
        let anchor = UsageTrendChart.resolveCycleStart(
            snapshot: snapshot(resetsAt: resetsAt),
            history: history,
            now: now
        )
        XCTAssertEqual(anchor.cycleStart, apiAnchor,
                       "drop inside the 24h grace describes the same reset as the API anchor — trust the API value")
        XCTAssertFalse(anchor.isHeuristic, "API-anchored cycle must not surface 'calibrating'")
        XCTAssertTrue(anchor.useAvgLine)
    }

    func testStrictDropJustOutsideGraceWindow_overrides() {
        // Drop landing 25h after the API anchor is too far from the
        // reset moment to be polling lag — treat it as a real mid-cycle
        // recalibration and let the override fire.
        let now = date(1_000_000)
        let resetsAt = now.addingTimeInterval(7 * 86_400 - 26 * 3600)
        let apiAnchor = resetsAt.addingTimeInterval(-7 * 86_400)
        let dropAt = apiAnchor.addingTimeInterval(25 * 3600)
        let history: [UsageHistoryEntry] = [
            UsageHistoryEntry(id: UUID(), at: apiAnchor.addingTimeInterval(-2 * 86_400), fiveHour: nil, sevenDay: 80),
            UsageHistoryEntry(id: UUID(), at: dropAt, fiveHour: nil, sevenDay: 4),
        ]
        let anchor = UsageTrendChart.resolveCycleStart(
            snapshot: snapshot(resetsAt: resetsAt),
            history: history,
            now: now
        )
        XCTAssertEqual(anchor.cycleStart, dropAt)
        XCTAssertTrue(anchor.isHeuristic)
        XCTAssertTrue(anchor.useAvgLine)
    }

    func testStrictDropWithoutResetsAt_fallsThroughToLooseHeuristic() {
        // When resets_at is nil entirely, the new strict branch can't
        // fire (it requires the API anchor to compare against). The
        // existing loose heuristic (≥5pp) takes over instead.
        let now = date(1_000_000)
        let twoDaysAgo = now.addingTimeInterval(-2 * 86_400)
        let history: [UsageHistoryEntry] = [
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-3 * 86_400), fiveHour: nil, sevenDay: 60),
            UsageHistoryEntry(id: UUID(), at: twoDaysAgo, fiveHour: nil, sevenDay: 5),
        ]
        let anchor = UsageTrendChart.resolveCycleStart(
            snapshot: snapshot(resetsAt: nil),
            history: history,
            now: now
        )
        XCTAssertEqual(anchor.cycleStart, twoDaysAgo)
        XCTAssertTrue(anchor.isHeuristic)
    }

    // MARK: - latestRecalibrationStart / isRecalibrationActive

    func testRecalibrationDetectedOnLargeMidCycleDrop() {
        let now = Date()
        let drop = now.addingTimeInterval(-1 * 3600)
        let history = [
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-3 * 3600), fiveHour: nil, sevenDay: 84),
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-2 * 3600), fiveHour: nil, sevenDay: 87),
            UsageHistoryEntry(id: UUID(), at: drop,                              fiveHour: nil, sevenDay: 58),
        ]
        XCTAssertEqual(UsageTrendChart.latestRecalibrationStart(in: history), drop)
    }

    func testNoRecalibrationWhenDropBelowThreshold() {
        let now = Date()
        let history = [
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-2 * 3600), fiveHour: nil, sevenDay: 87),
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-1 * 3600), fiveHour: nil, sevenDay: 80),
        ]
        XCTAssertNil(UsageTrendChart.latestRecalibrationStart(in: history))
    }

    func testResetIsNotRecalibration() {
        let now = Date()
        let history = [
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-2 * 3600), fiveHour: nil, sevenDay: 50),
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-1 * 3600), fiveHour: nil, sevenDay: 5),
        ]
        XCTAssertNil(UsageTrendChart.latestRecalibrationStart(in: history))
    }

    func testMonotonicIncreaseHasNoRecalibration() {
        let now = Date()
        let history = [
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-2 * 3600), fiveHour: nil, sevenDay: 40),
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-1 * 3600), fiveHour: nil, sevenDay: 60),
        ]
        XCTAssertNil(UsageTrendChart.latestRecalibrationStart(in: history))
    }

    func testReturnsLatestRecalibrationWhenMultiple() {
        let now = Date()
        let latestDrop = now.addingTimeInterval(-2 * 3600)
        let history = [
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-5 * 3600), fiveHour: nil, sevenDay: 80),
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-4 * 3600), fiveHour: nil, sevenDay: 55), // drop 25
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-3 * 3600), fiveHour: nil, sevenDay: 90),
            UsageHistoryEntry(id: UUID(), at: latestDrop,                        fiveHour: nil, sevenDay: 60), // drop 30
        ]
        XCTAssertEqual(UsageTrendChart.latestRecalibrationStart(in: history), latestDrop)
    }

    func testRecalibrationAtExactThresholdBoundaryIsDetected() {
        let now = Date()
        let drop = now.addingTimeInterval(-1 * 3600)
        let history = [
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-2 * 3600), fiveHour: nil, sevenDay: 25),
            UsageHistoryEntry(id: UUID(), at: drop,                              fiveHour: nil, sevenDay: 10), // drop exactly 15, current exactly 10
        ]
        XCTAssertEqual(UsageTrendChart.latestRecalibrationStart(in: history), drop)
    }

    func testRecalibrationJustBelowDropThresholdIsIgnored() {
        let now = Date()
        let history = [
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-2 * 3600), fiveHour: nil, sevenDay: 24),
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-1 * 3600), fiveHour: nil, sevenDay: 10), // drop 14 (< 15)
        ]
        XCTAssertNil(UsageTrendChart.latestRecalibrationStart(in: history))
    }

    func testRecalibrationJustBelowCurrentFloorIsIgnored() {
        let now = Date()
        let history = [
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-2 * 3600), fiveHour: nil, sevenDay: 50),
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-1 * 3600), fiveHour: nil, sevenDay: 9), // current 9 (< 10) → reset territory
        ]
        XCTAssertNil(UsageTrendChart.latestRecalibrationStart(in: history))
    }

    func testRecalibrationActiveWhenWithinCurrentCycle() {
        let now = Date()
        let cycleStart = now.addingTimeInterval(-7 * 86_400)
        let history = [
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-2 * 3600), fiveHour: nil, sevenDay: 87),
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-1 * 3600), fiveHour: nil, sevenDay: 58),
        ]
        XCTAssertTrue(UsageTrendChart.isRecalibrationActive(history: history, cycleStart: cycleStart))
    }

    func testRecalibrationInactiveWhenBeforeCurrentCycle() {
        let now = Date()
        let cycleStart = now.addingTimeInterval(-1 * 3600) // cycle started AFTER the drop
        let history = [
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-3 * 3600), fiveHour: nil, sevenDay: 87),
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-2 * 3600), fiveHour: nil, sevenDay: 58),
        ]
        XCTAssertFalse(UsageTrendChart.isRecalibrationActive(history: history, cycleStart: cycleStart))
    }

    // F-001 live repro: a normal weekly reset that fell into a multi-day
    // sampling gap (app closed / Mac asleep). The pre-gap sample (69%)
    // predates the current cycle; the post-gap sample (44%) is the first
    // reading of the new cycle. This is a reset, NOT a mid-cycle
    // recalibration — the drop only looks like one because the gap hid the
    // intervening reset. Because `prev` predates `cycleStart`, the drop must
    // not be counted.
    func testRecalibrationInactiveWhenPrevSamplePredatesCycle() {
        let now = Date()
        let cycleStart = now.addingTimeInterval(-6 * 86_400) // new cycle started after the 69% sample
        let history = [
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-7 * 86_400), fiveHour: nil, sevenDay: 69), // before cycle
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-1 * 86_400), fiveHour: nil, sevenDay: 44), // first sample of new cycle
        ]
        XCTAssertFalse(UsageTrendChart.isRecalibrationActive(history: history, cycleStart: cycleStart))
    }

    // A genuine mid-cycle cap change: both samples land inside the current
    // cycle, so the recalibration is real and must still be detected.
    func testRecalibrationActiveWhenBothSamplesInCycle() {
        let now = Date()
        let cycleStart = now.addingTimeInterval(-3 * 86_400)
        let history = [
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-2 * 86_400), fiveHour: nil, sevenDay: 80), // in cycle
            UsageHistoryEntry(id: UUID(), at: now.addingTimeInterval(-1 * 86_400), fiveHour: nil, sevenDay: 55), // in cycle, drop 25
        ]
        XCTAssertTrue(UsageTrendChart.isRecalibrationActive(history: history, cycleStart: cycleStart))
    }
}
