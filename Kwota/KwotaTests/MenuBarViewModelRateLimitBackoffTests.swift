//
//  MenuBarViewModelRateLimitBackoffTests.swift
//  KwotaTests
//
//  Pure-logic tests for the exponential fallback schedule applied when
//  Anthropic returns 429 without a usable Retry-After header. The schedule
//  is owned by MenuBarViewModel.fallbackBackoff(forConsecutiveCount:) — a
//  static helper so we can verify each step independently of the refresh
//  plumbing (init double-fire, Task generations, async waits).
//
//  The integration side (increment on silent 429, reset on success, do
//  NOT advance counter on explicit Retry-After) is enforced inline at the
//  catch site and verified by reading the diff during review.
//

import XCTest
@testable import Kwota

final class MenuBarViewModelRateLimitBackoffTests: XCTestCase {

    func testFirst429FallsBackToOneMinute() {
        XCTAssertEqual(MenuBarViewModel.fallbackBackoff(forConsecutiveCount: 1), 60)
    }

    func testSecondConsecutiveDoublesToTwoMinutes() {
        XCTAssertEqual(MenuBarViewModel.fallbackBackoff(forConsecutiveCount: 2), 120)
    }

    func testThirdConsecutiveDoublesToFourMinutes() {
        XCTAssertEqual(MenuBarViewModel.fallbackBackoff(forConsecutiveCount: 3), 240)
    }

    func testFourthConsecutiveClampsAtFiveMinuteCap() {
        // Raw formula gives 60 * 8 = 480s; cap pulls it back to 300.
        XCTAssertEqual(MenuBarViewModel.fallbackBackoff(forConsecutiveCount: 4), 300)
    }

    func testManyConsecutiveStaysAtFiveMinuteCap() {
        // Cap holds for arbitrarily large counts — no overflow, no drift.
        XCTAssertEqual(MenuBarViewModel.fallbackBackoff(forConsecutiveCount: 10), 300)
        XCTAssertEqual(MenuBarViewModel.fallbackBackoff(forConsecutiveCount: 100), 300)
    }

    func testZeroOrNegativeCountDefaultsToOneMinute() {
        // Defensive: a caller that hasn't incremented yet shouldn't blow up.
        XCTAssertEqual(MenuBarViewModel.fallbackBackoff(forConsecutiveCount: 0), 60)
        XCTAssertEqual(MenuBarViewModel.fallbackBackoff(forConsecutiveCount: -1), 60)
    }

    func testScheduleIsMonotonicNonDecreasing() {
        // Belt-and-braces invariant: stepping forward in the schedule must
        // never *decrease* the backoff. If a regression introduces a
        // misplaced min/max the per-step tests above will fail first, but
        // this catches a wider class of subtle off-by-one bugs.
        var previous: TimeInterval = 0
        for n in 1...20 {
            let next = MenuBarViewModel.fallbackBackoff(forConsecutiveCount: n)
            XCTAssertGreaterThanOrEqual(next, previous, "schedule must not decrease at step \(n)")
            previous = next
        }
    }
}
