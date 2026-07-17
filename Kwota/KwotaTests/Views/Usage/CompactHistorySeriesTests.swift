//
//  CompactHistorySeriesTests.swift
//

import XCTest
@testable import Kwota

final class CompactHistorySeriesTests: XCTestCase {
    /// Window start. `now` sits 24h later, so an entry at `t0` lands exactly
    /// on the cutoff boundary and an entry before it is outside the window.
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private var now: Date { t0.addingTimeInterval(24 * 3600) }

    private func entry(_ hours: Double, five: Double?, seven: Double?) -> UsageHistoryEntry {
        UsageHistoryEntry(at: t0.addingTimeInterval(hours * 3600), fiveHour: five, sevenDay: seven)
    }

    func test_emptyHistory_yieldsEmptySeries() {
        let s = CompactHistorySeries.series(from: [], now: now)
        XCTAssertTrue(s.session.isEmpty)
        XCTAssertTrue(s.week.isEmpty)
    }

    func test_remainingIsInvertedFromUtilization() {
        let s = CompactHistorySeries.series(from: [entry(1, five: 30, seven: 10)], now: now)
        XCTAssertEqual(s.session.first?.remaining, 70)
        XCTAssertEqual(s.week.first?.remaining, 90)
    }

    func test_remainingIsClampedBothEnds() {
        // The server has been seen to report utilization above 100 during
        // overage; a negative remaining would render as a bar overflowing
        // its track.
        let s = CompactHistorySeries.series(
            from: [entry(1, five: 120, seven: -5)], now: now)
        XCTAssertEqual(s.session.first?.remaining, 0)
        XCTAssertEqual(s.week.first?.remaining, 100)
    }

    func test_weeklyNilRun_carriesLastValueForward() {
        // UsageHistoryStore.normalizedForStorage nils sevenDay whenever weekly
        // is unchanged but fiveHour moved. Plotting raw would leave holes.
        let s = CompactHistorySeries.series(from: [
            entry(1, five: 10, seven: 20),
            entry(2, five: 20, seven: nil),
            entry(3, five: 30, seven: nil)
        ], now: now)
        XCTAssertEqual(s.week.map(\.remaining), [80, 80, 80])
    }

    func test_weeklyValueBeforeWindow_carriesIntoWindow() {
        // LOCF must run over the FULL history before windowing: the first
        // entry inside the window may owe its value to a sample that predates
        // the cutoff.
        let old = UsageHistoryEntry(
            at: t0.addingTimeInterval(-6 * 3600), fiveHour: 5, sevenDay: 40)
        let s = CompactHistorySeries.series(from: [old, entry(1, five: 10, seven: nil)], now: now)
        XCTAssertEqual(s.week.count, 1, "the pre-window sample must not be plotted")
        XCTAssertEqual(s.week.first?.remaining, 60, "but its value must carry in")
    }

    func test_weeklyAllNil_yieldsEmptyWeekSeries() {
        let s = CompactHistorySeries.series(from: [
            entry(1, five: 10, seven: nil),
            entry(2, five: 20, seven: nil)
        ], now: now)
        XCTAssertTrue(s.week.isEmpty, "no weekly reading ever seen — plot nothing, not zeros")
        XCTAssertEqual(s.session.count, 2)
    }

    func test_steadyBurn_staysOnSegmentZero() {
        let s = CompactHistorySeries.series(from: [
            entry(1, five: 10, seven: nil),
            entry(2, five: 40, seven: nil),
            entry(3, five: 90, seven: nil)
        ], now: now)
        XCTAssertEqual(s.session.map(\.segment), [0, 0, 0])
    }

    func test_sessionRefill_incrementsSegment() {
        let s = CompactHistorySeries.series(from: [
            entry(1, five: 90, seven: nil),
            entry(2, five: 5,  seven: nil),   // reset: remaining 10 -> 95
            entry(3, five: 30, seven: nil)
        ], now: now)
        XCTAssertEqual(s.session.map(\.segment), [0, 1, 1])
    }

    func test_smallUpwardJitter_doesNotIncrementSegment() {
        // remaining 20 -> 21 is a 1-point rise: at the floor, not above it.
        let s = CompactHistorySeries.series(from: [
            entry(1, five: 80, seven: nil),
            entry(2, five: 79, seven: nil)
        ], now: now)
        XCTAssertEqual(s.session.map(\.segment), [0, 0])
    }

    func test_weeklyReset_segmentsWeekIndependentlyOfSession() {
        let s = CompactHistorySeries.series(from: [
            entry(1, five: 50, seven: 80),
            entry(2, five: 60, seven: 2)    // weekly reset; session keeps burning
        ], now: now)
        XCTAssertEqual(s.week.map(\.segment), [0, 1])
        XCTAssertEqual(s.session.map(\.segment), [0, 0])
    }

    func test_windowExcludesOlderEntriesAndIncludesTheBoundary() {
        let s = CompactHistorySeries.series(from: [
            UsageHistoryEntry(at: t0.addingTimeInterval(-1), fiveHour: 11, sevenDay: nil),
            entry(0, five: 22, seven: nil),   // exactly on the cutoff
            entry(5, five: 33, seven: nil)
        ], now: now)
        XCTAssertEqual(s.session.map(\.remaining), [78, 67])
    }

    func test_unsortedInputIsOrderedByTime() {
        let s = CompactHistorySeries.series(from: [
            entry(3, five: 30, seven: nil),
            entry(1, five: 10, seven: nil)
        ], now: now)
        XCTAssertEqual(s.session.map(\.remaining), [90, 70])
    }
}
