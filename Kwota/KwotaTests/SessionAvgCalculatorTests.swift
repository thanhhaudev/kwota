//
//  SessionAvgCalculatorTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class SessionAvgCalculatorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ offsetSec: TimeInterval) -> Date {
        t0.addingTimeInterval(offsetSec)
    }

    // MARK: - sessionTimelines

    func testSessionTimelines_emptyInput_returnsEmpty() {
        XCTAssertTrue(SessionAvgCalculator.sessionTimelines(from: []).isEmpty)
    }

    func testSessionTimelines_singleCycleNotYetReset_excludesTrailingInProgress() {
        // Monotonic non-decreasing — one in-progress cycle, no completed cycle.
        let samples: [(at: Date, value: Double)] = [
            (at(0),     10),
            (at(3600),  25),
            (at(7200),  40),
        ]
        XCTAssertTrue(SessionAvgCalculator.sessionTimelines(from: samples).isEmpty)
    }

    func testSessionTimelines_twoCompletedCycles_returnsBothExcludesTrailing() {
        // Cycle 1: 10 → 25 → 40, then drops to 5 (reset). Cycle 1 completed.
        // Cycle 2: 5 → 30 → 60, then drops to 8 (reset). Cycle 2 completed.
        // Cycle 3 starts at 8, doesn't complete.
        let samples: [(at: Date, value: Double)] = [
            (at(0),      10),  // c1 start
            (at(3600),   25),
            (at(7200),   40),
            (at(10_800), 5),   // reset → c1 closes, c2 starts here
            (at(14_400), 30),
            (at(18_000), 60),
            (at(21_600), 8),   // reset → c2 closes, c3 starts here
            (at(25_200), 20),  // c3 trailing, excluded
        ]
        let timelines = SessionAvgCalculator.sessionTimelines(from: samples)
        XCTAssertEqual(timelines.count, 2)

        // c1: elapsed measured from at(0).
        XCTAssertEqual(timelines[0].map(\.elapsed), [0, 3600, 7200])
        XCTAssertEqual(timelines[0].map(\.value),   [10, 25, 40])

        // c2: elapsed measured from at(10_800), the post-drop sample.
        XCTAssertEqual(timelines[1].map(\.elapsed), [0, 3600, 7200])
        XCTAssertEqual(timelines[1].map(\.value),   [5, 30, 60])
    }

    func testSessionTimelines_smallDropWithinNoiseTolerance_doesNotCloseCycle() {
        // 40 → 39.5 is < 5.0 drop (server rounding noise); same cycle.
        let samples: [(at: Date, value: Double)] = [
            (at(0),     10),
            (at(3600),  40),
            (at(7200),  39.5),  // jitter, not a reset
            (at(10_800), 50),
            (at(14_400), 5),    // real reset, closes the cycle
        ]
        let timelines = SessionAvgCalculator.sessionTimelines(from: samples)
        XCTAssertEqual(timelines.count, 1)
        XCTAssertEqual(timelines[0].map(\.value), [10, 40, 39.5, 50])
    }

    // MARK: - avgAtElapsed

    private func tl(_ pairs: [(TimeInterval, Double)]) -> [SessionAvgCalculator.TimelineSample] {
        pairs.map { SessionAvgCalculator.TimelineSample(elapsed: $0.0, value: $0.1) }
    }

    func testAvgAtElapsed_emptyTimelines_returnsNil() {
        XCTAssertNil(SessionAvgCalculator.avgAtElapsed(3600, in: []))
    }

    func testAvgAtElapsed_locfPicksLastSampleAtOrBeforeElapsed() {
        // Two cycles, currentElapsed = 5400s (1.5h).
        // Cycle A: samples at 0/3600/7200 with values 10/40/70 → LOCF at 5400 = 40.
        // Cycle B: samples at 0/3600/7200 with values 20/50/80 → LOCF at 5400 = 50.
        // Expected avg = (40 + 50) / 2 = 45.
        let timelines = [
            tl([(0, 10), (3600, 40), (7200, 70)]),
            tl([(0, 20), (3600, 50), (7200, 80)]),
        ]
        let avg = SessionAvgCalculator.avgAtElapsed(5400, in: timelines)
        XCTAssertEqual(avg!, 45, accuracy: 0.0001)
    }

    func testAvgAtElapsed_skipsCyclesWithNoQualifyingSample() {
        // Empty cycle (pathological — sessionTimelines never emits these, but
        // the contract should still skip them) is excluded from the mean.
        let timelines = [
            tl([(0, 10), (3600, 40), (7200, 70)]),
            tl([(0, 20), (1800, 35)]),
            tl([]),
        ]
        let avg = SessionAvgCalculator.avgAtElapsed(7200, in: timelines)
        // (70 + 35) / 2 = 52.5
        XCTAssertEqual(avg!, 52.5, accuracy: 0.0001)
    }

    func testAvgAtElapsed_currentElapsedZero_returnsAverageOfStartValues() {
        let timelines = [
            tl([(0, 0), (3600, 30)]),
            tl([(0, 5), (3600, 40)]),
        ]
        let avg = SessionAvgCalculator.avgAtElapsed(0, in: timelines)
        XCTAssertEqual(avg!, 2.5, accuracy: 0.0001)
    }

    func testAvgAtElapsed_negativeElapsed_clampsToFirstSample() {
        // Defensive: clock skew shouldn't crash. Treat as 0.
        let timelines = [
            tl([(0, 10), (3600, 40)]),
            tl([(0, 20), (3600, 50)]),
        ]
        let avg = SessionAvgCalculator.avgAtElapsed(-100, in: timelines)
        XCTAssertEqual(avg!, 15, accuracy: 0.0001)
    }
}
