//
//  OAuthAccountReaderTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class OAuthAccountReaderTests: XCTestCase {
    func testReadsSeatTierAndEmail() {
        let json = #"""
        {"oauthAccount":{"seatTier":"team_bendep_nonprofit_premium","emailAddress":"x@y.com","displayName":"Hau","organizationName":"Box"}}
        """#
        let reader = OAuthAccountReader(configFile: URL(string: "x:/")!,
                                         provider: { Data(json.utf8) })
        let account = reader.read()
        XCTAssertEqual(account?.seatTier, "team_bendep_nonprofit_premium")
        XCTAssertEqual(account?.emailAddress, "x@y.com")
        XCTAssertEqual(account?.displayName, "Hau")
        XCTAssertEqual(account?.organizationName, "Box")
    }

    func testReadReturnsNilWhenOauthAccountMissing() {
        let json = "{}"
        let reader = OAuthAccountReader(configFile: URL(string: "x:/")!,
                                         provider: { Data(json.utf8) })
        XCTAssertNil(reader.read())
    }

    func testPlanFormatterMapsKnownPrefixes() {
        // Team variants now preserve a `premium` suffix when present;
        // other org-specific tokens (`bendep`, `nonprofit`) are still dropped.
        XCTAssertEqual(PlanFormatter.format("team_bendep_nonprofit_premium"), "Team Premium")
        XCTAssertEqual(PlanFormatter.format("team_bendep_nonprofit"),         "Team")
        XCTAssertEqual(PlanFormatter.format("team_premium"),                  "Team Premium")
        // Max variants surface the rate-limit multiplier (`5x`, `20x`).
        XCTAssertEqual(PlanFormatter.format("max_5x"),  "Max 5x")
        XCTAssertEqual(PlanFormatter.format("max_20x"), "Max 20x")
        // Unchanged for Pro/Enterprise/Free/raven.
        XCTAssertEqual(PlanFormatter.format("pro"), "Pro")
        XCTAssertEqual(PlanFormatter.format("pro_yearly"), "Pro")
        XCTAssertEqual(PlanFormatter.format("enterprise_seat"), "Enterprise")
        XCTAssertEqual(PlanFormatter.format("free"), "Free")
        XCTAssertEqual(PlanFormatter.format("raven"), "Pro")
    }

    func testPlanFormatterFallbackCapitalizesFirstToken() {
        XCTAssertEqual(PlanFormatter.format("custom_unknown_tier"), "Custom")
    }

    func testPlanFormatterReturnsNilForEmpty() {
        XCTAssertNil(PlanFormatter.format(nil))
        XCTAssertNil(PlanFormatter.format(""))
    }

    // MARK: - PlanFormatter two-arg overload

    func testPlanFormatterOrgType_seatTierWins() {
        // seatTier still takes precedence over organizationType. Suffix
        // surfaces because seatTier path now uses the shared helper.
        XCTAssertEqual(
            PlanFormatter.format(seatTier: "max_5x", organizationType: "claude_max"),
            "Max 5x"
        )
    }

    func testPlanFormatterOrgType_nullSeatTier_claudeMax() {
        XCTAssertEqual(PlanFormatter.format(seatTier: nil, organizationType: "claude_max"), "Max")
    }

    func testPlanFormatterOrgType_nullSeatTier_claudePro() {
        XCTAssertEqual(PlanFormatter.format(seatTier: nil, organizationType: "claude_pro"), "Pro")
    }

    func testPlanFormatterOrgType_nullSeatTier_claudeTeam() {
        XCTAssertEqual(PlanFormatter.format(seatTier: nil, organizationType: "claude_team"), "Team")
    }

    func testPlanFormatterOrgType_bothNil_returnsNil() {
        XCTAssertNil(PlanFormatter.format(seatTier: nil, organizationType: nil))
    }

    func testPlanFormatterOrgType_bothEmpty_returnsNil() {
        XCTAssertNil(PlanFormatter.format(seatTier: "", organizationType: ""))
    }

    func testOAuthAccountReaderParsesOrgTypeAndRateLimitTier() {
        let json = #"""
        {"oauthAccount":{"seatTier":null,"emailAddress":"x@y.com","organizationType":"claude_max","organizationRateLimitTier":"tier2"}}
        """#
        let reader = OAuthAccountReader(configFile: URL(string: "x:/")!,
                                         provider: { Data(json.utf8) })
        let account = reader.read()
        XCTAssertNil(account?.seatTier)
        XCTAssertEqual(account?.organizationType, "claude_max")
        XCTAssertEqual(account?.organizationRateLimitTier, "tier2")
    }

    func test_read_parsesAccountAndOrgUuid() {
        let json = """
        {"oauthAccount":{"emailAddress":"a@x.com","seatTier":"max",
          "accountUuid":"acct-123","organizationUuid":"org-456"}}
        """
        let reader = OAuthAccountReader(provider: { Data(json.utf8) })
        let account = reader.read()
        XCTAssertEqual(account?.accountUuid, "acct-123")
        XCTAssertEqual(account?.organizationUuid, "org-456")
    }
}
