import XCTest
@testable import Kwota

final class AntigravityUsageSnapshotTests: XCTestCase {
    func test_decodes_minimalEmpty() throws {
        let snap = try AntigravityUsageSnapshot.decoder.decode(
            AntigravityUsageSnapshot.self, from: Data(#"{"userStatus":{}}"#.utf8))
        XCTAssertNil(snap.email)
        XCTAssertNil(snap.planInfo)
    }

    func test_decodes_fullShape() throws {
        let json = #"""
        {"userStatus":{
          "name":"User","email":"u@b.com",
          "planStatus":{
            "planInfo":{"planName":"Pro","teamsTier":"TEAMS_TIER_PRO",
                        "monthlyPromptCredits":50000,"monthlyFlowCredits":150000},
            "availablePromptCredits":500,"availableFlowCredits":100
          },
          "userTier":{"name":"Google AI Pro","availableCredits":[{"creditAmount":"42","creditType":"GOOGLE_ONE_AI"}]}
        }}
        """#
        let snap = try AntigravityUsageSnapshot.decoder.decode(
            AntigravityUsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.email, "u@b.com")
        XCTAssertEqual(snap.planInfo?.planName, "Pro")
        XCTAssertEqual(snap.planInfo?.monthlyPromptCredits, 50000)
        XCTAssertEqual(snap.availablePromptCredits, 500)
        XCTAssertEqual(snap.aiCreditsWallet, 42)
        XCTAssertEqual(snap.userTierName, "Google AI Pro")
        XCTAssertEqual(snap.tier, .pro)
        XCTAssertEqual(snap.promptCreditPercentRemaining ?? -1, 1.0, accuracy: 0.01)
    }

    func test_availableCredits_decodesFullEntryShape() throws {
        // Wire form from a live `g1-pro-tier` userTier: int64-as-string
        // amounts and the discriminator + minimum-spend fields preserved.
        let json = #"""
        {"userStatus":{"userTier":{"availableCredits":[
          {"creditType":"GOOGLE_ONE_AI","creditAmount":"1000","minimumCreditAmountForUsage":"50"}
        ]}}}
        """#
        let snap = try AntigravityUsageSnapshot.decoder.decode(
            AntigravityUsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.availableCredits.count, 1)
        XCTAssertEqual(snap.availableCredits.first?.creditType, "GOOGLE_ONE_AI")
        XCTAssertEqual(snap.availableCredits.first?.creditAmount, 1000)
        XCTAssertEqual(snap.availableCredits.first?.minimumCreditAmountForUsage, 50)
        // Convenience getter reads the first entry's amount.
        XCTAssertEqual(snap.aiCreditsWallet, 1000)
    }

    func test_availableCredits_missingDefaultsToEmptyArray() throws {
        let snap = try AntigravityUsageSnapshot.decoder.decode(
            AntigravityUsageSnapshot.self, from: Data(#"{"userStatus":{}}"#.utf8))
        XCTAssertTrue(snap.availableCredits.isEmpty)
        XCTAssertNil(snap.aiCreditsWallet)
    }

    func test_proto3_walletEntryExistsButCreditAmountAbsent_meansZero() throws {
        // Live g1-pro-tier wire when AI Credits balance is 0: the entry is
        // present but `creditAmount` is elided. Must decode as 0, never fall
        // back to a stale state.vscdb sentinel. Mirrors the remainingFraction
        // test below.
        let json = #"""
        {"userStatus":{"userTier":{"availableCredits":[
          {"creditType":"GOOGLE_ONE_AI","minimumCreditAmountForUsage":"50"}
        ]}}}
        """#
        var snap = try AntigravityUsageSnapshot.decoder.decode(
            AntigravityUsageSnapshot.self, from: Data(json.utf8))
        snap.aiCreditsFallback = 1000
        XCTAssertEqual(snap.availableCredits.first?.creditAmount, 0)
        XCTAssertEqual(snap.aiCreditsWallet, 0)
    }

    func test_int64AsString_alsoDecodes() throws {
        // Proto JSON serializes int64 as string. Verify the decoder accepts both.
        let json = #"""
        {"userStatus":{"planStatus":{
          "planInfo":{"monthlyPromptCredits":"50000"},
          "availablePromptCredits":"500"
        }}}
        """#
        let snap = try AntigravityUsageSnapshot.decoder.decode(
            AntigravityUsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.planInfo?.monthlyPromptCredits, 50000)
        XCTAssertEqual(snap.availablePromptCredits, 500)
    }

    // MARK: - aiCreditsUtilization

    func test_aiCreditsUtilization_returnsNil_whenNoWallet() {
        let s = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            planInfo: .init(planName: "Google AI Pro", monthlyPromptCredits: 5000),
            availableCredits: [],
            userTierName: "Google AI Pro"
        )
        XCTAssertNil(s.aiCreditsUtilization)
    }

    func test_aiCreditsUtilization_returnsNil_whenTierHasNoCeiling() {
        // userTierName empty → tier defaults to .unknown → no ceiling
        let s = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            availableCredits: [.init(creditType: "GOOGLE_ONE_AI", creditAmount: 100)]
        )
        XCTAssertNil(s.aiCreditsUtilization)
    }

    func test_aiCreditsUtilization_computesForProTier() {
        // Pro ceiling = 1,000.  wallet = 423.  util = (1 - 423/1000) * 100 = 57.7
        let s = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            planInfo: .init(planName: "Google AI Pro", monthlyPromptCredits: 5000),
            availableCredits: [.init(creditType: "GOOGLE_ONE_AI", creditAmount: 423)],
            userTierName: "Google AI Pro"
        )
        XCTAssertEqual(s.aiCreditsUtilization!, 57.7, accuracy: 0.05)
    }

    // MARK: - overagesEnabled

    func test_overagesEnabled_defaultsToNil() {
        let s = AntigravityUsageSnapshot(fetchedAt: .distantPast)
        XCTAssertNil(s.overagesEnabled)
    }

    func test_overagesEnabled_canBeMutatedAfterDecode() {
        var s = AntigravityUsageSnapshot(fetchedAt: .distantPast)
        s.overagesEnabled = true
        XCTAssertEqual(s.overagesEnabled, true)
        s.overagesEnabled = false
        XCTAssertEqual(s.overagesEnabled, false)
    }

    // MARK: - aiCreditsWallet fallback

    func test_aiCreditsWallet_prefersAPIWallet_overFallback() {
        let s = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            availableCredits: [.init(creditType: "GOOGLE_ONE_AI", creditAmount: 250)],
            aiCreditsFallback: 1000
        )
        XCTAssertEqual(s.aiCreditsWallet, 250)
    }

    func test_aiCreditsWallet_usesFallback_whenNoAPIWallet() {
        let s = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            availableCredits: [],
            aiCreditsFallback: 1000
        )
        XCTAssertEqual(s.aiCreditsWallet, 1000)
    }

    func test_aiCreditsWallet_nil_whenNeitherPresent() {
        let s = AntigravityUsageSnapshot(fetchedAt: .distantPast)
        XCTAssertNil(s.aiCreditsWallet)
    }
}
