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

    // MARK: StatsModelPalette.colorMap — set-based distinct assignment

    func test_colorMap_stableForSameSet() {
        let models = ["claude-opus-4-8", "claude-sonnet-4-6", "gpt-5.5"]
        XCTAssertEqual(StatsModelPalette.colorMap(for: models),
                       StatsModelPalette.colorMap(for: models),
                       "Same set must yield the same assignment")
    }

    func test_colorMap_pinsSonnetToOrange() {
        // Sonnet must stay orange to match PerModelCard's "Sonnet only".
        let map = StatsModelPalette.colorMap(for: ["claude-sonnet-4-6", "claude-sonnet-4-5", "claude-opus-4-8"])
        XCTAssertEqual(map["claude-sonnet-4-6"], .orange)
        XCTAssertEqual(map["claude-sonnet-4-5"], .orange, "all sonnet versions share orange")
    }

    func test_colorMap_pinsFableToPink() {
        // Fable must stay pink to match PerModelCard's "Fable only".
        let map = StatsModelPalette.colorMap(for: ["claude-fable-5", "claude-opus-4-8"])
        XCTAssertEqual(map["claude-fable-5"], .pink)
    }

    func test_colorMap_pinsOpusToBlue() {
        // Opus must stay blue to match PerModelCard's "Opus" — and so it can
        // never drift onto a pink-adjacent palette color next to Fable.
        let map = StatsModelPalette.colorMap(for: ["claude-opus-4-8", "claude-fable-5", "gpt-5.5"])
        XCTAssertEqual(map["claude-opus-4-8"], .blue)
    }

    func test_colorMap_avoidsReservedColors() {
        // Blue/orange/pink are reserved for pinned Opus/Sonnet/Fable, green
        // for the daily-average rule; no other model may take any of them.
        let map = StatsModelPalette.colorMap(for: ["claude-haiku-4-5-20251001", "gpt-5.5", "gemini-3.1-pro"])
        for (_, color) in map {
            XCTAssertNotEqual(color, .blue)
            XCTAssertNotEqual(color, .orange)
            XCTAssertNotEqual(color, .pink)
            XCTAssertNotEqual(color, .green)
        }
    }

    func test_colorMap_assignsDistinctColors() {
        let models = ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex", "codex-auto-review"]
        let colors = StatsModelPalette.colorMap(for: models).values.map { $0 }
        for i in colors.indices {
            for j in colors.indices where j > i {
                XCTAssertNotEqual(colors[i], colors[j], "models in one view must not collide on a color")
            }
        }
    }

    func test_family_extractsModelFamily() {
        XCTAssertEqual(StatsModelPalette.family(of: "claude-sonnet-4-6"), "sonnet")
        XCTAssertEqual(StatsModelPalette.family(of: "claude-opus-4-8"), "opus")
        XCTAssertEqual(StatsModelPalette.family(of: "gpt-5.5"), "gpt")
    }
}
