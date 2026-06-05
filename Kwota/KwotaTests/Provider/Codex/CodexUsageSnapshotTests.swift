//
//  CodexUsageSnapshotTests.swift
//

import XCTest
@testable import Kwota

final class CodexUsageSnapshotTests: XCTestCase {
    func test_decodes_fullResponse() throws {
        let json = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window":   { "used_percent": 27, "limit_window_seconds": 18000,  "reset_at": "2026-05-25T18:22:00Z" },
            "secondary_window": { "used_percent": 46, "limit_window_seconds": 604800, "reset_at": "2026-05-29T09:15:00Z" }
          },
          "code_review_rate_limit": { "used_percent": 9, "limit_window_seconds": 604800, "reset_at": "2026-05-31T14:30:00Z" },
          "credits": { "has_credits": true, "unlimited": false, "balance": 12.34 }
        }
        """.data(using: .utf8)!

        let snap = try CodexUsageSnapshot.decoder.decode(CodexUsageSnapshot.self, from: json)
        XCTAssertEqual(snap.planType, "plus")
        XCTAssertEqual(snap.rateLimit?.primaryWindow?.usedPercent, 27)
        XCTAssertEqual(snap.rateLimit?.primaryWindow?.limitWindowSeconds, 18000)
        XCTAssertNotNil(snap.rateLimit?.primaryWindow?.resetAt)
        XCTAssertEqual(snap.rateLimit?.secondaryWindow?.usedPercent, 46)
        XCTAssertEqual(snap.codeReviewRateLimit?.usedPercent, 9)
        XCTAssertEqual(snap.credits?.hasCredits, true)
        XCTAssertEqual(snap.credits?.unlimited, false)
        XCTAssertEqual(snap.credits?.balance, 12.34)
    }

    func test_decodes_partialResponse_missingSections() throws {
        let json = """
        {
          "plan_type": "free",
          "rate_limit": {
            "primary_window": { "used_percent": 5, "limit_window_seconds": 18000, "reset_at": "2026-05-25T18:22:00Z" }
          }
        }
        """.data(using: .utf8)!

        let snap = try CodexUsageSnapshot.decoder.decode(CodexUsageSnapshot.self, from: json)
        XCTAssertEqual(snap.planType, "free")
        XCTAssertEqual(snap.rateLimit?.primaryWindow?.usedPercent, 5)
        XCTAssertNil(snap.rateLimit?.secondaryWindow)
        XCTAssertNil(snap.codeReviewRateLimit)
        XCTAssertNil(snap.credits)
    }

    func test_decodes_balanceAsString() throws {
        // wham/usage observed live (2026-05) returns credits.balance as a
        // string ("12.34") on paid plans. Older fixtures send a number. The
        // decoder must accept both — every fall-through error here blanks the
        // popover with no banner, so this is a regression fence.
        let json = """
        {
          "plan_type": "plus",
          "credits": { "has_credits": true, "unlimited": false, "balance": "12.34" }
        }
        """.data(using: .utf8)!

        let snap = try CodexUsageSnapshot.decoder.decode(CodexUsageSnapshot.self, from: json)
        XCTAssertEqual(snap.credits?.balance, 12.34)
    }

    func test_decodes_balanceUnparseableString_yieldsNil() throws {
        // If the server ever sends garbage in the string field, we shouldn't
        // throw — just degrade to nil so the rest of the snapshot still lands.
        let json = """
        {
          "credits": { "has_credits": true, "balance": "not-a-number" }
        }
        """.data(using: .utf8)!

        let snap = try CodexUsageSnapshot.decoder.decode(CodexUsageSnapshot.self, from: json)
        XCTAssertNil(snap.credits?.balance)
        XCTAssertEqual(snap.credits?.hasCredits, true)
    }

    func test_decodes_resetAtAsUnixEpochNumber() throws {
        // wham/usage observed live (2026-05) returns reset_at as a Unix epoch
        // number, not an ISO8601 string. The decoder must accept both: epoch
        // for fresh server payloads, ISO8601 for older persisted snapshots.
        let json = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window":   { "used_percent": 27, "limit_window_seconds": 18000,  "reset_at": 1748196120 },
            "secondary_window": { "used_percent": 46, "limit_window_seconds": 604800, "reset_at": 1748509200.5 }
          }
        }
        """.data(using: .utf8)!

        let snap = try CodexUsageSnapshot.decoder.decode(CodexUsageSnapshot.self, from: json)
        XCTAssertEqual(
            snap.rateLimit?.primaryWindow?.resetAt,
            Date(timeIntervalSince1970: 1748196120)
        )
        XCTAssertEqual(
            snap.rateLimit?.secondaryWindow?.resetAt,
            Date(timeIntervalSince1970: 1748509200.5)
        )
    }

    func test_decodes_empty_doesNotThrow() throws {
        let json = Data("{}".utf8)
        let snap = try CodexUsageSnapshot.decoder.decode(CodexUsageSnapshot.self, from: json)
        XCTAssertNil(snap.planType)
        XCTAssertNil(snap.rateLimit)
        XCTAssertNil(snap.codeReviewRateLimit)
        XCTAssertNil(snap.credits)
    }
}
