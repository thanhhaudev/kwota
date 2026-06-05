//
//  UsageTrendChartProjectionColorTests.swift
//  KwotaTests
//
//  Pure-logic tests for the session chart's projection ghost color.
//  Projection color is purely threshold-derived from the *projected* value
//  (not the current bar's value, not the warm-pace signal) — so this suite
//  pins each threshold band and its boundary.
//

import SwiftUI
import XCTest
@testable import Kwota

final class UsageTrendChartProjectionColorTests: XCTestCase {
    func testProjectionGreenWhenProjectedBelowWarning() {
        XCTAssertEqual(
            UsageTrendChart.projectionColor(projectedValue: 30),
            .green
        )
    }

    func testProjectionYellowAtExactWarningThreshold() {
        XCTAssertEqual(
            UsageTrendChart.projectionColor(projectedValue: 60),
            .yellow
        )
    }

    func testProjectionYellowMidBand() {
        XCTAssertEqual(
            UsageTrendChart.projectionColor(projectedValue: 70),
            .yellow
        )
    }

    func testProjectionRedAtExactCriticalThreshold() {
        XCTAssertEqual(
            UsageTrendChart.projectionColor(projectedValue: 80),
            .red
        )
    }

    func testProjectionRedHighBand() {
        XCTAssertEqual(
            UsageTrendChart.projectionColor(projectedValue: 95),
            .red
        )
    }
}
