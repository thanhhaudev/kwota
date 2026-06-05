//
//  ProviderPaletteTests.swift
//  KwotaTests
//

import XCTest
import SwiftUI
@testable import Kwota

final class ProviderPaletteTests: XCTestCase {
    func test_knownProvidersMapToTheirAssetColor() {
        XCTAssertEqual(ProviderPalette.color(for: .claude), Color("ProviderClaude"))
        XCTAssertEqual(ProviderPalette.color(for: .codex), Color("ProviderCodex"))
        XCTAssertEqual(ProviderPalette.color(for: .antigravity), Color("ProviderAntigravity"))
    }
}
