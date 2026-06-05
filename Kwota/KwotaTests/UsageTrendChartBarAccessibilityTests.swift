//
//  UsageTrendChartBarAccessibilityTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class UsageTrendChartBarAccessibilityTests: XCTestCase {

    // MARK: - barAccessibilityLabel

    func testSessionBarLabel_currentHour() {
        let cal = Calendar.current
        let nowHour = cal.dateInterval(of: .hour, for: Date())?.start ?? Date()
        let entry = UsageTrendChart.Entry(at: nowHour, value: 42)
        let label = UsageTrendChart.barAccessibilityLabel(entry: entry, style: .hourSuffixed)
        XCTAssertEqual(label, "Current hour")
    }

    func testSessionBarLabel_oneHourAgo() {
        let cal = Calendar.current
        let nowHour = cal.dateInterval(of: .hour, for: Date())?.start ?? Date()
        let at = nowHour.addingTimeInterval(-3600)
        let entry = UsageTrendChart.Entry(at: at, value: 30)
        let label = UsageTrendChart.barAccessibilityLabel(entry: entry, style: .hourSuffixed)
        XCTAssertEqual(label, "1 hour ago")
    }

    func testSessionBarLabel_threeHoursAgo() {
        let cal = Calendar.current
        let nowHour = cal.dateInterval(of: .hour, for: Date())?.start ?? Date()
        let at = nowHour.addingTimeInterval(-3 * 3600)
        let entry = UsageTrendChart.Entry(at: at, value: 10)
        let label = UsageTrendChart.barAccessibilityLabel(entry: entry, style: .hourSuffixed)
        XCTAssertEqual(label, "3 hours ago")
    }

    func testSessionBarLabel_previousSession() {
        let cal = Calendar.current
        let nowHour = cal.dateInterval(of: .hour, for: Date())?.start ?? Date()
        let at = nowHour.addingTimeInterval(-2 * 3600)
        var entry = UsageTrendChart.Entry(at: at, value: 60)
        entry.isPreviousSession = true
        let label = UsageTrendChart.barAccessibilityLabel(entry: entry, style: .hourSuffixed)
        XCTAssertEqual(label, "Previous session, 2 hours ago")
    }

    func testSessionBarLabel_projection() {
        let cal = Calendar.current
        let nowHour = cal.dateInterval(of: .hour, for: Date())?.start ?? Date()
        var entry = UsageTrendChart.Entry(at: nowHour.addingTimeInterval(3600), value: 55)
        entry.isProjection = true
        let label = UsageTrendChart.barAccessibilityLabel(entry: entry, style: .hourSuffixed)
        XCTAssertEqual(label, "Projected next hour")
    }

    func testWeeklyBarLabel_returnsWeekdayName() {
        var comps = DateComponents()
        comps.year = 2024; comps.month = 1; comps.day = 1
        let monday = Calendar(identifier: .gregorian).date(from: comps)!
        let entry = UsageTrendChart.Entry(at: monday, value: 70)
        let label = UsageTrendChart.barAccessibilityLabel(entry: entry, style: .weekdayNarrow)
        XCTAssertTrue(label.localizedCaseInsensitiveContains("monday"),
                      "expected weekday name, got \(label)")
    }

    func testWeeklyBarLabel_futureDayOverridesStyle() {
        var comps = DateComponents()
        comps.year = 2099; comps.month = 1; comps.day = 1
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        var entry = UsageTrendChart.Entry(at: date, value: 0)
        entry.isFuture = true
        let label = UsageTrendChart.barAccessibilityLabel(entry: entry, style: .weekdayNarrow)
        XCTAssertEqual(label, "Future day")
    }

    // MARK: - barAccessibilityValue

    func testBarValue_realEntry() {
        let entry = UsageTrendChart.Entry(at: Date(), value: 47.6)
        XCTAssertEqual(UsageTrendChart.barAccessibilityValue(entry: entry), "48 percent")
    }

    func testBarValue_zeroPercent() {
        let entry = UsageTrendChart.Entry(at: Date(), value: 0)
        XCTAssertEqual(UsageTrendChart.barAccessibilityValue(entry: entry), "0 percent")
    }

    func testBarValue_futureDay() {
        var entry = UsageTrendChart.Entry(at: Date(), value: 0)
        entry.isFuture = true
        XCTAssertEqual(UsageTrendChart.barAccessibilityValue(entry: entry), "no data yet")
    }
}
