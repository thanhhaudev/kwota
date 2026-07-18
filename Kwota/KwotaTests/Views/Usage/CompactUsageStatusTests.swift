import XCTest
@testable import Kwota

final class CompactUsageStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func point(pace: Double, burn: Double) -> CompactUsagePaceSeries.Point {
        CompactUsagePaceSeries.Point(at: now, pace: pace, burnPerHour: burn, segment: 0)
    }

    // MARK: pace words (reset in the future but burn too low to project)

    private func paceTag(_ pace: Double) -> CompactUsageStatus.Tag? {
        CompactUsageStatus.headlineTag(
            utilization: 50,
            resetsAt: nil,                       // no reset → projection can't fire
            latest: point(pace: pace, burn: 5),
            now: now
        )
    }

    func testPaceWordsMapAtThresholds() {
        XCTAssertEqual(paceTag(1.5), .init(text: "burning fast", style: .watch))
        XCTAssertEqual(paceTag(1.49), .init(text: "steady", style: .calm))
        XCTAssertEqual(paceTag(0.5), .init(text: "steady", style: .calm))
        XCTAssertEqual(paceTag(0.49), .init(text: "cooling", style: .neutral))
    }

    func testNoPaceSampleReturnsNil() {
        XCTAssertNil(CompactUsageStatus.headlineTag(
            utilization: 50,
            resetsAt: now.addingTimeInterval(3600),
            latest: nil,
            now: now
        ))
    }

    // MARK: projection

    func testProjectionFiresWhenExhaustionBeforeReset() {
        // 10% left, 20 %/h → 0.5h to cap; reset in 2h → fires.
        let tag = CompactUsageStatus.headlineTag(
            utilization: 90,
            resetsAt: now.addingTimeInterval(2 * 3600),
            latest: point(pace: 2.0, burn: 20),
            now: now
        )
        XCTAssertEqual(tag, .init(text: "~30m to cap", style: .hot))
    }

    func testProjectionYieldsToPaceWhenResetIsSooner() {
        // 80% left, 20 %/h → 4h to cap; reset in 1h → exhaustion after reset → no projection.
        let tag = CompactUsageStatus.headlineTag(
            utilization: 20,
            resetsAt: now.addingTimeInterval(1 * 3600),
            latest: point(pace: 2.0, burn: 20),
            now: now
        )
        XCTAssertEqual(tag, .init(text: "burning fast", style: .watch))
    }

    func testProjectionSkippedWhenBurnNegligible() {
        let tag = CompactUsageStatus.headlineTag(
            utilization: 95,
            resetsAt: now.addingTimeInterval(5 * 3600),
            latest: point(pace: 0.2, burn: 0.05),   // below minBurnPerHour
            now: now
        )
        XCTAssertEqual(tag, .init(text: "cooling", style: .neutral))
    }

    func testProjectionSkippedWhenNoReset() {
        let tag = CompactUsageStatus.headlineTag(
            utilization: 95,
            resetsAt: nil,
            latest: point(pace: 2.0, burn: 50),
            now: now
        )
        XCTAssertEqual(tag, .init(text: "burning fast", style: .watch))
    }

    // MARK: level-only rows

    func testLevelTagNearCapUnderThreshold() {
        XCTAssertEqual(CompactUsageStatus.levelTag(utilization: 86),
                       .init(text: "near cap", style: .hot))   // 14 left
    }

    func testLevelTagNilAtOrAboveThreshold() {
        XCTAssertNil(CompactUsageStatus.levelTag(utilization: 85))  // 15 left, boundary
        XCTAssertNil(CompactUsageStatus.levelTag(utilization: 20))  // 80 left
        XCTAssertNil(CompactUsageStatus.levelTag(utilization: nil))
    }

    // MARK: formatting

    func testFormatToCap() {
        XCTAssertEqual(CompactUsageStatus.formatToCap(0.75), "~45m to cap")
        XCTAssertEqual(CompactUsageStatus.formatToCap(3.2), "~3h to cap")
        XCTAssertEqual(CompactUsageStatus.formatToCap(50), "~2d to cap")
        XCTAssertEqual(CompactUsageStatus.formatToCap(0.001), "~1m to cap")
    }
}
