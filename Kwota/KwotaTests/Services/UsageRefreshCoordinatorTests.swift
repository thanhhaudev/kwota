//
//  UsageRefreshCoordinatorTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class UsageRefreshCoordinatorTests: XCTestCase {
    func testFiresImmediatelyOnStart() async throws {
        var fireCount = 0
        // Long intervals + zero jitter so the only fire we observe within
        // 50ms is the synchronous one from start().
        let coord = UsageRefreshCoordinator(
            openInterval: 600,
            closedInterval: 600,
            jitterFraction: 0,
            onTick: { fireCount += 1 }
        )
        coord.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fireCount, 1)
        coord.stop()
    }

    func testIntervalChangesWhenPopoverOpens() async throws {
        let coord = UsageRefreshCoordinator(jitterFraction: 0, onTick: {})
        coord.start()
        XCTAssertEqual(coord.currentInterval, coord.closedInterval)
        coord.popoverDidOpen()
        XCTAssertEqual(coord.currentInterval, coord.openInterval)
        coord.popoverDidClose()
        XCTAssertEqual(coord.currentInterval, coord.closedInterval)
        coord.stop()
    }

    func testDefaultOpenIntervalIsOneMinute() {
        // Cadence bump: 30s → 60s to halve baseline call volume. If you change
        // this, also update the ban-risk note in ClaudeAPIClient.swift.
        let coord = UsageRefreshCoordinator(onTick: {})
        XCTAssertEqual(coord.openInterval, 60)
    }

    // MARK: - Jitter

    func testJitterAppliesSymmetricFractionToBaseInterval() {
        // randomUnit()=0 → -jitterFraction → 0.8 * base
        let low = UsageRefreshCoordinator(
            openInterval: 100,
            closedInterval: 600,
            jitterFraction: 0.2,
            randomUnit: { 0 },
            onTick: {}
        )
        XCTAssertEqual(low.nextDelay(), 480, accuracy: 0.001)  // 0.8 * 600

        // randomUnit()=0.999... → +jitterFraction → 1.2 * base
        let high = UsageRefreshCoordinator(
            openInterval: 100,
            closedInterval: 600,
            jitterFraction: 0.2,
            randomUnit: { 0.999999 },
            onTick: {}
        )
        XCTAssertEqual(high.nextDelay(), 720, accuracy: 0.01)  // 1.2 * 600

        // randomUnit()=0.5 → 0 jitter → base
        let mid = UsageRefreshCoordinator(
            openInterval: 100,
            closedInterval: 600,
            jitterFraction: 0.2,
            randomUnit: { 0.5 },
            onTick: {}
        )
        XCTAssertEqual(mid.nextDelay(), 600, accuracy: 0.001)
    }

    func testZeroJitterFractionDisablesRandomness() {
        let coord = UsageRefreshCoordinator(
            openInterval: 60,
            closedInterval: 600,
            jitterFraction: 0,
            // Even if randomUnit is non-zero, jitter must not apply.
            randomUnit: { 0.7 },
            onTick: {}
        )
        XCTAssertEqual(coord.nextDelay(), 600)
    }

    func testNextDelayUsesEarlierResetWakeDate() {
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        let coord = UsageRefreshCoordinator(
            openInterval: 60,
            closedInterval: 600,
            jitterFraction: 0,
            now: { baseTime },
            randomUnit: { 0.5 },
            onTick: {}
        )

        coord.scheduleResetWake(at: baseTime.addingTimeInterval(45))

        XCTAssertEqual(
            coord.nextDelay(), 45,
            "known quota reset must wake the refresh loop before the closed-popover cadence"
        )
    }

    func testResetWakeFiresOnceWithoutImmediateDoubleTick() async throws {
        var fireCount = 0
        let coord = UsageRefreshCoordinator(
            openInterval: 10,
            closedInterval: 10,
            jitterFraction: 0,
            now: Date.init,
            randomUnit: { 0.5 },
            onTick: { fireCount += 1 }
        )

        coord.start()
        coord.scheduleResetWake(at: Date().addingTimeInterval(0.05))
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(
            fireCount,
            2,
            "reset wake should produce the start tick and one reset tick, then resume normal cadence"
        )
        coord.stop()
    }

    // MARK: - Back-off floor (per-provider)

    /// applyRetryAfter records a per-provider floor without affecting the
    /// shared timer's interval — gating happens in MenuBarViewModel.
    /// canRefreshNow when the tick fires. This keeps non-throttled
    /// providers ticking on schedule even while one provider is locked
    /// out.
    func testApplyRetryAfterDoesNotClampTimerInterval() {
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        let coord = UsageRefreshCoordinator(
            openInterval: 60,
            closedInterval: 600,
            jitterFraction: 0,
            now: { baseTime },
            randomUnit: { 0.5 },
            onTick: {}
        )
        coord.popoverDidOpen()  // base = 60s
        XCTAssertEqual(coord.nextDelay(), 60)

        coord.applyRetryAfter(180, for: .claude)
        // The floor is recorded for the Claude bucket, but the timer's
        // delay stays at the base interval — Antigravity / Codex
        // refreshes must keep ticking even while Claude is throttled.
        XCTAssertEqual(coord.nextDelay(), 60,
                       "scheduler must ignore the shared floor; per-provider gating runs in canRefreshNow")
        XCTAssertEqual(coord.backoffUntil(for: .claude),
                       baseTime.addingTimeInterval(180))
    }

    func testApplyRetryAfterDoesNotShortenLongerExistingFloor() {
        // If the server tells us 300s back-off and then 30s back-off shortly
        // after, we keep the longer per-provider floor.
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        let coord = UsageRefreshCoordinator(
            openInterval: 60,
            closedInterval: 600,
            jitterFraction: 0,
            now: { baseTime },
            randomUnit: { 0.5 },
            onTick: {}
        )
        coord.popoverDidOpen()
        coord.applyRetryAfter(300, for: .claude)
        coord.applyRetryAfter(30, for: .claude)
        XCTAssertEqual(coord.backoffUntil(for: .claude),
                       baseTime.addingTimeInterval(300))
    }

    func testApplyRetryAfterClampsNegativeToZero() {
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        let coord = UsageRefreshCoordinator(
            openInterval: 60,
            closedInterval: 600,
            jitterFraction: 0,
            now: { baseTime },
            randomUnit: { 0.5 },
            onTick: {}
        )
        coord.applyRetryAfter(-5, for: .claude)
        // Negative seconds → floor pinned to `now()` (not in the future).
        XCTAssertEqual(coord.backoffUntil(for: .claude), baseTime)
        // Scheduler runs at base interval regardless.
        XCTAssertEqual(coord.nextDelay(), 600)
    }

    // MARK: - Per-provider floors

    func test_perProviderFloor_isolatesAntigravityFromClaude() {
        // The bug this guards against: a Claude 429 used to gate every
        // provider's refresh because backoffUntil was one global field.
        // Now Antigravity (loopback, no rate limit) must NOT see Claude's
        // floor — its `backoffUntil(for:)` returns nil even after Claude
        // applyRetryAfter.
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        let coord = UsageRefreshCoordinator(
            openInterval: 60, closedInterval: 600, jitterFraction: 0,
            now: { baseTime }, randomUnit: { 0.5 }, onTick: {}
        )
        coord.applyRetryAfter(60, for: .claude)
        XCTAssertNotNil(coord.backoffUntil(for: .claude))
        XCTAssertNil(coord.backoffUntil(for: .antigravity),
                     "Antigravity must not inherit Claude's 429 floor")
        XCTAssertNil(coord.backoffUntil(for: .codex),
                     "Codex must not inherit Claude's 429 floor")
    }

    // MARK: - setIntervals

    func test_setIntervals_updatesOpenAndClosed() {
        let coord = UsageRefreshCoordinator(
            openInterval: 60, closedInterval: 600, jitterFraction: 0, onTick: {}
        )
        coord.setIntervals(open: 120, closed: 1800)
        XCTAssertEqual(coord.openInterval, 120)
        XCTAssertEqual(coord.closedInterval, 1800)
    }

    func test_setIntervals_preservesClosedCadenceState() {
        let coord = UsageRefreshCoordinator(
            openInterval: 60, closedInterval: 600, jitterFraction: 0, onTick: {}
        )
        // Popover is closed at launch — currentInterval starts at closed.
        XCTAssertEqual(coord.currentInterval, 600)
        coord.setIntervals(open: 120, closed: 1800)
        // Still closed → currentInterval flips to the new closed value.
        XCTAssertEqual(coord.currentInterval, 1800)
    }

    func test_setIntervals_preservesOpenCadenceState() {
        let coord = UsageRefreshCoordinator(
            openInterval: 60, closedInterval: 600, jitterFraction: 0, onTick: {}
        )
        coord.popoverDidOpen()
        XCTAssertEqual(coord.currentInterval, 60)
        coord.setIntervals(open: 120, closed: 1800)
        // Was open → currentInterval flips to the new open value, not closed.
        XCTAssertEqual(coord.currentInterval, 120)
    }

    // MARK: - clearBackoff

    func test_clearBackoff_dropsOnlyThatProvidersFloor() {
        // A successful fetch (e.g. the RateLimitBanner's "Try now" probe
        // landing a 200) proves the server is serving us again — the floor
        // recorded from the earlier 429 must be droppable so the auto
        // cadence resumes instead of waiting out a stale Retry-After.
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        let coord = UsageRefreshCoordinator(
            openInterval: 60, closedInterval: 600, jitterFraction: 0,
            now: { baseTime }, randomUnit: { 0.5 }, onTick: {}
        )
        coord.applyRetryAfter(2400, for: .claude)
        coord.applyRetryAfter(120, for: .codex)

        coord.clearBackoff(for: .claude)

        XCTAssertNil(coord.backoffUntil(for: .claude),
                     "clearBackoff must drop the Claude floor")
        XCTAssertEqual(coord.backoffUntil(for: .codex),
                       baseTime.addingTimeInterval(120),
                       "other providers' floors must survive")
    }

    func test_clearBackoff_isNoOp_whenNoFloorRecorded() {
        let coord = UsageRefreshCoordinator(
            openInterval: 60, closedInterval: 600, jitterFraction: 0, onTick: {}
        )
        coord.clearBackoff(for: .claude)
        XCTAssertNil(coord.backoffUntil(for: .claude))
        XCTAssertNil(coord.backoffUntil)
    }

    func test_perProviderFloor_eachProviderTracksIndependently() {
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        let coord = UsageRefreshCoordinator(
            openInterval: 60, closedInterval: 600, jitterFraction: 0,
            now: { baseTime }, randomUnit: { 0.5 }, onTick: {}
        )
        coord.applyRetryAfter(60, for: .claude)
        coord.applyRetryAfter(120, for: .codex)
        XCTAssertEqual(
            coord.backoffUntil(for: .claude),
            baseTime.addingTimeInterval(60)
        )
        XCTAssertEqual(
            coord.backoffUntil(for: .codex),
            baseTime.addingTimeInterval(120)
        )
        // Global max = latest of the two, used for timer scheduling.
        XCTAssertEqual(coord.backoffUntil, baseTime.addingTimeInterval(120))
    }
}
