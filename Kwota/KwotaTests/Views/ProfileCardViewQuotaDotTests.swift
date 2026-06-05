//
//  ProfileCardViewQuotaDotTests.swift
//  KwotaTests
//
//  Locks the quota-tier color mapping used by ProfileSwitcherCard for
//  the avatar status dot. The mapping is the shared source of truth
//  between the header card (active profile summary) and the list-card
//  rows (per-row coordinator summary), so the table here is the
//  contract both call sites depend on.
//
//  After the row-tint-palette unification round, the dot delegates to
//  MenuBarUsageDriver so its palette (green/yellow/red), thresholds
//  (60/80), and bucket selection (configurable via MenuBarUsageSource)
//  match the menu-bar icon's fill background. The .higher source is
//  used for the threshold tests to preserve the historical max-bucket
//  semantics; per-source behavior is exercised in the source-driven
//  selection tests at the bottom.
//

import XCTest
import SwiftUI
@testable import Kwota

@MainActor
final class ProfileCardViewQuotaDotTests: XCTestCase {
    // MARK: - Fixture

    private func summary(primary: Double?, secondary: Double?) -> ProviderUsageSummary {
        ProviderUsageSummary(
            providerID: .claude,
            fetchedAt: Date(),
            primary: UsageBucket(utilization: primary, resetsAt: nil),
            secondary: UsageBucket(utilization: secondary, resetsAt: nil),
            payload: UsageSnapshot.zeroes()
        )
    }

    // MARK: - Nil cases (no dot)

    func test_nilSummary_returnsNil() {
        XCTAssertNil(ProfileSwitcherCard.quotaDotColor(for: nil, source: .higher))
    }

    func test_bothBucketsNil_returnsNil() {
        let s = ProviderUsageSummary(
            providerID: .claude,
            fetchedAt: Date(),
            primary: nil,
            secondary: nil,
            payload: UsageSnapshot.zeroes()
        )
        XCTAssertNil(ProfileSwitcherCard.quotaDotColor(for: s, source: .higher))
    }

    func test_bothUtilizationsNil_returnsNil() {
        let s = summary(primary: nil, secondary: nil)
        XCTAssertNil(ProfileSwitcherCard.quotaDotColor(for: s, source: .higher))
    }

    // MARK: - Green (< 60)

    func test_lowUtilization_returnsGreen() {
        let s = summary(primary: 30, secondary: 20)
        XCTAssertEqual(ProfileSwitcherCard.quotaDotColor(for: s, source: .higher), .green)
    }

    func test_zero_returnsGreen() {
        let s = summary(primary: 0, secondary: 0)
        XCTAssertEqual(ProfileSwitcherCard.quotaDotColor(for: s, source: .higher), .green)
    }

    func test_justUnder60_returnsGreen() {
        let s = summary(primary: 59.9, secondary: 10)
        XCTAssertEqual(ProfileSwitcherCard.quotaDotColor(for: s, source: .higher), .green)
    }

    func test_at50_returnsGreen() {
        // Old threshold flipped 50 to .orange; new threshold (60) puts 50
        // back in the green tier. Locked so a future regression toward the
        // 50% split fails this test.
        let s = summary(primary: 50, secondary: 20)
        XCTAssertEqual(ProfileSwitcherCard.quotaDotColor(for: s, source: .higher), .green)
    }

    // MARK: - Yellow (60 ≤ x < 80)

    func test_at60_returnsYellow() {
        let s = summary(primary: 60, secondary: 20)
        XCTAssertEqual(ProfileSwitcherCard.quotaDotColor(for: s, source: .higher), .yellow)
    }

    func test_midRange_returnsYellow() {
        let s = summary(primary: 70, secondary: 40)
        XCTAssertEqual(ProfileSwitcherCard.quotaDotColor(for: s, source: .higher), .yellow)
    }

    func test_justUnder80_returnsYellow() {
        let s = summary(primary: 79.9, secondary: 10)
        XCTAssertEqual(ProfileSwitcherCard.quotaDotColor(for: s, source: .higher), .yellow)
    }

    // MARK: - Red (≥ 80)

    func test_at80_returnsRed() {
        let s = summary(primary: 80, secondary: 10)
        XCTAssertEqual(ProfileSwitcherCard.quotaDotColor(for: s, source: .higher), .red)
    }

    func test_high_returnsRed() {
        let s = summary(primary: 90, secondary: 10)
        XCTAssertEqual(ProfileSwitcherCard.quotaDotColor(for: s, source: .higher), .red)
    }

    // MARK: - Max wins (source: .higher)

    func test_secondaryDominates_returnsRed() {
        let s = summary(primary: 10, secondary: 85)
        XCTAssertEqual(ProfileSwitcherCard.quotaDotColor(for: s, source: .higher), .red)
    }

    func test_primaryNilSecondary40_returnsGreen() {
        let s = summary(primary: nil, secondary: 40)
        XCTAssertEqual(ProfileSwitcherCard.quotaDotColor(for: s, source: .higher), .green)
    }

    func test_primary85SecondaryNil_returnsRed() {
        let s = summary(primary: 85, secondary: nil)
        XCTAssertEqual(ProfileSwitcherCard.quotaDotColor(for: s, source: .higher), .red)
    }

    // MARK: - Source-driven bucket selection

    func test_quotaDot_sessionSource_picksPrimary() {
        // Primary 70 → yellow tier. Secondary 10 would be green if it were
        // consulted; .session must consult primary only.
        let s = summary(primary: 70, secondary: 10)
        XCTAssertEqual(ProfileSwitcherCard.quotaDotColor(for: s, source: .session), .yellow)
    }

    func test_quotaDot_weeklySource_picksSecondary() {
        // Secondary 85 → red tier. Primary 10 would be green if consulted;
        // .weekly must consult secondary only.
        let s = summary(primary: 10, secondary: 85)
        XCTAssertEqual(ProfileSwitcherCard.quotaDotColor(for: s, source: .weekly), .red)
    }

    func test_quotaDot_higherSource_picksMax() {
        // .higher should match the previous always-max behavior — the dot
        // turns red when *either* bucket crosses the critical threshold.
        let s = summary(primary: 30, secondary: 90)
        XCTAssertEqual(ProfileSwitcherCard.quotaDotColor(for: s, source: .higher), .red)
    }
}
