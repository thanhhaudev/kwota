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
}
