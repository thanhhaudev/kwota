//
//  OffMainTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class OffMainTests: XCTestCase {
    func testRunExecutesOffMainThread() async {
        let ranOnMain = await OffMain.run { Thread.isMainThread }
        XCTAssertFalse(
            ranOnMain,
            "OffMain.run must execute its work off the main thread — that is its entire purpose."
        )
    }

    func testRunReturnsWorkResult() async {
        let result = await OffMain.run { 6 * 7 }
        XCTAssertEqual(result, 42)
    }

    func testThrowingRunReturnsValue() async throws {
        let value = try await OffMain.run { () -> String in "ok" }
        XCTAssertEqual(value, "ok")
    }

    func testThrowingRunPropagatesError() async {
        struct Boom: Error {}
        do {
            _ = try await OffMain.run { () -> Int in throw Boom() }
            XCTFail("expected the thrown error to propagate")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("propagated the wrong error: \(error)")
        }
    }

    func testThrowingRunAlsoRunsOffMainThread() async throws {
        let ranOnMain = try await OffMain.run { () -> Bool in Thread.isMainThread }
        XCTAssertFalse(ranOnMain)
    }
}
