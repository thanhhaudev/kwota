//
//  NotificationConfigTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class NotificationConfigTests: XCTestCase {
    func test_default_isDisabledWith100PercentAndExpiry() {
        let c = NotificationConfig.default
        XCTAssertFalse(c.enabled)
        XCTAssertEqual(c.sessionThresholds, [100])
        XCTAssertEqual(c.weeklyThresholds, [100])
        XCTAssertFalse(c.notifyOnReset)
        XCTAssertTrue(c.notifyOnTokenExpiry)
    }

    func test_codableRoundTrip() throws {
        let c = NotificationConfig(
            enabled: true,
            sessionThresholds: [75, 90, 100],
            weeklyThresholds: [90, 100],
            notifyOnReset: true,
            notifyOnTokenExpiry: false
        )
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(NotificationConfig.self, from: data)
        XCTAssertEqual(decoded, c)
    }

    func test_thresholdsAreUnordered() {
        let a = NotificationConfig(
            enabled: true,
            sessionThresholds: [100, 75, 90],
            weeklyThresholds: [],
            notifyOnReset: false,
            notifyOnTokenExpiry: false
        )
        let b = NotificationConfig(
            enabled: true,
            sessionThresholds: [75, 90, 100],
            weeklyThresholds: [],
            notifyOnReset: false,
            notifyOnTokenExpiry: false
        )
        XCTAssertEqual(a, b)
    }
}
