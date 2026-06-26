//
//  PollingModeTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class PollingModeTests: XCTestCase {
    func test_normal_intervals_matchTodaysDefaults() {
        XCTAssertEqual(PollingMode.normal.openInterval,   120)
        XCTAssertEqual(PollingMode.normal.closedInterval, 900)
    }

    func test_batterySaver_intervals() {
        XCTAssertEqual(PollingMode.batterySaver.openInterval,   300)
        XCTAssertEqual(PollingMode.batterySaver.closedInterval, 3600)
    }

    func test_resolve_known_rawValues() {
        XCTAssertEqual(PollingMode.resolve("normal"),        .normal)
        XCTAssertEqual(PollingMode.resolve("batterySaver"),  .batterySaver)
    }

    func test_resolve_unknown_fallsBackToNormal() {
        XCTAssertEqual(PollingMode.resolve("garbage"), .normal)
        XCTAssertEqual(PollingMode.resolve(nil),       .normal)
    }
}
