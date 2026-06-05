//
//  IntNonZeroOrTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class IntNonZeroOrTests: XCTestCase {
    func test_nonZero_returnsSelf() {
        XCTAssertEqual(7.nonZeroOr(99), 7)
    }

    func test_zero_returnsFallback() {
        XCTAssertEqual(0.nonZeroOr(99), 99)
    }

    func test_negative_returnsSelf() {
        // `UserDefaults.integer(forKey:)` returns 0 for absent keys; negative
        // values are explicit user choices and should be honored.
        XCTAssertEqual((-3).nonZeroOr(99), -3)
    }
}
