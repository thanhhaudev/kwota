//
//  StatsFormatTests.swift
//  KwotaTests
//

import XCTest
import SwiftUI
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
        XCTAssertEqual(StatsFormat.tokens(999_999_999), "1000.0M")  // just under 1B
    }

    func test_tokens_billionsAndTrillions() {
        XCTAssertEqual(StatsFormat.tokens(1_000_000_000),     "1.0B")
        XCTAssertEqual(StatsFormat.tokens(4_744_000_000),     "4.7B")
        XCTAssertEqual(StatsFormat.tokens(1_000_000_000_000), "1.0T")
        XCTAssertEqual(StatsFormat.tokens(2_500_000_000_000), "2.5T")
    }

    func test_full_groupsDigitsWithCommas() {
        XCTAssertEqual(StatsFormat.full(0), "0")
        XCTAssertEqual(StatsFormat.full(61_900), "61,900")
        XCTAssertEqual(StatsFormat.full(4_744_000_000), "4,744,000,000")
    }

    // MARK: StatsModelPalette.label

    func test_label_stripsClaudePrefixAndPrettifiesVersion() {
        XCTAssertEqual(StatsModelPalette.label(for: "claude-opus-4-8"),   "opus 4.8")
        XCTAssertEqual(StatsModelPalette.label(for: "claude-sonnet-4-6"), "sonnet 4.6")
        XCTAssertEqual(StatsModelPalette.label(for: "claude-haiku-3-5"),  "haiku 3.5")
        // Date suffix is preserved, not special-cased.
        XCTAssertEqual(StatsModelPalette.label(for: "claude-haiku-4-5-20251001"), "haiku 4.5.20251001")
        // A bare model name with no version stays as-is.
        XCTAssertEqual(StatsModelPalette.label(for: "claude-opus"), "opus")
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

    func test_color_brandFamiliesMatchUsageUI() {
        // Must match PerModelCard: Opus = blue, Sonnet = orange.
        XCTAssertEqual(StatsModelPalette.color(for: "claude-sonnet-4-6"), .orange)
        XCTAssertEqual(StatsModelPalette.color(for: "claude-opus-4-8"), .blue)
        XCTAssertEqual(StatsModelPalette.color(for: "claude-opus-4-7"), .blue)   // versions share family color
        XCTAssertEqual(StatsModelPalette.color(for: "claude-haiku-4-5-20251001"), .teal)
    }

    func test_family_extractsModelFamily() {
        XCTAssertEqual(StatsModelPalette.family(of: "claude-sonnet-4-6"), "sonnet")
        XCTAssertEqual(StatsModelPalette.family(of: "claude-opus-4-8"), "opus")
        XCTAssertEqual(StatsModelPalette.family(of: "gpt-5.5"), "gpt")
    }
}
