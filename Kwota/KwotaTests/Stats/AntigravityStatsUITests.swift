//  AntigravityStatsUITests.swift
//  KwotaTests

import XCTest
import SwiftUI
@testable import Kwota

final class AntigravityStatsPaletteTests: XCTestCase {
    func test_geminiVariants_getDistinctColors() {
        // Gemini is no longer a single brand color: each variant must be
        // distinguishable, so two variants in one view get different colors.
        let models = ["gemini-pro-default", "Gemini 3.1 Pro (High)", "Gemini 3.1 Pro (Low)"]
        let map = StatsModelPalette.colorMap(for: models)
        XCTAssertEqual(StatsModelPalette.family(of: "gemini-pro-default"), "gemini")
        XCTAssertNotEqual(map["Gemini 3.1 Pro (High)"], map["Gemini 3.1 Pro (Low)"])
        for (_, color) in map { XCTAssertNotEqual(color, .orange, "orange is reserved for Sonnet") }
    }
}
