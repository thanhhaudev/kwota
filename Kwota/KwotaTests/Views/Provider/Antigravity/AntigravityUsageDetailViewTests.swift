//
//  AntigravityUsageDetailViewTests.swift
//  KwotaTests
//
//  Pure predicate coverage for the popover's credit-card visibility
//  rules. Visual rendering of the bar / caption is exercised manually
//  per Task 8 of the rework plan.
//

import XCTest
@testable import Kwota

@MainActor
final class AntigravityUsageDetailViewTests: XCTestCase {

    func test_shouldShowCreditCard_falseWhenNoWallet() {
        let snapshot = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            planInfo: .init(planName: "Google AI Pro", monthlyPromptCredits: 5000),
            availableCredits: [],
            userTierName: "Google AI Pro"
        )
        XCTAssertFalse(AntigravityUsageDetailView.shouldShowCreditCard(snapshot: snapshot))
    }

    func test_shouldShowCreditCard_falseWhenTierHasNoCeiling() {
        let snapshot = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            availableCredits: [.init(creditType: "GOOGLE_ONE_AI", creditAmount: 100)],
            userTierName: ""              // → .unknown → no ceiling
        )
        XCTAssertFalse(AntigravityUsageDetailView.shouldShowCreditCard(snapshot: snapshot))
    }

    func test_shouldShowCreditCard_trueWhenWalletAndCeilingPresent() {
        let snapshot = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            planInfo: .init(planName: "Google AI Pro", monthlyPromptCredits: 5000),
            availableCredits: [.init(creditType: "GOOGLE_ONE_AI", creditAmount: 100)],
            userTierName: "Google AI Pro"
        )
        XCTAssertTrue(AntigravityUsageDetailView.shouldShowCreditCard(snapshot: snapshot))
    }

    func test_shouldShowOverageCaption_followsExplicitState() {
        var snapshot = AntigravityUsageSnapshot(fetchedAt: .distantPast)
        snapshot.overagesEnabled = true
        XCTAssertTrue(AntigravityUsageDetailView.shouldShowOverageCaption(snapshot: snapshot))
        snapshot.overagesEnabled = false
        XCTAssertTrue(AntigravityUsageDetailView.shouldShowOverageCaption(snapshot: snapshot))
        snapshot.overagesEnabled = nil
        XCTAssertFalse(AntigravityUsageDetailView.shouldShowOverageCaption(snapshot: snapshot))
    }

    func test_aiCreditsBarShouldDim_followsOveragesOff() {
        var snapshot = AntigravityUsageSnapshot(fetchedAt: .distantPast)
        snapshot.overagesEnabled = false
        XCTAssertTrue(AntigravityUsageDetailView.aiCreditsBarShouldDim(snapshot: snapshot))
        snapshot.overagesEnabled = true
        XCTAssertFalse(AntigravityUsageDetailView.aiCreditsBarShouldDim(snapshot: snapshot))
        snapshot.overagesEnabled = nil
        XCTAssertFalse(AntigravityUsageDetailView.aiCreditsBarShouldDim(snapshot: snapshot))
    }
}
