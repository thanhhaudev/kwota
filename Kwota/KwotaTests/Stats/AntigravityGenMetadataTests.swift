//  AntigravityGenMetadataTests.swift
//  KwotaTests

import XCTest
@testable import Kwota

final class AntigravityGenMetadataTests: XCTestCase {
    typealias F = AntigravityProtoFixture

    func test_decode_mapsTokensWithThinkingFoldedIntoOutput() {
        let blob = F.genBlob(input: 1454, output: 365, cache: 32575, thinking: 301, ts: 1_781_344_349)
        let usage = decodeAntigravityGenMetadata(blob)
        XCTAssertEqual(usage?.tokens.input, 1454)
        XCTAssertEqual(usage?.tokens.output, 365 + 301)        // thinking folded in
        XCTAssertEqual(usage?.tokens.cacheRead, 32575)
        XCTAssertEqual(usage?.tokens.cacheCreation, 0)         // Gemini has no cache-creation
    }

    func test_decode_extractsTimestampAndDisplayModel() {
        let blob = F.genBlob(input: 10, output: 20, cache: 0, thinking: 0, ts: 1_781_344_349)
        let usage = decodeAntigravityGenMetadata(blob)
        XCTAssertEqual(usage?.timestamp, Date(timeIntervalSince1970: 1_781_344_349))
        XCTAssertEqual(usage?.model, "Gemini 3.1 Pro (High)")  // prefers 1.21 display
    }

    func test_decode_returnsNilTimestamp_whenAbsentOrImplausible() {
        let blob = F.genBlob(input: 10, output: 20, cache: 0, thinking: 0, ts: nil)
        XCTAssertNil(decodeAntigravityGenMetadata(blob)?.timestamp)
        XCTAssertNotNil(decodeAntigravityGenMetadata(blob)?.tokens)   // tokens still decode
    }

    func test_decode_returnsNil_whenInputFieldAbsent() {
        // A non-usage row: message 1 with no sub-4.2.
        let blob = F.mfield(1, F.sfield(19, "gemini-pro-default"))
        XCTAssertNil(decodeAntigravityGenMetadata(blob))
    }

    func test_decode_returnsNil_onStructuralConstantDrift() {
        // 1.4.1 present but wrong (999 ∉ {1016,1020}) ⇒ field-map drift ⇒ skip.
        let inner4 = F.vfield(1, 999) + F.vfield(2, 10) + F.vfield(3, 20) + F.vfield(6, 24) + F.vfield(9, 0)
        let blob = F.mfield(1, F.mfield(4, inner4))
        XCTAssertNil(decodeAntigravityGenMetadata(blob))
    }

    func test_decode_returnsNil_onInsaneMagnitude() {
        let blob = F.genBlob(input: 10, output: 999_000_000, cache: 0, thinking: 0, ts: 1_781_344_349)
        XCTAssertNil(decodeAntigravityGenMetadata(blob))   // output > 1e8 cap
    }
}
