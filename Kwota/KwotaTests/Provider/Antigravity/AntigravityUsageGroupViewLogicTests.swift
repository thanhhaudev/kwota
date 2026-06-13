//
//  AntigravityUsageGroupViewLogicTests.swift
//

import XCTest
import SwiftUI
@testable import Kwota

final class AntigravityUsageGroupViewLogicTests: XCTestCase {
    private func quota() -> AntigravityQuotaSummary {
        AntigravityQuotaSummary(
            fetchedAt: Date(timeIntervalSince1970: 1),
            groups: [
                .init(displayName: "Gemini Models", description: nil, buckets: [
                    .init(bucketId: "gemini-5h", displayName: "Five Hour Limit", window: .fiveHour, remainingFraction: 0.2, resetTime: nil)]),  // 80%
                .init(displayName: "Claude and GPT models", description: nil, buckets: [
                    .init(bucketId: "3p-weekly", displayName: "Weekly Limit", window: .weekly, remainingFraction: 0.08, resetTime: nil)])    // 92%
            ])
    }

    func test_defaultSelectedGroup_isBindingGroup() {
        XCTAssertEqual(AntigravityUsageGroupLogic.defaultSelection(quota: quota()), "3p")
    }

    func test_resolveSelection_fallsBackWhenKeyMissing() {
        XCTAssertEqual(AntigravityUsageGroupLogic.resolvedKey(selected: "nope", quota: quota()), "3p")
        XCTAssertEqual(AntigravityUsageGroupLogic.resolvedKey(selected: "gemini", quota: quota()), "gemini")
    }

    func test_segmentDotColor_tracksGroupWorst() {
        XCTAssertEqual(AntigravityUsageGroupLogic.dotColor(for: quota().groups[1]), UsageLevel.tint(for: 92))
        XCTAssertEqual(AntigravityUsageGroupLogic.dotColor(for: quota().groups[0]), UsageLevel.tint(for: 80))
    }

    func test_chartInput_mapsSelectedGroupWindows() {
        let g = quota().groups[0] // Gemini: 5h 80%, no weekly
        let input = AntigravityUsageGroupLogic.chartInput(for: g, fetchedAt: quota().fetchedAt)
        XCTAssertEqual(input.fiveHour?.utilization ?? -1, 80, accuracy: 0.001)
        XCTAssertNil(input.sevenDay?.utilization)
        XCTAssertTrue(input.hasRealData)
    }
}
