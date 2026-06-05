//  AntigravityCreditCycleTests.swift
//  KwotaTests

import XCTest
@testable import Kwota

final class AntigravityCreditCycleTests: XCTestCase {
    private func reading(_ wallet: Int64, _ ceiling: Int64) -> CreditCycleReading {
        CreditCycleReading(wallet: wallet, ceiling: ceiling)
    }

    func test_detectsReset_whenConsumedBalanceJumpsBackToFull() {
        // 50/1000 (heavily consumed) → 950/1000 (refilled). Same ceiling.
        XCTAssertTrue(didCreditCycleReset(previous: reading(50, 1000),
                                          current: reading(950, 1000)))
    }

    func test_noReset_onFirstObservation() {
        XCTAssertFalse(didCreditCycleReset(previous: nil, current: reading(950, 1000)))
    }

    /// Codex's scenario: a plan upgrade changes the ceiling. On utilization
    /// this looks like a huge drop (80% → 4% consumed), but the ceiling moved
    /// so it is NOT a reset. The raw-wallet detector rejects it.
    func test_noReset_whenCeilingChanged_evenIfUtilizationDropsToNearZero() {
        // Pro: 200/1000 → util 80. Upgrade to Ultra: 4800/5000 → util 4.
        XCTAssertFalse(didCreditCycleReset(previous: reading(200, 1000),
                                           current: reading(4800, 5000)))
    }

    func test_noReset_onMidCycleTopUp_thatDoesNotReachNearFull() {
        // 100/1000 → 500/1000: jumped up but only to 50%, not a reset.
        XCTAssertFalse(didCreditCycleReset(previous: reading(100, 1000),
                                           current: reading(500, 1000)))
    }

    func test_noReset_onSmallJump_belowThreshold() {
        // 880/1000 → 950/1000: lands near-full but the jump is only 7 pts.
        XCTAssertFalse(didCreditCycleReset(previous: reading(880, 1000),
                                           current: reading(950, 1000)))
    }

    func test_noReset_whenBalanceDecreases() {
        XCTAssertFalse(didCreditCycleReset(previous: reading(900, 1000),
                                           current: reading(300, 1000)))
    }

    func test_noReset_whenCeilingZeroOrMissing() {
        XCTAssertFalse(didCreditCycleReset(previous: reading(0, 0),
                                           current: reading(0, 0)))
    }
}
