//
//  AwakeConfigStoreTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class AwakeConfigStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "AwakeConfigStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testLoad_missingKey_returnsDefault() {
        let store = AwakeConfigStore(defaults: defaults)
        XCTAssertEqual(store.config, .default)
    }

    func testSave_persistsAndReloads() {
        let store = AwakeConfigStore(defaults: defaults)
        var cfg = store.config
        cfg.idleWindow = .m10
        cfg.batteryThreshold = .p15
        store.update(cfg)

        let reloaded = AwakeConfigStore(defaults: defaults)
        XCTAssertEqual(reloaded.config.idleWindow, .m10)
        XCTAssertEqual(reloaded.config.batteryThreshold, .p15)
    }

    func testLoad_corruptJSON_returnsDefault() {
        defaults.set("not json".data(using: .utf8), forKey: AppStorageKeys.awakeConfig)
        let store = AwakeConfigStore(defaults: defaults)
        XCTAssertEqual(store.config, .default)
    }

    func testMutate_updatesAndPersists() {
        let store = AwakeConfigStore(defaults: defaults)
        store.mutate { $0.autoEnabled = false }
        XCTAssertFalse(store.config.autoEnabled)

        let reloaded = AwakeConfigStore(defaults: defaults)
        XCTAssertFalse(reloaded.config.autoEnabled)
    }
}
