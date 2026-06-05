//
//  NotificationDispatcherTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class NotificationDispatcherTests: XCTestCase {

    private func makeProfile(
        cli: Bool = true,
        cfg: NotificationConfig = .init(
            enabled: true,
            sessionThresholds: [90],
            weeklyThresholds: [],
            notifyOnReset: false,
            notifyOnTokenExpiry: false
        )
    ) -> Profile {
        var p = Profile(id: UUID(), name: "P", authMethod: cli ? .cliSync : .sessionKey)
        p.notifications = cfg
        return p
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
        let prev = summary(primary: 70, primaryReset: baseReset)
        let next = summary(primary: 92, primaryReset: baseReset)

        let intents = d.evaluate(profile: p, current: next, previous: prev, now: now)

        XCTAssertEqual(intents.count, 1)
        XCTAssertEqual(intents.first?.rule, .session(90))
    }

    func test_alreadyFired_doesNotRefire() {
        let d = NotificationDispatcher()
        let p = makeProfile()
        let s1 = summary(primary: 92, primaryReset: baseReset)
        let s2 = summary(primary: 95, primaryReset: baseReset)

        _ = d.evaluate(profile: p, current: s1, previous: summary(primary: 70, primaryReset: baseReset), now: now)
        let intents = d.evaluate(profile: p, current: s2, previous: s1, now: now)

        XCTAssertTrue(intents.isEmpty)
    }

    func test_multipleThresholds_firesAllCrossed() {
        let d = NotificationDispatcher()
        let p = makeProfile(cfg: .init(
            enabled: true,
            sessionThresholds: [75, 90, 100],
            weeklyThresholds: [],
            notifyOnReset: false,
            notifyOnTokenExpiry: false
        ))
        let prev = summary(primary: 70, primaryReset: baseReset)
        let next = summary(primary: 92, primaryReset: baseReset)

        let rules = d.evaluate(profile: p, current: next, previous: prev, now: now).map(\.rule)

        XCTAssertEqual(Set(rules), [.session(75), .session(90)])
    }

    func test_resetClearsFiredFlagsAndFiresReset() {
        let d = NotificationDispatcher()
        let p = makeProfile(cfg: .init(
            enabled: true,
            sessionThresholds: [90],
            weeklyThresholds: [],
            notifyOnReset: true,
            notifyOnTokenExpiry: false
        ))
        let s1 = summary(primary: 95, primaryReset: baseReset)
        let s2 = summary(primary: 0, primaryReset: baseReset.addingTimeInterval(18_000)) // window rolled

        _ = d.evaluate(profile: p, current: s1, previous: summary(primary: 70, primaryReset: baseReset), now: now)
        let after = d.evaluate(profile: p, current: s2, previous: s1, now: now)

        XCTAssertEqual(after.map(\.rule), [.reset(.session)])

        // After reset, threshold can fire again
        let s3 = summary(primary: 92, primaryReset: baseReset.addingTimeInterval(18_000))
        let third = d.evaluate(profile: p, current: s3, previous: s2, now: now)
        XCTAssertEqual(third.map(\.rule), [.session(90)])
    }

    func test_disabledProfile_neverFires() {
        let d = NotificationDispatcher()
        let p = makeProfile(cfg: .init(
            enabled: false,
            sessionThresholds: [90],
            weeklyThresholds: [],
            notifyOnReset: false,
            notifyOnTokenExpiry: false
        ))
        let prev = summary(primary: 70, primaryReset: baseReset)
        let next = summary(primary: 99, primaryReset: baseReset)
        XCTAssertTrue(d.evaluate(profile: p, current: next, previous: prev, now: now).isEmpty)
    }

    func test_nilSummary_noFire() {
        let d = NotificationDispatcher()
        let p = makeProfile()
        XCTAssertTrue(d.evaluate(profile: p, current: nil, previous: nil, now: now).isEmpty)
    }

    func test_weeklyThresholdCrossing() {
        let d = NotificationDispatcher()
        let p = makeProfile(cfg: .init(
            enabled: true,
            sessionThresholds: [],
            weeklyThresholds: [90],
            notifyOnReset: false,
            notifyOnTokenExpiry: false
        ))
        let weeklyReset = baseReset.addingTimeInterval(86_400)
        let prev = summary(primary: 0, primaryReset: baseReset, secondary: 70, secondaryReset: weeklyReset)
        let next = summary(primary: 0, primaryReset: baseReset, secondary: 92, secondaryReset: weeklyReset)

        XCTAssertEqual(d.evaluate(profile: p, current: next, previous: prev, now: now).map(\.rule), [.weekly(90)])
    }

    func test_tokenExpiry_firesWhenInsideWindow() {
        let d = NotificationDispatcher()
        let cfg = NotificationConfig(
            enabled: true,
            sessionThresholds: [],
            weeklyThresholds: [],
            notifyOnReset: false,
            notifyOnTokenExpiry: true
        )
        let expiresAt = now.addingTimeInterval(23 * 3600) // 23h out
        var p = Profile(id: UUID(), name: "P", authMethod: .cliSync)
        p.notifications = cfg
        p.sessionKeyExpiresAt = expiresAt

        let s = summary(primary: 0, primaryReset: baseReset)
        let intents = d.evaluate(profile: p, current: s, previous: nil, now: now)

        XCTAssertEqual(intents.map(\.rule), [.tokenExpiry(expiresAt)])
    }

    func test_tokenExpiry_doesNotRefireForSameExpiresAt() {
        let d = NotificationDispatcher()
        let cfg = NotificationConfig(
            enabled: true,
            sessionThresholds: [],
            weeklyThresholds: [],
            notifyOnReset: false,
            notifyOnTokenExpiry: true
        )
        let expiresAt = now.addingTimeInterval(23 * 3600)
        var p = Profile(id: UUID(), name: "P", authMethod: .cliSync)
        p.notifications = cfg
        p.sessionKeyExpiresAt = expiresAt

        let s = summary(primary: 0, primaryReset: baseReset)
        _ = d.evaluate(profile: p, current: s, previous: nil, now: now)
        let second = d.evaluate(profile: p, current: s, previous: s, now: now)

        XCTAssertTrue(second.isEmpty)
    }

    func test_tokenExpiry_refiresAfterRotation() {
        let d = NotificationDispatcher()
        let cfg = NotificationConfig(
            enabled: true,
            sessionThresholds: [],
            weeklyThresholds: [],
            notifyOnReset: false,
            notifyOnTokenExpiry: true
        )
        let firstExpiry = now.addingTimeInterval(23 * 3600)
        var p = Profile(id: UUID(), name: "P", authMethod: .cliSync)
        p.notifications = cfg
        p.sessionKeyExpiresAt = firstExpiry

        let s = summary(primary: 0, primaryReset: baseReset)
        _ = d.evaluate(profile: p, current: s, previous: nil, now: now)

        let secondExpiry = now.addingTimeInterval(22 * 3600 + 30 * 60) // rotation produced fresh expiresAt
        p.sessionKeyExpiresAt = secondExpiry
        let intents = d.evaluate(profile: p, current: s, previous: s, now: now)

        XCTAssertEqual(intents.map(\.rule), [.tokenExpiry(secondExpiry)])
    }

    func test_weekly_rollingWindowAdvance_doesNotFireReset() {
        // Rolling 7-day window: resetsAt advances as old usage ages off
        // even though utilization stays high. Must NOT fire reset.
        let d = NotificationDispatcher()
        let p = makeProfile(cfg: .init(
            enabled: true,
            sessionThresholds: [],
            weeklyThresholds: [],
            notifyOnReset: true,
            notifyOnTokenExpiry: false
        ))
        let weeklyResetA = baseReset
        let weeklyResetB = baseReset.addingTimeInterval(3_600) // advances 1h forward
        let prev = summary(primary: 0, primaryReset: baseReset, secondary: 70, secondaryReset: weeklyResetA)
        let next = summary(primary: 0, primaryReset: baseReset, secondary: 68, secondaryReset: weeklyResetB)

        let intents = d.evaluate(profile: p, current: next, previous: prev, now: now)

        XCTAssertTrue(intents.isEmpty, "reset must not fire while utilization stays high")
    }

    func test_weekly_utilizationDropFiresReset() {
        // Real reset: utilization plunges from 70% to 0%. Must fire .reset(.weekly).
        let d = NotificationDispatcher()
        let p = makeProfile(cfg: .init(
            enabled: true,
            sessionThresholds: [],
            weeklyThresholds: [],
            notifyOnReset: true,
            notifyOnTokenExpiry: false
        ))
        let prev = summary(primary: 0, primaryReset: baseReset, secondary: 70, secondaryReset: baseReset)
        let next = summary(primary: 0, primaryReset: baseReset, secondary: 0,  secondaryReset: baseReset)

        let intents = d.evaluate(profile: p, current: next, previous: prev, now: now)

        XCTAssertEqual(intents.map(\.rule), [.reset(.weekly)])
    }
}
