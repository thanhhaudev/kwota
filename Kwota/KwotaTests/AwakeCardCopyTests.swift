//
//  AwakeCardCopyTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class AwakeCardCopyTests: XCTestCase {

    // MARK: - Title

    func test_title_idle_autoOff() {
        XCTAssertEqual(
            AwakeCardCopy.title(state: .idle, autoEnabled: false),
            "Ready"
        )
    }

    func test_title_idle_autoOn() {
        XCTAssertEqual(
            AwakeCardCopy.title(state: .idle, autoEnabled: true),
            "Standby"
        )
    }

    func test_title_autoActive() {
        let since = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            AwakeCardCopy.title(state: .autoActive(since: since), autoEnabled: true),
            "Auto awake"
        )
    }

    func test_title_manualActive() {
        let since = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            AwakeCardCopy.title(state: .manualActive(since: since, timeout: nil), autoEnabled: false),
            "Manual awake"
        )
    }

    func test_title_batteryBlocked() {
        XCTAssertEqual(
            AwakeCardCopy.title(state: .batteryBlocked, autoEnabled: true),
            "Paused"
        )
    }

    // MARK: - Subtitle

    func test_subtitle_idle_autoOff() {
        let s = AwakeCardCopy.subtitle(
            state: .idle,
            autoEnabled: false,
            now: Date(),
            lastActivity: nil,
            batteryPct: nil,
            batteryThreshold: nil
        )
        XCTAssertEqual(s, "")
    }

    func test_subtitle_idle_autoOn() {
        let s = AwakeCardCopy.subtitle(
            state: .idle,
            autoEnabled: true,
            now: Date(),
            lastActivity: nil,
            batteryPct: nil,
            batteryThreshold: nil
        )
        XCTAssertEqual(s, "Waiting for agent activity")
    }

    func test_subtitle_idle_autoOn_gateEnabled_userActive_showsStaticGateCopy() {
        // Gate enabled + recent activity, user still at the keyboard →
        // static copy naming the gate duration.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let recentActivity = now.addingTimeInterval(-60)     // 1 min ago — within 5-min window
        let s = AwakeCardCopy.subtitle(
            state: .idle,
            autoEnabled: true,
            now: now,
            lastActivity: recentActivity,
            batteryPct: nil,
            batteryThreshold: nil,
            userIdleSeconds: 0,
            gateSeconds: 60
        )
        XCTAssertEqual(s, "Agent active — starts auto-awake after 1 min away")
    }

    func test_subtitle_idle_autoOn_gateEnabled_userActive_subMinuteGateLabel() {
        // 30-second gate renders in seconds, matching the Settings picker label.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let recentActivity = now.addingTimeInterval(-60)
        let s = AwakeCardCopy.subtitle(
            state: .idle,
            autoEnabled: true,
            now: now,
            lastActivity: recentActivity,
            batteryPct: nil,
            batteryThreshold: nil,
            userIdleSeconds: 0,
            gateSeconds: 30
        )
        XCTAssertEqual(s, "Agent active — starts auto-awake after 30 s away")
    }

    func test_subtitle_idle_autoOn_gateEnabled_idleBelowRevealThreshold_staysStatic() {
        // A brief typing pause must not flip the line into a countdown.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let recentActivity = now.addingTimeInterval(-60)
        let s = AwakeCardCopy.subtitle(
            state: .idle,
            autoEnabled: true,
            now: now,
            lastActivity: recentActivity,
            batteryPct: nil,
            batteryThreshold: nil,
            userIdleSeconds: AwakeCardCopy.countdownRevealThreshold - 1,
            gateSeconds: 60
        )
        XCTAssertEqual(s, "Agent active — starts auto-awake after 1 min away")
    }

    func test_subtitle_idle_autoOn_gateEnabled_userAway_showsCountdown() {
        // User idle past the reveal threshold → live countdown to gate-open.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let recentActivity = now.addingTimeInterval(-60)
        let s = AwakeCardCopy.subtitle(
            state: .idle,
            autoEnabled: true,
            now: now,
            lastActivity: recentActivity,
            batteryPct: nil,
            batteryThreshold: nil,
            userIdleSeconds: 18,
            gateSeconds: 60
        )
        XCTAssertEqual(s, "Agent active — auto-awake in 0m 42s")
    }

    func test_subtitle_idle_autoOn_gateEnabled_idlePastGate_clampsAtZero() {
        // Gate already open but no agent pulse yet → clamp at zero, don't go negative.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let recentActivity = now.addingTimeInterval(-60)
        let s = AwakeCardCopy.subtitle(
            state: .idle,
            autoEnabled: true,
            now: now,
            lastActivity: recentActivity,
            batteryPct: nil,
            batteryThreshold: nil,
            userIdleSeconds: 75,
            gateSeconds: 60
        )
        XCTAssertEqual(s, "Agent active — auto-awake in 0m 00s")
    }

    func test_subtitle_idle_autoOn_gateOff_recentActivity_showsWaiting() {
        // Gate disabled → always show the generic "Waiting" copy even with recent activity.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let recentActivity = now.addingTimeInterval(-60)
        let s = AwakeCardCopy.subtitle(
            state: .idle,
            autoEnabled: true,
            now: now,
            lastActivity: recentActivity,
            batteryPct: nil,
            batteryThreshold: nil,
            userIdleSeconds: 120,
            gateSeconds: nil
        )
        XCTAssertEqual(s, "Waiting for agent activity")
    }

    func test_subtitle_idle_autoOn_gateEnabled_staleActivity_showsWaiting() {
        // Gate enabled but last activity was too long ago → "Waiting" (no agent to wait for).
        let now = Date(timeIntervalSince1970: 1_000_000)
        let staleActivity = now.addingTimeInterval(-400)     // > 5-min window
        let s = AwakeCardCopy.subtitle(
            state: .idle,
            autoEnabled: true,
            now: now,
            lastActivity: staleActivity,
            batteryPct: nil,
            batteryThreshold: nil,
            userIdleSeconds: 0,
            gateSeconds: 60
        )
        XCTAssertEqual(s, "Waiting for agent activity")
    }

    func test_subtitle_idle_autoOn_gateEnabled_nilActivity_showsWaiting() {
        // Gate enabled but no activity at all → "Waiting".
        let s = AwakeCardCopy.subtitle(
            state: .idle,
            autoEnabled: true,
            now: Date(timeIntervalSince1970: 1_000_000),
            lastActivity: nil,
            batteryPct: nil,
            batteryThreshold: nil,
            userIdleSeconds: 0,
            gateSeconds: 60
        )
        XCTAssertEqual(s, "Waiting for agent activity")
    }

    // MARK: - Gate countdown predicate (timer icon)

    func test_showsGateCountdown_userAway_true() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(AwakeCardCopy.showsGateCountdown(
            state: .idle,
            autoEnabled: true,
            now: now,
            lastActivity: now.addingTimeInterval(-60),
            userIdleSeconds: 18,
            gateSeconds: 60
        ))
    }

    func test_showsGateCountdown_userActive_false() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(AwakeCardCopy.showsGateCountdown(
            state: .idle,
            autoEnabled: true,
            now: now,
            lastActivity: now.addingTimeInterval(-60),
            userIdleSeconds: AwakeCardCopy.countdownRevealThreshold - 1,
            gateSeconds: 60
        ))
    }

    func test_showsGateCountdown_gateOff_false() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(AwakeCardCopy.showsGateCountdown(
            state: .idle,
            autoEnabled: true,
            now: now,
            lastActivity: now.addingTimeInterval(-60),
            userIdleSeconds: 120,
            gateSeconds: nil
        ))
    }

    func test_showsGateCountdown_staleActivity_false() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(AwakeCardCopy.showsGateCountdown(
            state: .idle,
            autoEnabled: true,
            now: now,
            lastActivity: now.addingTimeInterval(-400),
            userIdleSeconds: 18,
            gateSeconds: 60
        ))
    }

    func test_showsGateCountdown_nonIdleState_false() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(AwakeCardCopy.showsGateCountdown(
            state: .autoActive(since: now),
            autoEnabled: true,
            now: now,
            lastActivity: now.addingTimeInterval(-60),
            userIdleSeconds: 18,
            gateSeconds: 60
        ))
    }

    func test_subtitle_autoActive_withRecentActivity() {
        let since = Date(timeIntervalSince1970: 1_000_000)        // 14:46:40 UTC
        let now   = since.addingTimeInterval(120)                 // 2 minutes later
        let lastActivity = now.addingTimeInterval(-90)            // 1.5 min ago → rounds to "1m"
        let s = AwakeCardCopy.subtitle(
            state: .autoActive(since: since),
            autoEnabled: true,
            now: now,
            lastActivity: lastActivity,
            batteryPct: nil,
            batteryThreshold: nil
        )
        XCTAssertEqual(s, "Last activity 1m ago")
    }

    func test_subtitle_autoActive_oldActivity_omitsClause() {
        let since = Date(timeIntervalSince1970: 1_000_000)
        let now   = since.addingTimeInterval(600)                 // 10 minutes later
        let lastActivity = now.addingTimeInterval(-600)           // 10 min ago → over threshold
        let s = AwakeCardCopy.subtitle(
            state: .autoActive(since: since),
            autoEnabled: true,
            now: now,
            lastActivity: lastActivity,
            batteryPct: nil,
            batteryThreshold: nil
        )
        XCTAssertTrue(s.hasPrefix("Active since "), "got: \(s)")
        XCTAssertFalse(s.contains("last activity"), "got: \(s)")
    }

    // MARK: - Subtitle provider attribution

    func test_subtitle_autoActive_withProvider_recentActivity() {
        let since = Date(timeIntervalSince1970: 1_000_000)
        let now   = since.addingTimeInterval(120)
        let lastActivity = now.addingTimeInterval(-90)            // 1.5 min ago → "1m ago"
        let s = AwakeCardCopy.subtitle(
            state: .autoActive(since: since),
            autoEnabled: true,
            now: now,
            lastActivity: lastActivity,
            batteryPct: nil,
            batteryThreshold: nil,
            activeProviderNames: ["Codex"]
        )
        XCTAssertEqual(s, "Codex is working · last activity 1m ago")
    }

    func test_subtitle_autoActive_twoProviders_recentActivity() {
        let since = Date(timeIntervalSince1970: 1_000_000)
        let now   = since.addingTimeInterval(120)
        let lastActivity = now.addingTimeInterval(-90)
        let s = AwakeCardCopy.subtitle(
            state: .autoActive(since: since),
            autoEnabled: true,
            now: now,
            lastActivity: lastActivity,
            batteryPct: nil,
            batteryThreshold: nil,
            activeProviderNames: ["Claude", "Codex"]
        )
        XCTAssertEqual(s, "Claude and Codex are working · last activity 1m ago")
    }

    func test_subtitle_autoActive_threeProviders_recentActivity() {
        let since = Date(timeIntervalSince1970: 1_000_000)
        let now   = since.addingTimeInterval(120)
        let lastActivity = now.addingTimeInterval(-90)
        let s = AwakeCardCopy.subtitle(
            state: .autoActive(since: since),
            autoEnabled: true,
            now: now,
            lastActivity: lastActivity,
            batteryPct: nil,
            batteryThreshold: nil,
            activeProviderNames: ["Claude", "Codex", "Antigravity"]
        )
        XCTAssertEqual(s, "Claude, Codex and Antigravity are working · last activity 1m ago")
    }

    func test_subtitle_autoActive_withProvider_oldActivity() {
        let since = Date(timeIntervalSince1970: 1_000_000)
        let now   = since.addingTimeInterval(600)
        let lastActivity = now.addingTimeInterval(-600)           // over threshold
        let s = AwakeCardCopy.subtitle(
            state: .autoActive(since: since),
            autoEnabled: true,
            now: now,
            lastActivity: lastActivity,
            batteryPct: nil,
            batteryThreshold: nil,
            activeProviderNames: ["Codex"]
        )
        XCTAssertTrue(s.hasPrefix("Codex is working · active since "), "got: \(s)")
    }

    func test_subtitle_autoActive_noProvider_recentActivity_matchesLegacy() {
        let since = Date(timeIntervalSince1970: 1_000_000)
        let now   = since.addingTimeInterval(120)
        let lastActivity = now.addingTimeInterval(-90)
        let s = AwakeCardCopy.subtitle(
            state: .autoActive(since: since),
            autoEnabled: true,
            now: now,
            lastActivity: lastActivity,
            batteryPct: nil,
            batteryThreshold: nil,
            activeProviderNames: []
        )
        XCTAssertEqual(s, "Last activity 1m ago")
    }

    func test_subtitle_autoActive_noProvider_oldActivity_matchesLegacy() {
        let since = Date(timeIntervalSince1970: 1_000_000)
        let now   = since.addingTimeInterval(600)
        let lastActivity = now.addingTimeInterval(-600)
        let s = AwakeCardCopy.subtitle(
            state: .autoActive(since: since),
            autoEnabled: true,
            now: now,
            lastActivity: lastActivity,
            batteryPct: nil,
            batteryThreshold: nil,
            activeProviderNames: []
        )
        XCTAssertTrue(s.hasPrefix("Active since "), "got: \(s)")
    }

    func test_subtitle_manualActive_noTimeout() {
        let since = Date(timeIntervalSince1970: 1_000_000)
        let s = AwakeCardCopy.subtitle(
            state: .manualActive(since: since, timeout: nil),
            autoEnabled: false,
            now: since.addingTimeInterval(60),
            lastActivity: nil,
            batteryPct: nil,
            batteryThreshold: nil
        )
        XCTAssertEqual(s, "No auto-stop")
    }

    func test_subtitle_manualActive_withTimeout() {
        let since = Date(timeIntervalSince1970: 1_000_000)
        let s = AwakeCardCopy.subtitle(
            state: .manualActive(since: since, timeout: 3600),
            autoEnabled: false,
            now: since.addingTimeInterval(60),
            lastActivity: nil,
            batteryPct: nil,
            batteryThreshold: nil
        )
        XCTAssertEqual(s, "59m 00s left")
    }

    func test_subtitle_batteryBlocked_withReading() {
        let s = AwakeCardCopy.subtitle(
            state: .batteryBlocked,
            autoEnabled: true,
            now: Date(),
            lastActivity: nil,
            batteryPct: 18,
            batteryThreshold: 20
        )
        XCTAssertEqual(s, "Battery 18% (below 20% threshold)")
    }

    func test_subtitle_batteryBlocked_noReading() {
        let s = AwakeCardCopy.subtitle(
            state: .batteryBlocked,
            autoEnabled: true,
            now: Date(),
            lastActivity: nil,
            batteryPct: nil,
            batteryThreshold: nil
        )
        XCTAssertEqual(s, "Battery below threshold")
    }

    // MARK: - Body kind

    func test_bodyKind_idle_autoOff() {
        XCTAssertEqual(
            AwakeCardCopy.bodyKind(state: .idle, autoEnabled: false),
            .startControls
        )
    }

    func test_bodyKind_idle_autoOn() {
        XCTAssertEqual(
            AwakeCardCopy.bodyKind(state: .idle, autoEnabled: true),
            .empty
        )
    }

    func test_bodyKind_autoActive() {
        XCTAssertEqual(
            AwakeCardCopy.bodyKind(
                state: .autoActive(since: Date()),
                autoEnabled: true
            ),
            .empty
        )
    }

    func test_bodyKind_manualActive() {
        XCTAssertEqual(
            AwakeCardCopy.bodyKind(
                state: .manualActive(since: Date(), timeout: nil),
                autoEnabled: false
            ),
            .stop
        )
    }

    func test_bodyKind_batteryBlocked() {
        XCTAssertEqual(
            AwakeCardCopy.bodyKind(state: .batteryBlocked, autoEnabled: true),
            .batteryBlocked
        )
    }
}
