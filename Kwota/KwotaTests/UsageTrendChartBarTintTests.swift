//
//  UsageTrendChartBarTintTests.swift
//  KwotaTests
//
//  Pins the per-bar threshold tint used for real (non-projection,
//  non-future, non-prev-session) bars. Without per-bar tint, all real
//  bars in the session/weekly chart share a single bucket-derived color
//  and previous hours flip color when the current cumulative crosses a
//  threshold — the bug this suite guards against.
//

import SwiftUI
import XCTest
@testable import Kwota

final class UsageTrendChartBarTintTests: XCTestCase {
    func testGreenWhenBelowWarning() {
        XCTAssertEqual(UsageTrendChart.realBarTint(value: 30), .green)
    }

    func testYellowAtExactWarningThreshold() {
        XCTAssertEqual(UsageTrendChart.realBarTint(value: 60), .yellow)
    }

    func testYellowMidBand() {
        XCTAssertEqual(UsageTrendChart.realBarTint(value: 70), .yellow)
    }

    func testRedAtExactCriticalThreshold() {
        XCTAssertEqual(UsageTrendChart.realBarTint(value: 80), .red)
    }

    func testRedHighBand() {
        XCTAssertEqual(UsageTrendChart.realBarTint(value: 95), .red)
    }

    /// Regression: past-bar tint depends only on the bar's own value, not
    /// on whatever the bucket's current cumulative says. A -3h bar that
    /// ended at 30% must stay green even after `now` crosses into red.
    func testPastBarIndependentOfCurrentBucketUtilization() {
        let pastBarValue: Double = 30
        XCTAssertEqual(UsageTrendChart.realBarTint(value: pastBarValue), .green)
        // Symmetry: matches projectionColor's rule for the projection bar.
        XCTAssertEqual(
            UsageTrendChart.realBarTint(value: pastBarValue),
            UsageTrendChart.projectionColor(projectedValue: pastBarValue)
        )
    }
}
