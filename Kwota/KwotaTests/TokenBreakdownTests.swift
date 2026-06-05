//
//  TokenBreakdownTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class TokenBreakdownTests: XCTestCase {
    func testBillableExcludesCacheFields() {
        let t = TokenBreakdown(input: 100, output: 50, cacheCreation: 10_000, cacheRead: 50_000)
        XCTAssertEqual(t.billable, 150)
    }

    func testAdditionSumsAllFields() {
        let a = TokenBreakdown(input: 1, output: 2, cacheCreation: 3, cacheRead: 4)
        let b = TokenBreakdown(input: 10, output: 20, cacheCreation: 30, cacheRead: 40)
        let sum = a + b
        XCTAssertEqual(sum.input, 11)
        XCTAssertEqual(sum.output, 22)
        XCTAssertEqual(sum.cacheCreation, 33)
        XCTAssertEqual(sum.cacheRead, 44)
    }

    func testDecodesFromUsageJSON() throws {
        let json = #"""
        {"input_tokens":6,"output_tokens":413,"cache_creation_input_tokens":14142,"cache_read_input_tokens":15093}
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TokenBreakdown.self, from: json)
        XCTAssertEqual(decoded.input, 6)
        XCTAssertEqual(decoded.output, 413)
        XCTAssertEqual(decoded.cacheCreation, 14_142)
        XCTAssertEqual(decoded.cacheRead, 15_093)
    }

    func testDecodesWithMissingCacheFields() throws {
        let json = #"{"input_tokens":10,"output_tokens":20}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TokenBreakdown.self, from: json)
        XCTAssertEqual(decoded.cacheCreation, 0)
        XCTAssertEqual(decoded.cacheRead, 0)
    }
}
