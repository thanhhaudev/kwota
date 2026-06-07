//
//  MenuBarPulseTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class MenuBarPulseTests: XCTestCase {
    func test_noPulse_whenUtilizationIsNil() {
        for style in MenuBarStyle.allCases {
            XCTAssertFalse(MenuBarPulse.shouldPulse(style: style, utilization: nil),
                           "style=\(style) should not pulse without data")
        }
    }

    func test_noPulse_belowCriticalThreshold() {
        for style in MenuBarStyle.allCases {
            XCTAssertFalse(MenuBarPulse.shouldPulse(style: style, utilization: 0))
            XCTAssertFalse(MenuBarPulse.shouldPulse(style: style, utilization: 50))
            XCTAssertFalse(MenuBarPulse.shouldPulse(style: style, utilization: 79.999))
        }
    }

    func test_pulse_onlyForTintedStyles_atOrAboveThreshold() {
        let tinted: Set<MenuBarStyle> = [.fillBackground, .tintDot]
        for style in MenuBarStyle.allCases {
            for u in [80.0, 90.0, 100.0, 250.0] {
                let result = MenuBarPulse.shouldPulse(style: style, utilization: u)
                XCTAssertEqual(result, tinted.contains(style),
                               "style=\(style) u=\(u) — only tinted styles should pulse")
            }
        }
    }

    func test_threshold_matchesUsageLevelCritical() {
        XCTAssertEqual(MenuBarPulse.threshold, UsageLevel.criticalThreshold)
    }
}
