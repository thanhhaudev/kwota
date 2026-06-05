//
//  ProviderIDTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class ProviderIDTests: XCTestCase {
    func testUnknownRawValueDecodesAsClaude() throws {
        // Unknown raw values fall back to .claude rather than crashing the
        // load. Claude is the longest-standing provider and the original
        // default, so legacy profiles.json without the field land here too.
        let json = Data("\"openai\"".utf8)
        let decoded = try JSONDecoder().decode(ProviderID.self, from: json)
        XCTAssertEqual(decoded, .claude)
    }

    func testInitFromRawValue() {
        XCTAssertEqual(ProviderID(rawValue: "claude"), .claude)
        XCTAssertEqual(ProviderID(rawValue: "openai"), .claude)
    }

    func test_codex_codable_decodesAsCodex() throws {
        let json = Data("\"codex\"".utf8)
        let decoded = try JSONDecoder().decode(ProviderID.self, from: json)
        XCTAssertEqual(decoded, .codex)
    }

    func test_antigravity_roundTripsRawValue() {
        XCTAssertEqual(ProviderID.antigravity.rawValue, "antigravity")
        XCTAssertEqual(ProviderID(rawValue: "antigravity"), .antigravity)
    }

    func test_antigravity_decodesFromJSONString() throws {
        let data = Data("\"antigravity\"".utf8)
        let decoded = try JSONDecoder().decode(ProviderID.self, from: data)
        XCTAssertEqual(decoded, .antigravity)
    }

    func test_antigravity_encodesAsJSONString() throws {
        let data = try JSONEncoder().encode(ProviderID.antigravity)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"antigravity\"")
    }
}
