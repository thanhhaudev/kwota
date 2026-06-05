//
//  DisplayThemeTests.swift
//  KwotaTests
//

import XCTest
import SwiftUI
@testable import Kwota

final class DisplayThemeTests: XCTestCase {
    func test_resolve_nil_returnsSystem() {
        XCTAssertEqual(DisplayTheme.resolve(nil), .system)
    }

    func test_resolve_unknown_returnsSystem() {
        XCTAssertEqual(DisplayTheme.resolve("foobar"), .system)
    }

    func test_resolve_validRawValues_roundTrip() {
        for c in DisplayTheme.allCases {
            XCTAssertEqual(DisplayTheme.resolve(c.rawValue), c)
        }
    }

    func test_colorScheme_system_isNil() {
        XCTAssertNil(DisplayTheme.system.colorScheme)
    }

    func test_colorScheme_light_isLight() {
        XCTAssertEqual(DisplayTheme.light.colorScheme, .light)
    }

    func test_colorScheme_dark_isDark() {
        XCTAssertEqual(DisplayTheme.dark.colorScheme, .dark)
    }
}
