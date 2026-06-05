//
//  AboutVersionStringTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class AboutVersionStringTests: XCTestCase {
    func test_displayLabel_present() {
        let s = AboutVersionString.displayLabel(short: "1.2")
        XCTAssertEqual(s, "Version 1.2")
    }

    func test_displayLabel_missingShort_fallsBackToDash() {
        let s = AboutVersionString.displayLabel(short: nil)
        XCTAssertEqual(s, "Version —")
    }

    func test_clipboardText_combinesFields() {
        let s = AboutVersionString.clipboardText(
            short: "1.2",
            macOSVersion: "14.5.1"
        )
        XCTAssertEqual(s, "Kwota 1.2 — macOS 14.5.1")
    }

    func test_clipboardText_handlesMissingFields() {
        let s = AboutVersionString.clipboardText(
            short: nil,
            macOSVersion: "14.5.1"
        )
        XCTAssertEqual(s, "Kwota — — macOS 14.5.1")
    }
}
