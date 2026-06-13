//
//  AntigravityModelChoiceTests.swift
//  KwotaTests
//
//  Contract for the Antigravity (agy) model enum. rawValue is a stable
//  persisted slug; cliModelArg is the EXACT `agy models` display string
//  (so agy recognizes it); provenanceLabel is what gets stamped.
//

import XCTest
@testable import Kwota

final class AntigravityModelChoiceTests: XCTestCase {

    func testRawValuesAreStableSlugs() {
        XCTAssertEqual(AntigravityModelChoice.agyDefault.rawValue, "default")
        XCTAssertEqual(AntigravityModelChoice.gemini35FlashLow.rawValue, "gemini-3.5-flash-low")
    }

    func testDefaultIsAgyDefault() {
        XCTAssertEqual(AntigravityModelChoice.default, .agyDefault)
    }

    func testAllCasesAreSix() {
        XCTAssertEqual(AntigravityModelChoice.allCases.count, 6)
    }

    func testDefaultOmitsModelArg() {
        XCTAssertNil(AntigravityModelChoice.agyDefault.cliModelArg,
                     "default must omit --model so agy uses its configured default")
    }

    func testExplicitModelsUseExactAgyDisplayString() {
        XCTAssertEqual(AntigravityModelChoice.gemini35FlashLow.cliModelArg, "Gemini 3.5 Flash (Low)")
        XCTAssertEqual(AntigravityModelChoice.gemini35FlashMedium.cliModelArg, "Gemini 3.5 Flash (Medium)")
        XCTAssertEqual(AntigravityModelChoice.gemini35FlashHigh.cliModelArg, "Gemini 3.5 Flash (High)")
        XCTAssertEqual(AntigravityModelChoice.gemini31ProLow.cliModelArg, "Gemini 3.1 Pro (Low)")
        XCTAssertEqual(AntigravityModelChoice.gemini31ProHigh.cliModelArg, "Gemini 3.1 Pro (High)")
    }

    func testProvenanceLabels() {
        XCTAssertEqual(AntigravityModelChoice.agyDefault.provenanceLabel, "antigravity-default")
        XCTAssertEqual(AntigravityModelChoice.gemini35FlashLow.provenanceLabel, "Gemini 3.5 Flash (Low)")
    }
}
