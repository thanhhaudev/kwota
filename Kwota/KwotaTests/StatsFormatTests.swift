//
//  StatsFormatTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class StatsFormatTests: XCTestCase {

    // MARK: StatsFormat.tokens

    func test_tokens_belowThousand() {
        XCTAssertEqual(StatsFormat.tokens(0),   "0")
        XCTAssertEqual(StatsFormat.tokens(1),   "1")
        XCTAssertEqual(StatsFormat.tokens(999), "999")
    }

    func test_tokens_thousands() {
        XCTAssertEqual(StatsFormat.tokens(1_000),  "1.0K")
        XCTAssertEqual(StatsFormat.tokens(1_500),  "1.5K")
        XCTAssertEqual(StatsFormat.tokens(12_300), "12.3K")
        XCTAssertEqual(StatsFormat.tokens(999_999),"1000.0K")
    }

    func test_tokens_millions() {
        XCTAssertEqual(StatsFormat.tokens(1_000_000), "1.0M")
        XCTAssertEqual(StatsFormat.tokens(1_200_000), "1.2M")
        XCTAssertEqual(StatsFormat.tokens(2_000_000), "2.0M")
    }

    // MARK: StatsModelPalette.label

    func test_label_stripsClaudePrefix() {
        XCTAssertEqual(StatsModelPalette.label(for: "claude-opus-4-8"),  "opus-4-8")
        XCTAssertEqual(StatsModelPalette.label(for: "claude-sonnet-4-6"), "sonnet-4-6")
        XCTAssertEqual(StatsModelPalette.label(for: "claude-haiku-3-5"),  "haiku-3-5")
    }

    func test_label_unknownPassthrough() {
        XCTAssertEqual(StatsModelPalette.label(for: "unknown"), "unknown")
    }

    func test_label_nonClaudePassthrough() {
        XCTAssertEqual(StatsModelPalette.label(for: "gpt-5.5"), "gpt-5.5")
    }

    // MARK: StatsModelPalette.color stability within a run

    func test_color_sameModelReturnsSameColor() {
        let a = StatsModelPalette.color(for: "claude-opus-4-8")
        let b = StatsModelPalette.color(for: "claude-opus-4-8")
        XCTAssertEqual(a, b, "Same model must yield same color within a process run")
    }
}
