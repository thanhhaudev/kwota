//
//  UsageBatteryRowTests.swift
//

import XCTest
@testable import Kwota

final class UsageBatteryRowTests: XCTestCase {
    func test_remainingWidth_invertsUtilization() {
        XCTAssertEqual(UsageBatteryRow.remainingWidth(for: 0), 100)
        XCTAssertEqual(UsageBatteryRow.remainingWidth(for: 27), 73)
        XCTAssertEqual(UsageBatteryRow.remainingWidth(for: 100), 0)
    }

    func test_remainingWidth_nilIsEmptyTrack() {
        XCTAssertEqual(UsageBatteryRow.remainingWidth(for: nil), 0)
    }

    func test_remainingWidth_clampsOutOfRange() {
        XCTAssertEqual(UsageBatteryRow.remainingWidth(for: 120), 0)
        XCTAssertEqual(UsageBatteryRow.remainingWidth(for: -5), 100)
    }

    func test_remainingText_matchesWidth() {
        XCTAssertEqual(UsageBatteryRow.remainingText(for: 27), "73%")
        XCTAssertEqual(UsageBatteryRow.remainingText(for: 100), "0%")
        XCTAssertEqual(UsageBatteryRow.remainingText(for: nil), "—")
    }

    func test_remainingText_clampsInsteadOfShowingNegative() {
        XCTAssertEqual(UsageBatteryRow.remainingText(for: 120), "0%")
    }
}
