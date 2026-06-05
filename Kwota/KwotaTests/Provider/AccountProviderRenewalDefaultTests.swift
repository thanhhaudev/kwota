//  AccountProviderRenewalDefaultTests.swift
//  KwotaTests

import XCTest
import SwiftUI
@testable import Kwota

@MainActor
final class AccountProviderRenewalDefaultTests: XCTestCase {
    /// Minimal provider that takes the protocol defaults for both new hooks.
    private final class BareProvider: AccountProvider {
        let id: ProviderID = .claude
        let displayName = "Bare"
        let iconAssetName = "Mascot"
        var supportedAuthMethods: [any ProviderAuthMethod] { [] }
        func fetchUsage(credential: Credential, profile: Profile) async throws -> ProviderUsageSummary {
            ProviderUsageSummary(providerID: id, fetchedAt: .distantPast,
                                 primary: nil, secondary: nil, payload: 0 as Int)
        }
        func usageDetailView(summary: ProviderUsageSummary, history: [UsageHistoryEntry], profile: Profile) -> AnyView { AnyView(EmptyView()) }
        func planBadgeView(profile: Profile) -> AnyView { AnyView(EmptyView()) }
    }

    func test_defaultRenewalEstimate_usesSubscriptionMonthly() {
        let p = makeProfileWithCreated("2026-01-10T00:00:00Z")
        let est = BareProvider().renewalEstimate(
            profile: p, summary: nil, now: iso("2026-05-29T00:00:00Z"))
        XCTAssertEqual(est?.date, iso("2026-06-10T00:00:00Z"))
        XCTAssertEqual(est?.prefix, "Est.")
        XCTAssertEqual(est?.absolute, true)
    }

    func test_defaultRenewalEstimate_nilWhenNoAnchors() {
        let p = Profile(name: "p", authMethod: .cliSync)
        XCTAssertNil(BareProvider().renewalEstimate(profile: p, summary: nil, now: Date()))
    }

    func test_defaultReauthTitle_namesProviderCLI() {
        XCTAssertEqual(BareProvider().reauthTitle, "Bare CLI session expired")
    }

    func test_defaultEvaluateCreditCycle_isNil() {
        let summary = ProviderUsageSummary(
            providerID: .claude, fetchedAt: .distantPast,
            primary: nil, secondary: nil, payload: 0 as Int)
        XCTAssertNil(BareProvider().evaluateCreditCycle(
            summary: summary, profile: Profile(name: "p", authMethod: .cliSync), now: Date()))
    }

    private func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    private func makeProfileWithCreated(_ s: String) -> Profile {
        var p = Profile(name: "p", authMethod: .cliSync)
        p.subscriptionCreatedAt = iso(s)
        return p
    }
}
