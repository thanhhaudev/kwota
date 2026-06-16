//  RenewalEstimatorTests.swift
//  KwotaTests

import XCTest
@testable import Kwota

final class RenewalEstimatorTests: XCTestCase {
    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    // MARK: - next(after:now:)

    func test_next_rollsForwardToFirstFutureAnniversary() {
        let start = date("2026-01-10T00:00:00Z")
        let now   = date("2026-05-29T00:00:00Z")
        let next  = RenewalEstimator.next(after: start, now: now)
        XCTAssertEqual(next, date("2026-06-10T00:00:00Z"))
    }

    func test_next_returnsFutureAnchorUnchanged() {
        let start = date("2026-08-01T00:00:00Z")
        let now   = date("2026-05-29T00:00:00Z")
        XCTAssertEqual(RenewalEstimator.next(after: start, now: now), start)
    }

    // MARK: - subscription(for:now:)

    func test_subscription_prefersExplicitRenewsAt() {
        var p = Profile(name: "p", authMethod: .cliSync)
        p.subscriptionRenewsAt = date("2026-06-15T00:00:00Z")
        p.subscriptionCreatedAt = date("2026-01-01T00:00:00Z")
        XCTAssertEqual(RenewalEstimator.subscription(for: p, now: date("2026-05-29T00:00:00Z")),
                       date("2026-06-15T00:00:00Z"))
    }

    func test_subscription_monthlyFromCreatedWhenNoExplicit() {
        var p = Profile(name: "p", authMethod: .cliSync)
        p.subscriptionCreatedAt = date("2026-01-10T00:00:00Z")
        XCTAssertEqual(RenewalEstimator.subscription(for: p, now: date("2026-05-29T00:00:00Z")),
                       date("2026-06-10T00:00:00Z"))
    }

    func test_subscription_nilWhenNoAnchors() {
        let p = Profile(name: "p", authMethod: .cliSync)
        XCTAssertNil(RenewalEstimator.subscription(for: p, now: Date()))
    }

    // MARK: - adopt(detected:over:)

    func test_adopt_firstObservation() {
        let d = date("2026-05-01T00:00:00Z")
        XCTAssertEqual(RenewalEstimator.adopt(detected: d, over: nil), d)
    }

    func test_adopt_newerWins() {
        let stored = date("2026-04-01T00:00:00Z")
        let newer  = date("2026-05-01T00:00:00Z")
        XCTAssertEqual(RenewalEstimator.adopt(detected: newer, over: stored), newer)
    }

    func test_adopt_notNewerOrNilLeavesUnchanged() {
        let stored = date("2026-05-01T00:00:00Z")
        XCTAssertNil(RenewalEstimator.adopt(detected: stored, over: stored))      // equal → no change
        XCTAssertNil(RenewalEstimator.adopt(detected: date("2026-04-01T00:00:00Z"), over: stored))
        XCTAssertNil(RenewalEstimator.adopt(detected: nil, over: stored))
    }

    // MARK: - display strings

    func test_subtitleString_absolute() {
        let est = RenewalEstimate(date: date("2026-06-18T00:00:00Z"),
                                  prefix: "Est. resets", absolute: true)
        XCTAssertEqual(RenewalEstimator.subtitleString(est), "Est. resets 18 Jun 2026")
    }

    // MARK: - daysRelative sub-day resolution

    func test_daysRelative_imminentFutureReset_showsHours() {
        let now = date("2026-06-16T10:00:00Z")
        XCTAssertEqual(
            RenewalEstimator.daysRelative(from: now, to: now.addingTimeInterval(3 * 3_600)),
            "in 3h")
    }

    func test_daysRelative_underAnHour_showsMinutes() {
        let now = date("2026-06-16T10:00:00Z")
        XCTAssertEqual(
            RenewalEstimator.daysRelative(from: now, to: now.addingTimeInterval(20 * 60)),
            "in 20m")
    }

    func test_daysRelative_multiDayReset_staysDayGranular() {
        let now = date("2026-06-16T10:00:00Z")
        XCTAssertEqual(
            RenewalEstimator.daysRelative(from: now, to: now.addingTimeInterval(3 * 86_400)),
            "in 3 days")
    }

    func test_daysRelative_pastSameDay_stillToday() {
        let now = date("2026-06-16T10:00:00Z")
        XCTAssertEqual(
            RenewalEstimator.daysRelative(from: now, to: now.addingTimeInterval(-2 * 3_600)),
            "today")
    }

    func test_subtitleString_relativePrefixOnly() {
        // Relative wording is locale/clock-dependent; assert the prefix and
        // that no absolute date leaks in.
        let est = RenewalEstimate(date: Date().addingTimeInterval(7200),
                                  prefix: "Resets", absolute: false)
        let s = RenewalEstimator.subtitleString(est)
        XCTAssertTrue(s.hasPrefix("Resets "), s)
        XCTAssertFalse(s.contains("Est."), s)
    }
}
