//
//  WeekAvgCalculatorTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class WeekAvgCalculatorTests: XCTestCase {
    private func date(_ ts: TimeInterval) -> Date {
        Date(timeIntervalSince1970: ts)
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(WeekAvgCalculator.weeklyTimelines(from: []).isEmpty)
    }

    func testSegmentsOnDropAndExcludesTrailing() {
        // Three sample-groups: a pre-first-drop "fake" group, one fully
        // completed cycle anchored by a real drop, and a trailing
        // in-progress group. Only the middle group is kept — the fake
        // first lacks a real reset anchor (cycleStart = samples[0].at is
        // wherever the app was installed), and the trailing one is the
        // current cycle that hasn't completed yet.
        let samples: [(at: Date, value: Double)] = [
            (date(0), 10), (date(1), 30), (date(2), 80),       // fake first (dropped)
            (date(3), 5),  (date(4), 40), (date(5), 70),       // properly anchored, completed
            (date(6), 2),  (date(7), 15)                       // trailing in-progress
        ]
        let timelines = WeekAvgCalculator.weeklyTimelines(from: samples)
        XCTAssertEqual(timelines.count, 1)
        XCTAssertEqual(timelines[0].map(\.value), [5, 40, 70])
    }

    func testFakeFirstCycleIsDroppedWhenOnlyOneDropObserved() {
        // Real-world scenario: heavy user installs mid-cycle near peak.
        // samples start at 92% and continue near the cap until the first
        // weekly reset. With one drop, the algorithm has anchored the
        // post-drop cycle but it is still in progress (trailing) — so
        // there should be ZERO completed cycles in the output. The fake
        // first group is discarded; the trailing post-drop group is
        // discarded as before.
        let samples: [(at: Date, value: Double)] = [
            (date(0), 92), (date(1), 95), (date(2), 98), (date(3), 100),  // fake first
            (date(4), 4),  (date(5), 18)                                   // trailing, post-drop
        ]
        XCTAssertEqual(WeekAvgCalculator.weeklyTimelines(from: samples).count, 0)
    }

    func testElapsedAvgLOCFsAcrossTimelines() {
        // Two completed weeks. Sample LOCF at elapsed=4 should pick:
        //   week 1: value at elapsed=2 (last ≤ 4) → 30
        //   week 2: value at elapsed=2 (last ≤ 4) → 40
        // Mean = 35.
        let timelines: [[WeekAvgCalculator.TimelineSample]] = [
            [.init(elapsed: 0, value: 10),
             .init(elapsed: 2, value: 30),
             .init(elapsed: 6, value: 80)],
            [.init(elapsed: 0, value: 5),
             .init(elapsed: 2, value: 40),
             .init(elapsed: 6, value: 70)],
        ]
        XCTAssertEqual(WeekAvgCalculator.avgAtElapsed(4, in: timelines), 35)
    }

    func testElapsedAvgReturnsNilWhenNoTimelineHasSampleAtOrBelow() {
        let timelines: [[WeekAvgCalculator.TimelineSample]] = [
            [.init(elapsed: 5, value: 50)]  // first sample at 5h; elapsed 2 has no LOCF
        ]
        XCTAssertNil(WeekAvgCalculator.avgAtElapsed(2, in: timelines))
    }

    func testElapsedAvgClampsNegativeToZero() {
        let timelines: [[WeekAvgCalculator.TimelineSample]] = [
            [.init(elapsed: 0, value: 10), .init(elapsed: 5, value: 50)]
        ]
        // currentElapsed = -1 → treated as 0 → LOCF sample at 0 → 10.
        XCTAssertEqual(WeekAvgCalculator.avgAtElapsed(-1, in: timelines), 10)
    }

    // MARK: - overshoot guard

    func testAvgSkipsTruncatedCyclesWhereMaxElapsedBelowTarget() {
        // Truncated past cycle: only 3 samples spanning elapsed 0..2.
        // Target is 5 — well beyond the cycle's reach. Without the
        // overshoot guard, samples.last(where: elapsed <= 5) would
        // return the elapsed=2 sample = the cycle's max captured
        // value (typically near peak). With the guard, the cycle is
        // skipped entirely and the avg is nil (no usable cycles).
        let timelines: [[WeekAvgCalculator.TimelineSample]] = [
            [.init(elapsed: 0, value: 80),
             .init(elapsed: 1, value: 90),
             .init(elapsed: 2, value: 95)],
        ]
        XCTAssertNil(WeekAvgCalculator.avgAtElapsed(5, in: timelines))
    }

    func testAvgMixesQualifyingAndSkipsTruncated() {
        // Two cycles. Cycle A spans elapsed 0..6 (full); cycle B is
        // truncated at elapsed 0..2. Target = 4. Cycle A qualifies
        // (maxElapsed 6 >= 4) and contributes LOCF at elapsed=3 = 60.
        // Cycle B is skipped (maxElapsed 2 < 4). Mean of {60} = 60.
        let timelines: [[WeekAvgCalculator.TimelineSample]] = [
            [.init(elapsed: 0, value: 10),
             .init(elapsed: 3, value: 60),
             .init(elapsed: 6, value: 95)],
            [.init(elapsed: 0, value: 70),
             .init(elapsed: 1, value: 85),
             .init(elapsed: 2, value: 95)],
        ]
        XCTAssertEqual(WeekAvgCalculator.avgAtElapsed(4, in: timelines), 60)
    }

    func testAvgIncludesCycleWhereMaxElapsedExactlyMatchesTarget() {
        // Boundary: maxElapsed == target. The guard uses `>=`, so the
        // cycle qualifies and the LOCF sample at elapsed = target is
        // returned.
        let timelines: [[WeekAvgCalculator.TimelineSample]] = [
            [.init(elapsed: 0, value: 10),
             .init(elapsed: 2, value: 30),
             .init(elapsed: 4, value: 60)],
        ]
        XCTAssertEqual(WeekAvgCalculator.avgAtElapsed(4, in: timelines), 60)
    }
}
