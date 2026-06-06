//
//  NotificationSettingsTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class NotificationSettingsTests: XCTestCase {
    func test_default_matchesSpec() {
        let s = NotificationSettings.default
        XCTAssertEqual(s.shortWindowThresholds, [100])
        XCTAssertEqual(s.longWindowThresholds, [100])
        XCTAssertFalse(s.notifyOnReset)
        XCTAssertTrue(s.notifyOnTokenExpiry)
    }

    func test_roundTrip_preservesValues() throws {
        let s = NotificationSettings(
            shortWindowThresholds: [75, 100],
            longWindowThresholds: [90],
            notifyOnReset: true,
            notifyOnTokenExpiry: false
        )
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(NotificationSettings.self, from: data)
        XCTAssertEqual(decoded, s)
    }
}
