import XCTest
@testable import Kwota

final class UsageUrgencyTests: XCTestCase {
    func testRemainingAtOrAboveFortyIsOk() {
        XCTAssertEqual(UsageUrgency(remaining: 40), .ok)
        XCTAssertEqual(UsageUrgency(remaining: 88), .ok)
    }

    func testRemainingBetweenFifteenAndFortyIsWatch() {
        XCTAssertEqual(UsageUrgency(remaining: 39.9), .watch)
        XCTAssertEqual(UsageUrgency(remaining: 15), .watch)
    }

    func testRemainingBelowFifteenIsCritical() {
        XCTAssertEqual(UsageUrgency(remaining: 14.9), .critical)
        XCTAssertEqual(UsageUrgency(remaining: 0), .critical)
    }

    func testUtilizationConvenienceInvertsAndClamps() {
        XCTAssertEqual(UsageUrgency(utilization: 12), .ok)        // 88 remaining
        XCTAssertEqual(UsageUrgency(utilization: 96), .critical)  // 4 remaining
        XCTAssertEqual(UsageUrgency(utilization: 150), .critical) // clamps to 0
    }

    func testNilUtilizationHasNoUrgency() {
        XCTAssertNil(UsageUrgency(utilization: nil))
    }
}
