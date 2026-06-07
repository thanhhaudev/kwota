import XCTest
@testable import Kwota

final class AntigravityUsageSnapshotTests: XCTestCase {
    func test_decodes_minimalEmpty() throws {
        let snap = try AntigravityUsageSnapshot.decoder.decode(
            AntigravityUsageSnapshot.self, from: Data(#"{"userStatus":{}}"#.utf8))
        XCTAssertNil(snap.email)
        XCTAssertNil(snap.planInfo)
        XCTAssertNil(snap.models)
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
          "cascadeModelConfigData":{"clientModelConfigs":[
            {"label":"Gemini Flash","modelOrAlias":{"model":"M20"},
             "quotaInfo":{"remainingFraction":0.85,"resetTime":"2026-05-28T00:00:00Z"}}
          ]},
          "userTier":{"name":"Google AI Pro","availableCredits":[{"creditAmount":"42","creditType":"GOOGLE_ONE_AI"}]}
        }}
        """#
        let snap = try AntigravityUsageSnapshot.decoder.decode(
            AntigravityUsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.email, "u@b.com")
        XCTAssertEqual(snap.planInfo?.planName, "Pro")
        XCTAssertEqual(snap.planInfo?.monthlyPromptCredits, 50000)
        XCTAssertEqual(snap.availablePromptCredits, 500)
        XCTAssertEqual(snap.models?.count, 1)
        XCTAssertEqual(snap.models?.first?.remainingFraction, 0.85)
        XCTAssertEqual(snap.models?.first?.modelId, "M20")
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

    func test_proto3_quotaInfoExistsButRemainingFractionAbsent_meansZero() throws {
        // Per proto3, default zero values are elided. Reference: ma-do-ka repo line 138.
        let json = #"""
        {"userStatus":{"cascadeModelConfigData":{"clientModelConfigs":[
          {"label":"M","modelOrAlias":{"model":"X"},
           "quotaInfo":{"resetTime":"2026-05-28T00:00:00Z"}}
        ]}}}
        """#
        let snap = try AntigravityUsageSnapshot.decoder.decode(
            AntigravityUsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.models?.first?.remainingFraction, 0)
    }

    func test_proto3_quotaInfoAbsent_meansNoLimit() throws {
        let json = #"""
        {"userStatus":{"cascadeModelConfigData":{"clientModelConfigs":[
          {"label":"M","modelOrAlias":{"model":"X"}}
        ]}}}
        """#
        let snap = try AntigravityUsageSnapshot.decoder.decode(
            AntigravityUsageSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snap.models?.first?.remainingFraction)
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

    // MARK: - worstModelUtilization

    func test_worstModelUtilization_returnsNil_whenNoModels() {
        let s = AntigravityUsageSnapshot(fetchedAt: .distantPast, models: nil)
        XCTAssertNil(s.worstModelUtilization)
    }

    func test_worstModelUtilization_returnsNil_whenAllModelsHaveNoQuota() {
        let s = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [
                .init(label: "GPT-5", modelId: "gpt-5", remainingFraction: nil, resetTime: nil),
                .init(label: "Claude", modelId: "claude", remainingFraction: nil, resetTime: nil)
            ]
        )
        XCTAssertNil(s.worstModelUtilization)
    }

    func test_worstModelUtilization_takesMinAmongQuotaModels() {
        // min remainingFraction = 0.03  →  utilization = (1 - 0.03) * 100 = 97
        let s = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [
                .init(label: "GPT-5",      modelId: "gpt-5",  remainingFraction: nil,  resetTime: nil),
                .init(label: "Gemini Pro", modelId: "gem",    remainingFraction: 0.03, resetTime: nil),
                .init(label: "Claude",     modelId: "claude", remainingFraction: 0.5,  resetTime: nil)
            ]
        )
        XCTAssertEqual(s.worstModelUtilization!, 97, accuracy: 0.0001)
    }

    func test_worstModelUtilization_clampedTo100_whenFractionZero() {
        let s = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [.init(label: "X", modelId: "x", remainingFraction: 0, resetTime: nil)]
        )
        XCTAssertEqual(s.worstModelUtilization!, 100, accuracy: 0.0001)
    }

    // MARK: - worstModelLabel

    func test_worstModelLabel_returnsNil_whenNoQuotaModels() {
        let s = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [.init(label: "X", modelId: "x", remainingFraction: nil, resetTime: nil)]
        )
        XCTAssertNil(s.worstModelLabel)
    }

    func test_worstModelLabel_returnsTheModelDrivingTheMin() {
        let s = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [
                .init(label: "GPT-5",      modelId: "gpt", remainingFraction: 0.8,  resetTime: nil),
                .init(label: "Gemini Pro", modelId: "gem", remainingFraction: 0.03, resetTime: nil),
                .init(label: "Claude",     modelId: "cla", remainingFraction: 0.5,  resetTime: nil)
            ]
        )
        XCTAssertEqual(s.worstModelLabel, "Gemini Pro")
    }

    // MARK: - worst-still-usable selection (exhausted-aware)

    func test_worstModel_skipsExhaustedAndPicksNextWorstUsable() {
        // Opus at 0 (exhausted) is excluded; among Flash (0.7) and Pro
        // (0.4), Pro has the lower remaining → it's the worst usable.
        // Util = (1 - 0.4) * 100 = 60.
        let s = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [
                .init(label: "Opus",         modelId: "opus",  remainingFraction: 0,    resetTime: nil),
                .init(label: "Gemini Flash", modelId: "flash", remainingFraction: 0.7,  resetTime: nil),
                .init(label: "Gemini Pro",   modelId: "pro",   remainingFraction: 0.4,  resetTime: nil)
            ]
        )
        XCTAssertEqual(s.worstModelUtilization!, 60, accuracy: 0.0001)
        XCTAssertEqual(s.worstModelLabel, "Gemini Pro")
    }

    func test_worstModel_returns100AndEarliestResetLabel_whenAllExhausted() {
        // Every model exhausted. Bar pegs to 100 (capped). Label points
        // at the one with the earliest resetTime — the next model to
        // come back online — so the tooltip can promise "next reset in X".
        let soon = Date(timeIntervalSince1970: 1_000_000)
        let later = soon.addingTimeInterval(3_600)
        let s = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [
                .init(label: "Opus",       modelId: "opus", remainingFraction: 0, resetTime: later),
                .init(label: "Sonnet",     modelId: "son",  remainingFraction: 0, resetTime: soon),
                .init(label: "Gemini Pro", modelId: "pro",  remainingFraction: 0, resetTime: later)
            ]
        )
        XCTAssertEqual(s.worstModelUtilization!, 100, accuracy: 0.0001)
        XCTAssertEqual(s.worstModelLabel, "Sonnet",
                       "earliest-reset model wins the label slot when all are capped")
        XCTAssertTrue(s.allModelsExhausted)
        XCTAssertEqual(s.earliestModelReset, soon)
    }

    // MARK: - allModelsFresh / allModelsExhausted

    func test_allModelsFresh_trueWhenEveryQuotaModelAt100Remaining() {
        let s = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [
                .init(label: "A", modelId: "a", remainingFraction: 1.0, resetTime: nil),
                .init(label: "B", modelId: "b", remainingFraction: 1.0, resetTime: nil),
                // No-quota model doesn't disqualify
                .init(label: "C", modelId: "c", remainingFraction: nil, resetTime: nil)
            ]
        )
        XCTAssertTrue(s.allModelsFresh)
        XCTAssertFalse(s.allModelsExhausted)
    }

    func test_allModelsFresh_falseWhenAnyHasUsage() {
        let s = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [
                .init(label: "A", modelId: "a", remainingFraction: 1.0, resetTime: nil),
                .init(label: "B", modelId: "b", remainingFraction: 0.9, resetTime: nil)
            ]
        )
        XCTAssertFalse(s.allModelsFresh)
    }

    func test_allModelsExhausted_falseWhenOneStillUsable() {
        let s = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [
                .init(label: "A", modelId: "a", remainingFraction: 0,   resetTime: nil),
                .init(label: "B", modelId: "b", remainingFraction: 0.1, resetTime: nil)
            ]
        )
        XCTAssertFalse(s.allModelsExhausted)
    }

    func test_earliestModelReset_picksTheEarliestNonNil() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let s = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [
                .init(label: "A", modelId: "a", remainingFraction: 0, resetTime: now.addingTimeInterval(7_200)),
                .init(label: "B", modelId: "b", remainingFraction: 0, resetTime: now.addingTimeInterval(3_600)),
                .init(label: "C", modelId: "c", remainingFraction: 0, resetTime: nil)
            ]
        )
        XCTAssertEqual(s.earliestModelReset, now.addingTimeInterval(3_600))
    }

    // MARK: - worstModelReset

    func test_worstModelReset_picksWorstUsableModelsOwnReset_notEarliest() {
        // The screenshot scenario: the worst usable model (Sonnet, lowest
        // remaining → the one on the bar) resets LATER than a healthier
        // model. worstModelReset must follow the bar, not the soonest reset.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let sonnetReset = now.addingTimeInterval(5 * 86_400) // +5 days
        let geminiReset = now.addingTimeInterval(4 * 3_600)  // +4 hours
        let s = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [
                .init(label: "Sonnet", modelId: "son", remainingFraction: 0.2, resetTime: sonnetReset),
                .init(label: "Gemini", modelId: "gem", remainingFraction: 0.8, resetTime: geminiReset)
            ]
        )
        XCTAssertEqual(s.worstModelLabel, "Sonnet")
        XCTAssertEqual(s.worstModelReset, sonnetReset)
        XCTAssertEqual(s.earliestModelReset, geminiReset,
                       "earliestModelReset still tracks the soonest — they must differ here")
    }

    func test_worstModelReset_whenAllExhausted_matchesEarliestResetModel() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let soon = now.addingTimeInterval(3_600)
        let later = now.addingTimeInterval(7_200)
        let s = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [
                .init(label: "Opus",   modelId: "opus", remainingFraction: 0, resetTime: later),
                .init(label: "Sonnet", modelId: "son",  remainingFraction: 0, resetTime: soon)
            ]
        )
        // All capped → worst model is the next to return (earliest reset).
        XCTAssertEqual(s.worstModelLabel, "Sonnet")
        XCTAssertEqual(s.worstModelReset, soon)
    }

    func test_worstModelReset_nilWhenWorstModelHasNoResetWindow() {
        // Every model fresh and unthrottled → no reset to surface; the
        // switcher subtitle should fall back to the credit cycle.
        let s = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [
                .init(label: "A", modelId: "a", remainingFraction: 1.0, resetTime: nil),
                .init(label: "B", modelId: "b", remainingFraction: 1.0, resetTime: nil)
            ]
        )
        XCTAssertNil(s.worstModelReset)
    }

    func test_worstModelReset_nilWhenNoModels() {
        XCTAssertNil(AntigravityUsageSnapshot(fetchedAt: .distantPast).worstModelReset)
    }

    func test_worstModelReset_nil_whenWorstModelHasNoReset_butAnotherDoes() {
        // Partial data: the worst usable model carries no resetTime; a
        // healthier model does. worstModelReset must stay nil so callers
        // never surface the other model's reset as the worst model's.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let s = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [
                .init(label: "Sonnet", modelId: "son", remainingFraction: 0.2, resetTime: nil),
                .init(label: "Gemini", modelId: "gem", remainingFraction: 0.8, resetTime: now.addingTimeInterval(3_600))
            ]
        )
        XCTAssertEqual(s.worstModelLabel, "Sonnet")
        XCTAssertNil(s.worstModelReset)
        XCTAssertEqual(s.earliestModelReset, now.addingTimeInterval(3_600),
                       "earliest still tracks the healthier model — worstModelReset must not")
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
