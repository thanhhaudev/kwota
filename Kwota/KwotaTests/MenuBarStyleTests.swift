//
//  MenuBarStyleTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class MenuBarStyleTests: XCTestCase {
    func test_resolve_known_rawValues() {
        XCTAssertEqual(MenuBarStyle.resolve("original"), .original)
        XCTAssertEqual(MenuBarStyle.resolve("fillBackground"), .fillBackground)
        XCTAssertEqual(MenuBarStyle.resolve("percentText"), .percentText)
        XCTAssertEqual(MenuBarStyle.resolve("percentRing"), .percentRing)
    }

    func test_resolve_unknown_fallsBackToOriginal() {
        XCTAssertEqual(MenuBarStyle.resolve("garbage"), .original)
        XCTAssertEqual(MenuBarStyle.resolve(""), .original)
        XCTAssertEqual(MenuBarStyle.resolve(nil), .original)
    }

    func test_requiresUsageSource() {
        XCTAssertFalse(MenuBarStyle.original.requiresUsageSource)
        XCTAssertTrue(MenuBarStyle.fillBackground.requiresUsageSource)
        XCTAssertTrue(MenuBarStyle.percentText.requiresUsageSource)
        XCTAssertTrue(MenuBarStyle.percentRing.requiresUsageSource)
    }

    func test_allCases_orderForPicker() {
        XCTAssertEqual(MenuBarStyle.allCases, [.original, .fillBackground, .percentText, .percentRing])
    }
}
