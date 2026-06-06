//
//  NotificationDispatcherTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class NotificationDispatcherTests: XCTestCase {

    private func makeProfile(cli: Bool = true, muted: Bool = false) -> Profile {
        var p = Profile(id: UUID(), name: "P", authMethod: cli ? .cliSync : .sessionKey)
        p.notificationsMuted = muted
        return p
    }

    private func settings(
        short: Set<Int> = [90],
        long: Set<Int> = [],
        reset: Bool = false,
        tokenExpiry: Bool = false
    ) -> NotificationSettings {
        NotificationSettings(
            shortWindowThresholds: short,
            longWindowThresholds: long,
            notifyOnReset: reset,
            notifyOnTokenExpiry: tokenExpiry
        )
    }

    private func summary(
        primary: Double?,
        primaryReset: Date,
        secondary: Double? = nil,
        secondaryReset: Date? = nil
    ) -> ProviderUsageSummary {
        ProviderUsageSummary(
            providerID: .claude,
            fetchedAt: Date(),
            primary: UsageBucket(utilization: primary, resetsAt: primaryReset),
            secondary: secondary.map { UsageBucket(utilization: $0, resetsAt: secondaryReset) },
            payload: 0,
            retryAfter: nil
        )
    }

    private let baseReset = Date(timeIntervalSince1970: 1_750_000_000)
    private let now = Date(timeIntervalSince1970: 1_749_990_000)

    func test_thresholdCrossing_firesOnce() {
        let d = NotificationDispatcher()
        let p = makeProfile()
        let s = settings(short: [90])
        let prev = summary(primary: 70, primaryReset: baseReset)
        let next = summary(primary: 92, primaryReset: baseReset)

        let first = d.evaluate(profile: p, settings: s, current: next, previous: prev, now: now)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.body, "Short-window quota at 90%.")

        let second = d.evaluate(profile: p, settings: s, current: next, previous: prev, now: now)
        XCTAssertTrue(second.isEmpty, "Should dedup until the next reset")
    }

    func test_mutedProfile_emitsNothing() {
        let d = NotificationDispatcher()
        let p = makeProfile(muted: true)
        let s = settings(short: [75, 90, 100], long: [75, 90, 100], reset: true, tokenExpiry: true)
        let prev = summary(primary: 0, primaryReset: baseReset, secondary: 0, secondaryReset: baseReset)
        let next = summary(primary: 100, primaryReset: baseReset, secondary: 100, secondaryReset: baseReset)

        XCTAssertTrue(
            d.evaluate(profile: p, settings: s, current: next, previous: prev, now: now).isEmpty
        )
    }

    func test_resetClearsDedup_andFiresReset() {
        let d = NotificationDispatcher()
        let p = makeProfile()
        let s = settings(short: [90], reset: true)

        let pre = summary(primary: 80, primaryReset: baseReset)
        let high = summary(primary: 95, primaryReset: baseReset)
        _ = d.evaluate(profile: p, settings: s, current: high, previous: pre, now: now)

        let reset = summary(primary: 2, primaryReset: baseReset)
        let after = d.evaluate(profile: p, settings: s, current: reset, previous: high, now: now)
        XCTAssertTrue(after.contains(where: { $0.body == "Short-window quota reset. Full quota available." }))

        let regrew = summary(primary: 95, primaryReset: baseReset)
        let again = d.evaluate(profile: p, settings: s, current: regrew, previous: reset, now: now)
        XCTAssertTrue(again.contains(where: { $0.body == "Short-window quota at 90%." }))
    }

    func test_longWindow_threshold() {
        let d = NotificationDispatcher()
        let p = makeProfile()
        let s = settings(short: [], long: [100])
        let prev = summary(primary: 0, primaryReset: baseReset, secondary: 90, secondaryReset: baseReset)
        let next = summary(primary: 0, primaryReset: baseReset, secondary: 100, secondaryReset: baseReset)

        let intents = d.evaluate(profile: p, settings: s, current: next, previous: prev, now: now)
        XCTAssertEqual(intents.first?.body, "Long-window quota at 100%.")
    }

    func test_tokenExpiry_onlyFiresForCliSyncProfile() {
        let d = NotificationDispatcher()
        let s = settings(tokenExpiry: true)
        let summaryNow = summary(primary: 10, primaryReset: baseReset)
        let expiry = Date(timeInterval: 3600, since: now)

        var web = makeProfile(cli: false)
        web.sessionKeyExpiresAt = expiry
        let webIntents = d.evaluate(profile: web, settings: s, current: summaryNow, previous: nil, now: now)
        XCTAssertFalse(webIntents.contains(where: {
            if case .tokenExpiry = $0.rule { return true }
            return false
        }))

        var cli = makeProfile(cli: true)
        cli.sessionKeyExpiresAt = expiry
        let cliIntents = d.evaluate(profile: cli, settings: s, current: summaryNow, previous: nil, now: now)
        XCTAssertTrue(cliIntents.contains(where: {
            if case .tokenExpiry = $0.rule { return true }
            return false
        }))
    }
}
