//  AntigravityStatsReaderTests.swift
//  KwotaTests

import XCTest
@testable import Kwota

final class AntigravityStatsReaderTests: XCTestCase {
    func test_appPaths_conversationDirs_coverIDEAndCLI() {
        let paths = AppPaths.antigravityConversationDirs.map(\.path)
        XCTAssertTrue(paths.contains { $0.hasSuffix("/.gemini/antigravity/conversations") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("/.gemini/antigravity-cli/conversations") })
    }
}
