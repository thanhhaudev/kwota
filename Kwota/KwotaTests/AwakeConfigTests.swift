//
//  AwakeConfigTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class AwakeConfigTests: XCTestCase {
    func testDefaultConfig_autoEnabledIdleOnlyFiveMinTwentyPercent() {
        let cfg = AwakeConfig.default
        XCTAssertTrue(cfg.autoEnabled)
        XCTAssertTrue(cfg.flags.preventIdleSleep)
        XCTAssertFalse(cfg.flags.preventDisplaySleep)
        XCTAssertFalse(cfg.flags.preventSystemSleep)
        XCTAssertFalse(cfg.flags.declareUserActivity)
        XCTAssertEqual(cfg.idleWindow, .m5)
        XCTAssertEqual(cfg.batteryThreshold, .p20)
        XCTAssertEqual(cfg.forceTimeout, .h2)
    }

    func testIdleWindow_secondsMapping() {
        XCTAssertEqual(IdleWindow.m1.seconds, 60)
        XCTAssertEqual(IdleWindow.m2.seconds, 120)
        XCTAssertEqual(IdleWindow.m5.seconds, 300)
        XCTAssertEqual(IdleWindow.m10.seconds, 600)
        XCTAssertEqual(IdleWindow.m15.seconds, 900)
    }

    func testBatteryThreshold_percentMapping() {
        XCTAssertNil(BatteryThreshold.off.percent)
        XCTAssertEqual(BatteryThreshold.p10.percent, 10)
        XCTAssertEqual(BatteryThreshold.p20.percent, 20)
        XCTAssertEqual(BatteryThreshold.p30.percent, 30)
    }

    func testCodableRoundTrip() throws {
        let cfg = AwakeConfig(
            autoEnabled: false,
            flags: CaffeinateOptions(
                preventDisplaySleep: true,
                preventIdleSleep: false,
                preventSystemSleep: false,
                declareUserActivity: false
            ),
            idleWindow: .m10,
            batteryThreshold: .p15,
            forceTimeout: .h2
        )
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AwakeConfig.self, from: data)
        XCTAssertEqual(cfg, decoded)
    }

    func testDecode_missingFieldsUseDefaults() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AwakeConfig.self, from: json)
        XCTAssertEqual(decoded, .default)
    }

    func testCaffeinateOptions_missingBoolFieldsUseDefaults() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CaffeinateOptions.self, from: json)
        XCTAssertEqual(decoded, .default)
    }

    func testDecode_unknownIdleWindowFallsBackToDefault() throws {
        let json = #"{"idleWindow":"m99"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AwakeConfig.self, from: json)
        XCTAssertEqual(decoded.idleWindow, .m5)
    }

    func testDecode_autoFlagsOnlyPayload_migratesToFlags() throws {
        // Old persisted shape from a build that only knew about autoFlags +
        // forceFlags. We migrate by preferring autoFlags (the dominant mode).
        let json = #"""
        {
            "autoEnabled": true,
            "autoFlags": {
                "preventDisplaySleep": true,
                "preventIdleSleep": true,
                "preventDiskSleep": false,
                "preventSystemSleep": false,
                "declareUserActivity": false
            },
            "idleWindow": "m5",
            "batteryThreshold": "p20",
            "forceTimeout": "h1"
        }
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AwakeConfig.self, from: json)
        XCTAssertTrue(decoded.flags.preventDisplaySleep)
        XCTAssertTrue(decoded.flags.preventIdleSleep)
    }

    func testDecode_forceFlagsOnlyPayload_migratesToFlags() throws {
        // Theoretical legacy payload missing autoFlags. Falls back to forceFlags.
        // Field values are intentionally NOT all-true so this test would fail
        // if resolveFlags silently fell through to `.default` (which has the
        // five flags at their memberwise init defaults).
        let json = #"""
        {
            "autoEnabled": false,
            "forceFlags": {
                "preventDisplaySleep": false,
                "preventIdleSleep": true,
                "preventDiskSleep": true,
                "preventSystemSleep": false,
                "declareUserActivity": false
            },
            "idleWindow": "m5",
            "batteryThreshold": "p20",
            "forceTimeout": "h2"
        }
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AwakeConfig.self, from: json)
        XCTAssertFalse(decoded.flags.preventDisplaySleep)
        XCTAssertTrue(decoded.flags.preventIdleSleep)
        XCTAssertFalse(decoded.flags.preventSystemSleep)
        XCTAssertFalse(decoded.flags.declareUserActivity)
    }

    func testDecode_bothLegacyFlagsPresent_autoWins() throws {
        let json = #"""
        {
            "autoFlags": {
                "preventDisplaySleep": false,
                "preventIdleSleep": true,
                "preventDiskSleep": false,
                "preventSystemSleep": false,
                "declareUserActivity": false
            },
            "forceFlags": {
                "preventDisplaySleep": true,
                "preventIdleSleep": true,
                "preventDiskSleep": true,
                "preventSystemSleep": true,
                "declareUserActivity": true
            }
        }
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AwakeConfig.self, from: json)
        XCTAssertFalse(decoded.flags.preventDisplaySleep)
        XCTAssertTrue(decoded.flags.preventIdleSleep)
    }

    func testDecode_newShapePayload_roundTrips() throws {
        let original = AwakeConfig(
            autoEnabled: false,
            flags: CaffeinateOptions(
                preventDisplaySleep: true,
                preventIdleSleep: false,
                preventSystemSleep: false,
                declareUserActivity: true
            ),
            idleWindow: .m10,
            batteryThreshold: .p15,
            forceTimeout: .h2
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AwakeConfig.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testEncode_emitsOnlyFlagsKey_notLegacyKeys() throws {
        let cfg = AwakeConfig.default
        let data = try JSONEncoder().encode(cfg)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(dict["flags"], "new encoder must emit `flags`")
        XCTAssertNil(dict["autoFlags"], "encoder must not re-emit legacy autoFlags")
        XCTAssertNil(dict["forceFlags"], "encoder must not re-emit legacy forceFlags")
    }
}
