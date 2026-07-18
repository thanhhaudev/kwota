import XCTest
@testable import Kwota

final class CompactUsagePaceSeriesTests: XCTestCase {
    private let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
    private var now: Date { cutoff.addingTimeInterval(24 * 3600) }

    private func entry(
        _ hours: Double,
        five: Double?,
        seven: Double?
    ) -> UsageHistoryEntry {
        UsageHistoryEntry(
            at: cutoff.addingTimeInterval(hours * 3600),
            fiveHour: five,
            sevenDay: seven
        )
    }

    func testEmptyHistoryYieldsNoRenderableSeries() {
        let output = CompactUsagePaceSeries.series(from: [], now: now)

        XCTAssertTrue(output.session.isEmpty)
        XCTAssertTrue(output.week.isEmpty)
    }

    func testConstantSessionBurnNormalizesToOne() {
        let output = CompactUsagePaceSeries.series(from: [
            entry(1, five: 0, seven: nil),
            entry(2, five: 10, seven: nil),
            entry(3, five: 20, seven: nil)
        ], now: now)

        XCTAssertEqual(output.session.count, 2)
        XCTAssertEqual(output.session.map(\.pace), [1, 1])
        XCTAssertEqual(output.session.map(\.segment), [0, 0])
    }

    func testWeekCarriesForwardBeforeCalculatingRates() {
        let output = CompactUsagePaceSeries.series(from: [
            entry(1, five: 0, seven: 10),
            entry(2, five: 5, seven: nil),
            entry(3, five: 10, seven: 20),
            entry(4, five: 15, seven: 30)
        ], now: now)

        XCTAssertFalse(output.week.isEmpty)
        XCTAssertEqual(output.week.last?.segment, 0)
    }

    func testLastDuplicateTimestampWins() {
        let duplicateDate = cutoff.addingTimeInterval(2 * 3600)
        let output = CompactUsagePaceSeries.series(from: [
            entry(1, five: 0, seven: nil),
            UsageHistoryEntry(at: duplicateDate, fiveHour: 5, sevenDay: nil),
            UsageHistoryEntry(at: duplicateDate, fiveHour: 10, sevenDay: nil),
            entry(3, five: 20, seven: nil)
        ], now: now)

        XCTAssertEqual(output.session.map(\.pace), [1, 1])
    }

    func testPredecessorBeforeCutoffSeedsFirstVisibleRate() {
        let predecessor = UsageHistoryEntry(
            at: cutoff.addingTimeInterval(-30 * 60),
            fiveHour: 0,
            sevenDay: nil
        )
        let output = CompactUsagePaceSeries.series(from: [
            predecessor,
            entry(0.5, five: 10, seven: nil),
            entry(1.5, five: 20, seven: nil)
        ], now: now)

        XCTAssertEqual(output.session.count, 2)
    }

    func testResetBreaksSegmentAndDoesNotCreateSpike() {
        let output = CompactUsagePaceSeries.series(from: [
            entry(1, five: 80, seven: nil),
            entry(2, five: 5, seven: nil),
            entry(3, five: 15, seven: nil),
            entry(4, five: 25, seven: nil)
        ], now: now)

        XCTAssertEqual(output.session.map(\.segment), [1, 1])
        XCTAssertEqual(output.session.map(\.pace), [1, 1])
    }

    func testSmallNegativeJitterBecomesZeroRate() {
        let output = CompactUsagePaceSeries.series(from: [
            entry(1, five: 10, seven: nil),
            entry(2, five: 9.5, seven: nil),
            entry(3, five: 19.5, seven: nil)
        ], now: now)

        XCTAssertEqual(output.session.first?.pace, 0)
    }

    func testPositiveDeltaAcrossTwoHourGapUsesAveragePace() {
        let output = CompactUsagePaceSeries.series(from: [
            entry(1, five: 0, seven: nil),
            entry(3, five: 20, seven: nil),
            entry(4, five: 30, seven: nil),
            entry(5, five: 40, seven: nil)
        ], now: now)

        XCTAssertEqual(output.session.map(\.segment), [0, 0, 0])
        XCTAssertEqual(output.session.map(\.pace), [1, 1, 1])
    }

    func testPositiveDeltaAcrossMoreThanThreeHoursIsUnknown() {
        let output = CompactUsagePaceSeries.series(from: [
            entry(1, five: 0, seven: nil),
            entry(5, five: 20, seven: nil),
            entry(6, five: 30, seven: nil),
            entry(7, five: 40, seven: nil)
        ], now: now)

        XCTAssertEqual(output.session.map(\.segment), [1, 1])
    }

    func testLongZeroPlateauRemainsKnownIdleTime() {
        let output = CompactUsagePaceSeries.series(from: [
            entry(1, five: 10, seven: nil),
            entry(4, five: 10, seven: nil),
            entry(5, five: 10, seven: nil)
        ], now: now)

        XCTAssertEqual(output.session.map(\.pace), [0, 0])
    }

    func testThreePointSmoothingAndCeiling() {
        var history: [UsageHistoryEntry] = []
        for hour in 0...10 {
            history.append(entry(Double(hour + 1), five: 0, seven: nil))
        }
        history.append(entry(12, five: 100, seven: nil))
        history.append(entry(13, five: 100, seven: nil))

        let output = CompactUsagePaceSeries.series(from: history, now: now)

        XCTAssertEqual(
            output.session.last(where: { $0.at == entry(12, five: 0, seven: nil).at })?.pace,
            2
        )
        XCTAssertTrue(output.session.allSatisfy { (0...2).contains($0.pace) })
    }

    func testOneDerivedPointIsNotRenderable() {
        let output = CompactUsagePaceSeries.series(from: [
            entry(1, five: 0, seven: nil),
            entry(2, five: 10, seven: nil)
        ], now: now)

        XCTAssertTrue(output.session.isEmpty)
    }

    func testSessionCanRenderWhileWeekIsUnavailable() {
        let output = CompactUsagePaceSeries.series(from: [
            entry(1, five: 0, seven: nil),
            entry(2, five: 10, seven: nil),
            entry(3, five: 20, seven: nil)
        ], now: now)

        XCTAssertFalse(output.session.isEmpty)
        XCTAssertTrue(output.week.isEmpty)
    }

    func testBurnPerHourCapturesAbsoluteRateBeforeNormalization() {
        // 10 %/h constant burn → pace normalizes to 1, burnPerHour stays 10.
        let output = CompactUsagePaceSeries.series(from: [
            entry(1, five: 0, seven: nil),
            entry(2, five: 10, seven: nil),
            entry(3, five: 20, seven: nil)
        ], now: now)

        XCTAssertEqual(output.session.map(\.pace), [1, 1])
        XCTAssertEqual(output.session.map(\.burnPerHour), [10, 10])
    }
}
