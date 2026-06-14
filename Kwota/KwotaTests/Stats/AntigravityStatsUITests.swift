//  AntigravityStatsUITests.swift
//  KwotaTests

import XCTest
import SwiftUI
@testable import Kwota

final class AntigravityStatsPaletteTests: XCTestCase {
    func test_geminiFamily_hasBrandColor() {
        XCTAssertEqual(StatsModelPalette.family(of: "gemini-pro-default"), "gemini")
        XCTAssertEqual(StatsModelPalette.color(for: "gemini-pro-default"), .purple)
        XCTAssertEqual(StatsModelPalette.color(for: "Gemini 3.1 Pro (High)"), .purple)
    }
}
