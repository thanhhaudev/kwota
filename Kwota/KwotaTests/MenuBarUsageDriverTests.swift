//
//  MenuBarUsageDriverTests.swift
//  KwotaTests
//

import XCTest
import SwiftUI
@testable import Kwota

final class MenuBarUsageDriverTests: XCTestCase {

    private func makeSummary(primary: Double?, secondary: Double?) -> ProviderUsageSummary {
        let now = Date()
        let p = UsageBucket(utilization: primary, resetsAt: now.addingTimeInterval(3600))
        let s = UsageBucket(utilization: secondary, resetsAt: now.addingTimeInterval(86400))
        return ProviderUsageSummary(
            providerID: .claude,
            fetchedAt: now,
            primary: primary == nil ? nil : p,
            secondary: secondary == nil ? nil : s,
            payload: 0
        )
    }

    func test_nilSummary_returnsNoUtilization() {
        let r = MenuBarUsageDriver.read(summary: nil, source: .session)
        XCTAssertNil(r.utilization)
    }

    func test_session_readsPrimary() {
        let r = MenuBarUsageDriver.read(summary: makeSummary(primary: 42, secondary: 70), source: .session)
        XCTAssertEqual(r.utilization, 42)
    }

    func test_weekly_readsSecondary() {
        let r = MenuBarUsageDriver.read(summary: makeSummary(primary: 42, secondary: 70), source: .weekly)
        XCTAssertEqual(r.utilization, 70)
    }

    func test_higher_returnsMaxOfBoth() {
        let r = MenuBarUsageDriver.read(summary: makeSummary(primary: 42, secondary: 70), source: .higher)
        XCTAssertEqual(r.utilization, 70)
    }

    func test_higher_handlesNilSide() {
        let r1 = MenuBarUsageDriver.read(summary: makeSummary(primary: 42, secondary: nil), source: .higher)
        XCTAssertEqual(r1.utilization, 42)

        let r2 = MenuBarUsageDriver.read(summary: makeSummary(primary: nil, secondary: 30), source: .higher)
        XCTAssertEqual(r2.utilization, 30)

        let r3 = MenuBarUsageDriver.read(summary: makeSummary(primary: nil, secondary: nil), source: .higher)
        XCTAssertNil(r3.utilization)
    }

    func test_tint_matchesUsageLevelTiers() {
        let low    = MenuBarUsageDriver.read(summary: makeSummary(primary: 50, secondary: nil), source: .session).tint
        let mid    = MenuBarUsageDriver.read(summary: makeSummary(primary: 70, secondary: nil), source: .session).tint
        let high   = MenuBarUsageDriver.read(summary: makeSummary(primary: 90, secondary: nil), source: .session).tint
        XCTAssertEqual(low,  Color.green)
        XCTAssertEqual(mid,  Color.yellow)
        XCTAssertEqual(high, Color.red)
    }

    func test_remainingFraction_nil_returnsZero() {
        XCTAssertEqual(MenuBarUsageDriver.remainingFraction(for: nil), 0)
    }

    func test_remainingFraction_negative_clampsToFull() {
        XCTAssertEqual(MenuBarUsageDriver.remainingFraction(for: -10), 1)
    }

    func test_remainingFraction_zero_isFull() {
        XCTAssertEqual(MenuBarUsageDriver.remainingFraction(for: 0), 1)
    }

    func test_remainingFraction_fifty_isHalf() {
        XCTAssertEqual(MenuBarUsageDriver.remainingFraction(for: 50), 0.5)
    }

    func test_remainingFraction_hundred_isEmpty() {
        XCTAssertEqual(MenuBarUsageDriver.remainingFraction(for: 100), 0)
    }

    func test_remainingFraction_overHundred_clampsToEmpty() {
        XCTAssertEqual(MenuBarUsageDriver.remainingFraction(for: 150), 0)
    }
}
