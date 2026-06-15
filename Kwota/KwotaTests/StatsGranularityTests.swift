//  StatsGranularityTests.swift
//  KwotaTests

import XCTest
@testable import Kwota

final class StatsGranularityTests: XCTestCase {
    func test_forSpan_picksTierByDayCount() {
        XCTAssertEqual(StatsGranularity.forSpan(days: 1),    .day)
        XCTAssertEqual(StatsGranularity.forSpan(days: 90),   .day)
        XCTAssertEqual(StatsGranularity.forSpan(days: 91),   .week)
        XCTAssertEqual(StatsGranularity.forSpan(days: 730),  .week)
        XCTAssertEqual(StatsGranularity.forSpan(days: 731),  .month)
        XCTAssertEqual(StatsGranularity.forSpan(days: 3653), .month)
        XCTAssertEqual(StatsGranularity.forSpan(days: 3654), .year)
    }

    func test_componentAndAvgUnit() {
        XCTAssertEqual(StatsGranularity.day.component, .day)
        XCTAssertEqual(StatsGranularity.week.component, .weekOfYear)
        XCTAssertEqual(StatsGranularity.month.component, .month)
        XCTAssertEqual(StatsGranularity.year.component, .year)
        XCTAssertEqual(StatsGranularity.day.avgUnit, "day")
        XCTAssertEqual(StatsGranularity.week.avgUnit, "week")
        XCTAssertEqual(StatsGranularity.month.avgUnit, "month")
        XCTAssertEqual(StatsGranularity.year.avgUnit, "year")
    }
}
