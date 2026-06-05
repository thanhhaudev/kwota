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

    func test_legacyProfileWithoutNotifications_decodesAsNil() throws {
        let legacy = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "name": "Old",
          "authMethod": "cliSync",
          "createdAt": 1700000000
        }
        """
        let p = try decoder().decode(Profile.self, from: Data(legacy.utf8))
        XCTAssertNil(p.notifications)
    }

    func test_profileWithNotifications_roundTrips() throws {
        var p = Profile(id: UUID(), name: "T", authMethod: .cliSync)
        p.notifications = NotificationConfig(
            enabled: true,
            sessionThresholds: [90, 100],
            weeklyThresholds: [100],
            notifyOnReset: true,
            notifyOnTokenExpiry: true
        )
        let data = try encoder().encode(p)
        let decoded = try decoder().decode(Profile.self, from: data)
        XCTAssertEqual(decoded.notifications, p.notifications)
    }
}
