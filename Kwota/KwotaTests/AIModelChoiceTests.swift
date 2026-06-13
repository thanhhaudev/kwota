//
//  AIModelChoiceTests.swift
//  KwotaTests
//
//  Contract for the Claude family-alias model enum. Raw values are CLI
//  `--model` aliases AND persisted in cache-state.json, and the decoder
//  must keep loading pre-alias blobs that stored pinned version IDs.
//

import XCTest
@testable import Kwota

final class AIModelChoiceTests: XCTestCase {

    func testRawValuesAreCLIAliases() {
        XCTAssertEqual(AIModelChoice.opus.rawValue, "opus")
        XCTAssertEqual(AIModelChoice.sonnet.rawValue, "sonnet")
        XCTAssertEqual(AIModelChoice.haiku.rawValue, "haiku")
    }

    func testDefaultIsHaiku() {
        XCTAssertEqual(AIModelChoice.default, .haiku)
    }

    func testAllCasesAreThreeTiers() {
        XCTAssertEqual(Set(AIModelChoice.allCases), [.opus, .sonnet, .haiku])
    }

    // MARK: - Legacy decode (pre-alias blobs stored pinned version IDs)

    private func decode(_ raw: String) throws -> AIModelChoice {
        try JSONDecoder().decode(AIModelChoice.self, from: Data("\"\(raw)\"".utf8))
    }

    func testLegacyPinnedIDsMapToTier() throws {
        XCTAssertEqual(try decode("claude-opus-4-7"), .opus)
        XCTAssertEqual(try decode("claude-opus-4-8"), .opus)
        XCTAssertEqual(try decode("claude-sonnet-4-6"), .sonnet)
        XCTAssertEqual(try decode("claude-haiku-4-5-20251001"), .haiku)
    }

    func testAliasRawValuesRoundTrip() throws {
        XCTAssertEqual(try decode("opus"), .opus)
        XCTAssertEqual(try decode("sonnet"), .sonnet)
        XCTAssertEqual(try decode("haiku"), .haiku)
    }

    func testUnknownRawValueFallsBackToDefault() throws {
        XCTAssertEqual(try decode("claude-fable-5"), .default)
        XCTAssertEqual(try decode("gpt-5.5"), .default)
        XCTAssertEqual(try decode(""), .default)
    }

    func testEncodeUsesAliasRawValue() throws {
        let data = try JSONEncoder().encode(AIModelChoice.opus)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"opus\"")
    }
}
