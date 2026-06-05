//
//  ProviderUsageSummaryTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class ProviderUsageSummaryTests: XCTestCase {
    func testWrapsClaudeSnapshotPreservingPrimaryAndSecondary() {
        let snap = UsageSnapshot(
            fiveHour: UsageBucket(utilization: 42, resetsAt: nil),
            sevenDay: UsageBucket(utilization: 17, resetsAt: nil),
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let summary = ProviderUsageSummary(
            providerID: .claude,
            fetchedAt: snap.fetchedAt,
            primary: snap.fiveHour,
            secondary: snap.sevenDay,
            payload: snap
        )
        XCTAssertEqual(summary.providerID, .claude)
        XCTAssertEqual(summary.primary?.utilization, 42)
        XCTAssertEqual(summary.secondary?.utilization, 17)
        XCTAssertNotNil(summary.payload as? UsageSnapshot)
    }

    func testNilBucketsAllowed() {
        let summary = ProviderUsageSummary(
            providerID: .claude,
            fetchedAt: Date(),
            primary: nil,
            secondary: nil,
            payload: 0 as Int
        )
        XCTAssertNil(summary.primary)
        XCTAssertNil(summary.secondary)
    }

    // MARK: - hasBucketData

    private func makeSummary(
        _ providerID: ProviderID = .codex,
        primary: Double?,
        secondary: Double?,
        fetchedAt: Date = Date()
    ) -> ProviderUsageSummary {
        ProviderUsageSummary(
            providerID: providerID,
            fetchedAt: fetchedAt,
            primary: primary.map { UsageBucket(utilization: $0, resetsAt: nil) },
            secondary: secondary.map { UsageBucket(utilization: $0, resetsAt: nil) },
            payload: 0 as Int
        )
    }

    func testHasBucketData_trueWhenEitherBucketHasUtilization() {
        XCTAssertTrue(makeSummary(primary: 12, secondary: 34).hasBucketData)
        XCTAssertTrue(makeSummary(primary: 0, secondary: nil).hasBucketData)
        XCTAssertTrue(makeSummary(primary: nil, secondary: 5).hasBucketData)
    }

    func testHasBucketData_falseWhenBothBucketsEmpty() {
        // Bucket absent entirely (Codex `rate_limit: null`)...
        XCTAssertFalse(makeSummary(primary: nil, secondary: nil).hasBucketData)
        // ...and bucket present but with nil utilization both read empty.
        let nilUtil = ProviderUsageSummary(
            providerID: .codex, fetchedAt: Date(),
            primary: UsageBucket(utilization: nil, resetsAt: Date()),
            secondary: UsageBucket(utilization: nil, resetsAt: Date()),
            payload: 0 as Int
        )
        XCTAssertFalse(nilUtil.hasBucketData)
    }

    // MARK: - shouldRetain

    func testShouldRetain_trueWhenEmptyIncomingWouldClobberGoodPrevious() {
        let previous = makeSummary(.codex, primary: 10, secondary: 20)
        let incoming = makeSummary(.codex, primary: nil, secondary: nil)
        XCTAssertTrue(ProviderUsageSummary.shouldRetain(previous: previous, over: incoming))
    }

    func testShouldRetain_falseWhenIncomingHasData() {
        let previous = makeSummary(.codex, primary: 10, secondary: 20)
        let incoming = makeSummary(.codex, primary: 1, secondary: nil)
        XCTAssertFalse(ProviderUsageSummary.shouldRetain(previous: previous, over: incoming))
    }

    func testShouldRetain_falseWhenNoPrevious() {
        let incoming = makeSummary(.codex, primary: nil, secondary: nil)
        XCTAssertFalse(ProviderUsageSummary.shouldRetain(previous: nil, over: incoming))
    }

    func testShouldRetain_falseWhenPreviousAlsoEmpty() {
        // A brand-new account that never had data must not get stuck pinned
        // to an empty snapshot — there's nothing worth retaining.
        let previous = makeSummary(.codex, primary: nil, secondary: nil)
        let incoming = makeSummary(.codex, primary: nil, secondary: nil)
        XCTAssertFalse(ProviderUsageSummary.shouldRetain(previous: previous, over: incoming))
    }

    func testShouldRetain_falseWhenProviderDiffers() {
        // Just-switched profile: the empty first fetch of the new provider
        // must not be masked by the old provider's good data.
        let previous = makeSummary(.claude, primary: 10, secondary: 20)
        let incoming = makeSummary(.codex, primary: nil, secondary: nil)
        XCTAssertFalse(ProviderUsageSummary.shouldRetain(previous: previous, over: incoming))
    }
}
