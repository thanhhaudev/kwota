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
        XCTAssertEqual(first.first?.body, "P: Short-window quota at 90%.")

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
        XCTAssertTrue(after.contains(where: { $0.body == "P: Short-window quota reset. Full quota available." }))

        let regrew = summary(primary: 95, primaryReset: baseReset)
        let again = d.evaluate(profile: p, settings: s, current: regrew, previous: reset, now: now)
        XCTAssertTrue(again.contains(where: { $0.body == "P: Short-window quota at 90%." }))
    }

    func test_longWindow_threshold() {
        let d = NotificationDispatcher()
        let p = makeProfile()
        let s = settings(short: [], long: [100])
        let prev = summary(primary: 0, primaryReset: baseReset, secondary: 90, secondaryReset: baseReset)
        let next = summary(primary: 0, primaryReset: baseReset, secondary: 100, secondaryReset: baseReset)

        let intents = d.evaluate(profile: p, settings: s, current: next, previous: prev, now: now)
        XCTAssertEqual(intents.first?.body, "P: Long-window quota at 100%.")
    }

    func test_antigravityProfile_usesProviderSpecificBodyText() {
        let d = NotificationDispatcher()
        var p = makeProfile()
        p.providerID = .antigravity
        let s = settings(short: [90], long: [100], reset: true)

        // Threshold cross — short window
        let preShort = summary(primary: 70, primaryReset: baseReset, secondary: 0, secondaryReset: baseReset)
        let crossShort = summary(primary: 95, primaryReset: baseReset, secondary: 0, secondaryReset: baseReset)
        let shortIntents = d.evaluate(profile: p, settings: s, current: crossShort, previous: preShort, now: now)
        XCTAssertEqual(shortIntents.first?.body, "P: Top model rate limit at 90%.")

        // Threshold cross — long window (AI Credits)
        let preLong = summary(primary: 95, primaryReset: baseReset, secondary: 50, secondaryReset: baseReset)
        let crossLong = summary(primary: 95, primaryReset: baseReset, secondary: 100, secondaryReset: baseReset)
        let longIntents = d.evaluate(profile: p, settings: s, current: crossLong, previous: preLong, now: now)
        XCTAssertEqual(longIntents.first?.body, "P: AI Credits at 100%.")

        // Reset detection — short window (rate-limit clears)
        let resetShort = summary(primary: 0, primaryReset: baseReset, secondary: 100, secondaryReset: baseReset)
        let resetShortIntents = d.evaluate(profile: p, settings: s, current: resetShort, previous: crossLong, now: now)
        XCTAssertTrue(resetShortIntents.contains(where: { $0.body == "P: Model rate limits cleared. All models full." }))

        // Reset detection — long window (AI Credits refilled)
        let resetLong = summary(primary: 0, primaryReset: baseReset, secondary: 0, secondaryReset: baseReset)
        let resetLongIntents = d.evaluate(profile: p, settings: s, current: resetLong, previous: resetShort, now: now)
        XCTAssertTrue(resetLongIntents.contains(where: { $0.body == "P: AI Credits refilled." }))
    }

    func test_title_includesProviderAndPlan() {
        let d = NotificationDispatcher()
        var p = makeProfile()
        p.subscriptionPlan = "Pro"
        let s = settings(short: [90])
        let prev = summary(primary: 70, primaryReset: baseReset)
        let next = summary(primary: 92, primaryReset: baseReset)

        let intents = d.evaluate(profile: p, settings: s, current: next, previous: prev, now: now)
        XCTAssertEqual(intents.first?.title, "Kwota — Claude · Pro")
    }

    func test_title_omitsPlanSegmentWhenBlank() {
        let d = NotificationDispatcher()
        var p = makeProfile()
        p.providerID = .antigravity
        p.subscriptionPlan = nil  // nil plan → no plan segment in the title
        let s = settings(short: [90])
        let prev = summary(primary: 70, primaryReset: baseReset)
        let next = summary(primary: 92, primaryReset: baseReset)

        let intents = d.evaluate(profile: p, settings: s, current: next, previous: prev, now: now)
        XCTAssertEqual(intents.first?.title, "Kwota — Antigravity")
    }

    func test_title_omitsPlanSegmentWhenWhitespaceOnly() {
        let d = NotificationDispatcher()
        var p = makeProfile()
        p.subscriptionPlan = "  \n "  // whitespace-only trims to empty → no plan segment
        let s = settings(short: [90])
        let prev = summary(primary: 70, primaryReset: baseReset)
        let next = summary(primary: 92, primaryReset: baseReset)

        let intents = d.evaluate(profile: p, settings: s, current: next, previous: prev, now: now)
        XCTAssertEqual(intents.first?.title, "Kwota — Claude")
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
