//
//  NotificationSettingsStoreTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class NotificationSettingsStoreTests: XCTestCase {

    private func tempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwota-notif-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notification-settings.json")
    }

    func test_missingFile_returnsDefault() {
        let url = tempURL()
        let store = NotificationSettingsStore(fileURL: url)
        XCTAssertEqual(store.value, .default)
    }

    func test_corruptFile_returnsDefault() throws {
        let url = tempURL()
        try Data("{ not json".utf8).write(to: url)
        let store = NotificationSettingsStore(fileURL: url)
        XCTAssertEqual(store.value, .default)
    }

    func test_writeReadRoundTrip() {
        let url = tempURL()
        let store = NotificationSettingsStore(fileURL: url)
        store.value = NotificationSettings(
            shortWindowThresholds: [75, 90],
            longWindowThresholds: [100],
            notifyOnReset: true,
            notifyOnTokenExpiry: false
        )

        let reloaded = NotificationSettingsStore(fileURL: url)
        XCTAssertEqual(reloaded.value, store.value)
    }
}
