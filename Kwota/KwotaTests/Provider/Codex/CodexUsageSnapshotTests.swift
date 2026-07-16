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

    // MARK: - classifiedWindows (duration-based, not slot-based)

    private func snapshot(from json: String) throws -> CodexUsageSnapshot {
        try CodexUsageSnapshot.decoder.decode(
            CodexUsageSnapshot.self, from: Data(json.utf8))
    }

    func test_classifiedWindows_historicalBothWindows_mapsByDuration() throws {
        // Historical shape: 5-hour in primary_window, weekly in secondary_window.
        let snap = try snapshot(from: """
        { "rate_limit": {
            "primary_window":   { "used_percent": 27, "limit_window_seconds": 18000 },
            "secondary_window": { "used_percent": 46, "limit_window_seconds": 604800 }
        } }
        """)
        let w = snap.classifiedWindows
        XCTAssertEqual(w.session?.usedPercent, 27)
        XCTAssertEqual(w.weekly?.usedPercent, 46)
    }

    func test_classifiedWindows_currentShape_weeklyInPrimary_secondaryNull() throws {
        // 2026-07 live shape: OpenAI moved the weekly window into
        // primary_window (604800s) and nulled secondary_window. Positional
        // reads mislabel this weekly usage as the 5-hour session; the classifier
        // must land it on weekly and leave session empty.
        let snap = try snapshot(from: """
        { "rate_limit": {
            "primary_window":   { "used_percent": 17, "limit_window_seconds": 604800 },
            "secondary_window": null
        } }
        """)
        let w = snap.classifiedWindows
        XCTAssertNil(w.session, "no 5-hour window present → session must be nil")
        XCTAssertEqual(w.weekly?.usedPercent, 17)
    }

    func test_classifiedWindows_sessionOnly_noWeekly() throws {
        // e.g. a shape where only the 5-hour burst window is active.
        let snap = try snapshot(from: """
        { "rate_limit": {
            "primary_window": { "used_percent": 5, "limit_window_seconds": 18000 }
        } }
        """)
        let w = snap.classifiedWindows
        XCTAssertEqual(w.session?.usedPercent, 5)
        XCTAssertNil(w.weekly)
    }

    func test_classifiedWindows_slotsSwapped_stillClassifyByDuration() throws {
        // Defensive: if OpenAI ever puts weekly in primary and 5-hour in
        // secondary, duration classification keeps them in the right cards.
        let snap = try snapshot(from: """
        { "rate_limit": {
            "primary_window":   { "used_percent": 80, "limit_window_seconds": 604800 },
            "secondary_window": { "used_percent": 12, "limit_window_seconds": 18000 }
        } }
        """)
        let w = snap.classifiedWindows
        XCTAssertEqual(w.session?.usedPercent, 12, "5-hour window → session regardless of slot")
        XCTAssertEqual(w.weekly?.usedPercent, 80, "weekly window → weekly regardless of slot")
    }

    func test_classifiedWindows_durationless_fallsBackToSlotOrder() throws {
        // Some payloads omit limit_window_seconds entirely. With no duration
        // signal, keep the historical slot meaning: primary → session,
        // secondary → weekly. This is what the pre-classifier fetchUsage tests
        // relied on, so the fallback preserves them.
        let snap = try snapshot(from: """
        { "rate_limit": {
            "primary_window":   { "used_percent": 27 },
            "secondary_window": { "used_percent": 46 }
        } }
        """)
        let w = snap.classifiedWindows
        XCTAssertEqual(w.session?.usedPercent, 27)
        XCTAssertEqual(w.weekly?.usedPercent, 46)
    }

    func test_classifiedWindows_noRateLimit_bothNil() throws {
        let snap = try snapshot(from: "{}")
        let w = snap.classifiedWindows
        XCTAssertNil(w.session)
        XCTAssertNil(w.weekly)
    }
}
