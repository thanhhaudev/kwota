//
//  PlanFormatterRateLimitTierTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class PlanFormatterRateLimitTierTests: XCTestCase {

    // MARK: - format(rateLimitTier:)

    func testRateLimitTier_max20x() {
        XCTAssertEqual(PlanFormatter.format(rateLimitTier: "default_claude_max_20x"), "Max 20x")
    }

    func testRateLimitTier_max5x() {
        XCTAssertEqual(PlanFormatter.format(rateLimitTier: "default_claude_max_5x"), "Max 5x")
    }

    func testRateLimitTier_max100x() {
        XCTAssertEqual(PlanFormatter.format(rateLimitTier: "default_claude_max_100x"), "Max 100x")
    }

    func testRateLimitTier_pro() {
        XCTAssertEqual(PlanFormatter.format(rateLimitTier: "default_claude_pro"), "Pro")
    }

    func testRateLimitTier_free() {
        XCTAssertEqual(PlanFormatter.format(rateLimitTier: "default_claude_free"), "Free")
    }

    func testRateLimitTier_team_noSuffix() {
        XCTAssertEqual(PlanFormatter.format(rateLimitTier: "default_claude_team"), "Team")
    }

    func testRateLimitTier_teamPremium() {
        XCTAssertEqual(PlanFormatter.format(rateLimitTier: "default_claude_team_premium"), "Team Premium")
    }

    func testRateLimitTier_enterprise() {
        XCTAssertEqual(PlanFormatter.format(rateLimitTier: "default_claude_enterprise"), "Enterprise")
    }

    func testRateLimitTier_shortPrefix_claudeMax20x() {
        // `claude_` prefix without `default_` also accepted.
        XCTAssertEqual(PlanFormatter.format(rateLimitTier: "claude_max_20x"), "Max 20x")
    }

    func testRateLimitTier_noPrefix_max20x() {
        // Raw `max_20x` (no `default_claude_` or `claude_` prefix) still works.
        XCTAssertEqual(PlanFormatter.format(rateLimitTier: "max_20x"), "Max 20x")
    }

    func testRateLimitTier_unknownSuffixesDropped() {
        // `lite` is not `\d+x` and not `premium`, so it's dropped.
        XCTAssertEqual(
            PlanFormatter.format(rateLimitTier: "default_claude_max_20x_lite"),
            "Max 20x"
        )
    }

    func testRateLimitTier_teamWithOrgSlugAndPremium() {
        // `bendep` and `nonprofit` dropped; `premium` kept.
        XCTAssertEqual(
            PlanFormatter.format(rateLimitTier: "default_claude_team_bendep_nonprofit_premium"),
            "Team Premium"
        )
    }

    func testRateLimitTier_unknownBaseCapitalized() {
        XCTAssertEqual(PlanFormatter.format(rateLimitTier: "default_claude_newtier"), "Newtier")
    }

    func testRateLimitTier_empty_returnsNil() {
        XCTAssertNil(PlanFormatter.format(rateLimitTier: ""))
    }

    func testRateLimitTier_nil_returnsNil() {
        XCTAssertNil(PlanFormatter.format(rateLimitTier: nil))
    }

    // MARK: - Shared helper consistency across entry points
    // The shared `renderPlan` helper means seatTier path now produces the
    // same enriched labels as rateLimitTier. These tests pin that contract.

    func testSeatTier_max20x_throughSharedHelper() {
        XCTAssertEqual(
            PlanFormatter.format(seatTier: "max_20x", organizationType: nil),
            "Max 20x"
        )
    }

    func testSeatTier_teamPremium_throughSharedHelper() {
        XCTAssertEqual(
            PlanFormatter.format(seatTier: "team_premium", organizationType: nil),
            "Team Premium"
        )
    }

    func testOrgType_claudeMax20x_throughSharedHelper() {
        // Two-arg overload: nil seatTier, claude_max_20x organizationType.
        XCTAssertEqual(
            PlanFormatter.format(seatTier: nil, organizationType: "claude_max_20x"),
            "Max 20x"
        )
    }

    func testOrgType_claudeTeamPremium_throughSharedHelper() {
        XCTAssertEqual(
            PlanFormatter.format(seatTier: nil, organizationType: "claude_team_premium"),
            "Team Premium"
        )
    }
}
