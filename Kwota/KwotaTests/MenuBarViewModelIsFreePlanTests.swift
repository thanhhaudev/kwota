//
//  MenuBarViewModelIsFreePlanTests.swift
//  KwotaTests
//
//  Regression suite for the "Plan: Free" misidentification bug: paid users
//  who sign in via sessionKey paste flow had subscriptionPlan == nil because
//  no code path on that flow probes plan info, and the previous gating
//  logic equated nil with "Free" — locking the session/weekly charts behind
//  a fake upsell overlay.
//
//  Two-signal gate now: planSaysFree (only when explicitly "Free") AND
//  !dataProvesPaid (any per-model bucket or extra-credit billing being
//  active). Either signal alone is enough to keep the overlay off.
//

import XCTest
@testable import Kwota

final class MenuBarViewModelIsFreePlanTests: XCTestCase {

    private func snapshot(
        opus: UsageBucket? = nil,
        sonnet: UsageBucket? = nil,
        omelette: UsageBucket? = nil,
        extra: ExtraUsage? = nil
    ) -> UsageSnapshot {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return UsageSnapshot(
            fiveHour: UsageBucket(utilization: nil, resetsAt: now.addingTimeInterval(3600)),
            sevenDay: UsageBucket(utilization: nil, resetsAt: now.addingTimeInterval(86400)),
            sevenDayOpus: opus,
            sevenDaySonnet: sonnet,
            sevenDayOmelette: omelette,
            extra: extra,
            fetchedAt: now
        )
    }

    // MARK: - The bug: nil plan + paid data must NOT be Free

    func testNilPlanWithPaidPerModelDataIsNotFree() {
        // The exact screenshot scenario: sessionKey-pasted profile, plan
        // never written, but seven_day_sonnet=13% and seven_day_omelette=8%
        // populated by claude.ai/api/usage. Previous logic locked the
        // session/weekly charts; new logic must let them through.
        let snap = snapshot(
            sonnet: UsageBucket(utilization: 13, resetsAt: nil),
            omelette: UsageBucket(utilization: 8, resetsAt: nil)
        )
        XCTAssertFalse(MenuBarViewModel.computeIsFreePlan(plan: nil, snapshot: snap))
    }

    func testNilPlanWithNoDataIsNotFree() {
        // F1 alone: nil plan never implies Free. An actual Free user with no
        // data here will see empty zero-percent charts instead of the
        // overlay — acceptable UX trade for not falsely blocking paid users.
        let snap = snapshot()
        XCTAssertFalse(MenuBarViewModel.computeIsFreePlan(plan: nil, snapshot: snap))
    }

    func testNilPlanAndNilSnapshotIsNotFree() {
        // Edge case: brand-new profile, snapshot still nil while first fetch
        // is in flight. Must not flicker into the Free state during the gap.
        XCTAssertFalse(MenuBarViewModel.computeIsFreePlan(plan: nil, snapshot: nil))
    }

    // MARK: - Explicit "Free" plan handling

    func testExplicitFreePlanWithNoDataIsFree() {
        // Genuine Free account: plan field carries the literal string and no
        // per-model data exists. Overlay should fire — this is the legitimate
        // upsell case.
        let snap = snapshot()
        XCTAssertTrue(MenuBarViewModel.computeIsFreePlan(plan: "Free", snapshot: snap))
    }

    func testExplicitFreePlanWithPaidDataIsNotFree() {
        // Defensive: if Anthropic ever stamps "Free" but the snapshot shows
        // per-model data (data > label), trust the data. Prevents a single
        // mislabeling from locking out an account that's clearly paid.
        let snap = snapshot(sonnet: UsageBucket(utilization: 5, resetsAt: nil))
        XCTAssertFalse(MenuBarViewModel.computeIsFreePlan(plan: "Free", snapshot: snap))
    }

    func testFreePlanMatchIsCaseInsensitive() {
        // Anthropic's responses have varied between "free" / "Free" / "FREE"
        // historically; gate must catch all spellings.
        let snap = snapshot()
        XCTAssertTrue(MenuBarViewModel.computeIsFreePlan(plan: "free",  snapshot: snap))
        XCTAssertTrue(MenuBarViewModel.computeIsFreePlan(plan: "FREE",  snapshot: snap))
        XCTAssertTrue(MenuBarViewModel.computeIsFreePlan(plan: "Free",  snapshot: snap))
    }

    // MARK: - Paid plan handling (CLI profile flow)

    func testProPlanIsNeverFree() {
        // CLI profiles populate subscriptionPlan from the keychain envelope.
        // Pro/Team/Max all flip planSaysFree off, so no data probe needed.
        let snap = snapshot()
        XCTAssertFalse(MenuBarViewModel.computeIsFreePlan(plan: "Pro",  snapshot: snap))
        XCTAssertFalse(MenuBarViewModel.computeIsFreePlan(plan: "Team", snapshot: snap))
        XCTAssertFalse(MenuBarViewModel.computeIsFreePlan(plan: "Max",  snapshot: snap))
    }

    // MARK: - dataProvesPaid signal sources

    func testOpusBucketAloneProvesPaid() {
        let snap = snapshot(opus: UsageBucket(utilization: 0, resetsAt: nil))
        XCTAssertFalse(MenuBarViewModel.computeIsFreePlan(plan: "Free", snapshot: snap))
    }

    func testExtraUsageEnabledProvesPaid() {
        // Extra-credit billing is paid-tier only. Even with zero usage and
        // no per-model data, an enabled extra row should prevent overlay.
        let snap = snapshot(extra: ExtraUsage(
            isEnabled: true,
            utilization: 0,
            usedCredits: 0,
            monthlyLimit: 5000
        ))
        XCTAssertFalse(MenuBarViewModel.computeIsFreePlan(plan: "Free", snapshot: snap))
    }

    func testFreePlanWithSessionDataIsNotFree() {
        // Free account with session usage data should NOT be gated.
        let now = Date()
        let snap = UsageSnapshot(
            fiveHour: UsageBucket(utilization: 11, resetsAt: now.addingTimeInterval(3600)),
            sevenDay: UsageBucket(utilization: nil, resetsAt: nil),
            fetchedAt: now
        )
        XCTAssertFalse(MenuBarViewModel.computeIsFreePlan(plan: "Free", snapshot: snap))
    }

    func testFreePlanWithWeeklyDataIsNotFree() {
        // Free account with weekly usage data should NOT be gated.
        let now = Date()
        let snap = UsageSnapshot(
            fiveHour: UsageBucket(utilization: nil, resetsAt: nil),
            sevenDay: UsageBucket(utilization: 1, resetsAt: now.addingTimeInterval(86400)),
            fetchedAt: now
        )
        XCTAssertFalse(MenuBarViewModel.computeIsFreePlan(plan: "Free", snapshot: snap))
    }

    func testPlaceholderZeroesIsStillFree() {
        // Before first fetch, snapshot is zeroes() and fetchedAt is .distantPast.
        // We must show the overlay here to avoid empty charts.
        let snap = UsageSnapshot.zeroes()
        XCTAssertTrue(MenuBarViewModel.computeIsFreePlan(plan: "Free", snapshot: snap))
    }
}
