import XCTest
@testable import Kwota

final class BindingReclaimTests: XCTestCase {

    private let kA = HotKeyDefinition(keyCode: 18, rawModifiers: 1 << 18)
    private let kB = HotKeyDefinition(keyCode: 19, rawModifiers: 1 << 18)

    func testReturnerWithoutBindingReturnsEmpty() {
        let returner = UUID()
        let other = UUID()
        let result = BindingReclaim.displacedByReturner(
            returnerID: returner,
            bindings: [other: kA]
        )
        XCTAssertEqual(result, [])
    }

    func testNoCollisionReturnsEmpty() {
        let returner = UUID()
        let other = UUID()
        let result = BindingReclaim.displacedByReturner(
            returnerID: returner,
            bindings: [returner: kA, other: kB]
        )
        XCTAssertEqual(result, [])
    }

    func testSingleCollisionReturnsTheOther() {
        let returner = UUID()
        let other = UUID()
        let result = BindingReclaim.displacedByReturner(
            returnerID: returner,
            bindings: [returner: kA, other: kA]
        )
        XCTAssertEqual(result, [other])
    }

    func testMultipleCollisionsReturnsAllOthers() {
        let returner = UUID()
        let p1 = UUID()
        let p2 = UUID()
        let p3 = UUID()
        let result = BindingReclaim.displacedByReturner(
            returnerID: returner,
            bindings: [returner: kA, p1: kA, p2: kA, p3: kB]
        )
        XCTAssertEqual(Set(result), Set([p1, p2]))
        XCTAssertFalse(result.contains(returner))
        XCTAssertFalse(result.contains(p3))
    }

    func testReturnerNeverDisplacesItself() {
        let returner = UUID()
        let result = BindingReclaim.displacedByReturner(
            returnerID: returner,
            bindings: [returner: kA]
        )
        XCTAssertEqual(result, [])
    }
}
