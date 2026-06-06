//
//  ProfileNotificationDecodingTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class ProfileNotificationDecodingTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    func test_legacyProfileWithoutNotifications_decodesAsNotMuted() throws {
        let legacy = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "name": "Old",
          "authMethod": "cliSync",
          "createdAt": 1700000000
        }
        """
        let p = try decoder().decode(Profile.self, from: Data(legacy.utf8))
        XCTAssertFalse(p.notificationsMuted)
    }

    func test_legacyDisabledNotifications_migratesToMuted() throws {
        let legacy = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "name": "Sandbox",
          "authMethod": "cliSync",
          "createdAt": 1700000000,
          "notifications": {
            "enabled": false,
            "sessionThresholds": [100],
            "weeklyThresholds": [100],
            "notifyOnReset": false,
            "notifyOnTokenExpiry": true
          }
        }
        """
        let p = try decoder().decode(Profile.self, from: Data(legacy.utf8))
        XCTAssertTrue(p.notificationsMuted)
    }

    func test_legacyEnabledNotifications_doesNotMute() throws {
        let legacy = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "name": "Live",
          "authMethod": "cliSync",
          "createdAt": 1700000000,
          "notifications": {
            "enabled": true,
            "sessionThresholds": [100],
            "weeklyThresholds": [100],
            "notifyOnReset": false,
            "notifyOnTokenExpiry": true
          }
        }
        """
        let p = try decoder().decode(Profile.self, from: Data(legacy.utf8))
        XCTAssertFalse(p.notificationsMuted)
    }

    func test_mutedRoundTrip() throws {
        var p = Profile(id: UUID(), name: "T", authMethod: .cliSync)
        p.notificationsMuted = true
        let data = try encoder().encode(p)
        let decoded = try decoder().decode(Profile.self, from: data)
        XCTAssertEqual(decoded.notificationsMuted, true)
    }
}
