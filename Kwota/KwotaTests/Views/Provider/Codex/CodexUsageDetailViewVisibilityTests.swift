//
//  CodexUsageDetailViewVisibilityTests.swift
//
//  Locks the "adapt to whichever windows the server sends" card-visibility
//  rule that replaced the fixed Session-then-Weekly layout when OpenAI
//  collapsed Codex to a single weekly window (2026-07).
//

import XCTest
@testable import Kwota

final class CodexUsageDetailViewVisibilityTests: XCTestCase {
    private func vis(session: Bool, weekly: Bool, free: Bool = false)
        -> (showSession: Bool, showWeekly: Bool) {
        CodexUsageDetailView.cardVisibility(
            hasSession: session, hasWeekly: weekly, isFreePlan: free)
    }

    func test_bothWindows_showsBothCards() {
        let v = vis(session: true, weekly: true)
        XCTAssertTrue(v.showSession)
        XCTAssertTrue(v.showWeekly)
    }

    func test_weeklyOnly_hidesSession_showsWeekly() {
        // Today's OpenAI shape: only a weekly window. An empty 5-hour card
        // would imply a burst limit that no longer exists, so hide it.
        let v = vis(session: false, weekly: true)
        XCTAssertFalse(v.showSession)
        XCTAssertTrue(v.showWeekly)
    }

    func test_sessionOnly_showsSession_hidesWeekly() {
        let v = vis(session: true, weekly: false)
        XCTAssertTrue(v.showSession)
        XCTAssertFalse(v.showWeekly)
    }

    func test_neitherWindow_showsSessionPlaceholder_hidesWeekly() {
        // rate_limit: null (intermittent 200). Keep the session card as the
        // "waiting for data" placeholder so the tab is never fully blank.
        let v = vis(session: false, weekly: false)
        XCTAssertTrue(v.showSession)
        XCTAssertFalse(v.showWeekly)
    }

    func test_freePlan_weeklyPresent_hidesWeekly() {
        // Free tier's weekly window is not a meaningful limit — keep the
        // original free-plan suppression even if a weekly window is sent.
        let v = vis(session: true, weekly: true, free: true)
        XCTAssertTrue(v.showSession)
        XCTAssertFalse(v.showWeekly)
    }
}
