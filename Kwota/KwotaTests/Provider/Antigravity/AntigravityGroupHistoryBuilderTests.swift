//
//  AntigravityGroupHistoryBuilderTests.swift
//

import XCTest
@testable import Kwota

final class AntigravityGroupHistoryBuilderTests: XCTestCase {
    private func quota() -> AntigravityQuotaSummary {
        AntigravityQuotaSummary(
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            groups: [
                .init(displayName: "Gemini Models", description: nil, buckets: [
                    .init(bucketId: "gemini-weekly", displayName: "Weekly Limit", window: .weekly, remainingFraction: 1, resetTime: nil),
                    .init(bucketId: "gemini-5h", displayName: "Five Hour Limit", window: .fiveHour, remainingFraction: 0.2, resetTime: nil)]),
                .init(displayName: "Claude and GPT models", description: nil, buckets: [
                    .init(bucketId: "3p-weekly", displayName: "Weekly Limit", window: .weekly, remainingFraction: 0.08, resetTime: nil),
                    .init(bucketId: "3p-5h", displayName: "Five Hour Limit", window: .fiveHour, remainingFraction: 1, resetTime: nil)])
            ])
    }

    func test_entries_oneEntryPerGroup_fiveHourAndWeeklyMapped() {
        let at = Date(timeIntervalSince1970: 2_000)
        let out = AntigravityGroupHistoryBuilder.entries(from: quota(), at: at)
        XCTAssertEqual(out.count, 2)
        let gemini = out.first { $0.key == "gemini" }
        XCTAssertEqual(gemini?.entry.at, at)
        XCTAssertEqual(gemini?.entry.fiveHour ?? -1, 80, accuracy: 0.001)
        XCTAssertEqual(gemini?.entry.sevenDay ?? -1, 0, accuracy: 0.001)

        let third = out.first { $0.key == "3p" }
        XCTAssertEqual(third?.entry.fiveHour ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(third?.entry.sevenDay ?? -1, 92, accuracy: 0.001)
    }

    func test_entries_emptyQuota_noEntries() {
        let out = AntigravityGroupHistoryBuilder.entries(
            from: AntigravityQuotaSummary(fetchedAt: Date(), groups: []), at: Date())
        XCTAssertTrue(out.isEmpty)
    }
}
