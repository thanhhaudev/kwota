//
//  AntigravityQuotaSummaryTests.swift
//

import XCTest
@testable import Kwota

final class AntigravityQuotaSummaryTests: XCTestCase {
    /// Verbatim shape captured from the live RetrieveUserQuotaSummary RPC
    /// (2026-06-13). Gemini 5h drained to 20% remaining, weekly full; the
    /// Claude/GPT group weekly drained to 8% remaining, 5h full — so the
    /// "worst per window" and "binding group" assertions exercise both axes.
    private let sampleJSON = """
    {"response":{"groups":[
      {"displayName":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro",
       "buckets":[
         {"bucketId":"gemini-weekly","displayName":"Weekly Limit","window":"weekly","remainingFraction":1,"resetTime":"2026-06-20T10:40:07Z"},
         {"bucketId":"gemini-5h","displayName":"Five Hour Limit","window":"5h","remainingFraction":0.2,"resetTime":"2026-06-13T15:40:07Z"}]},
      {"displayName":"Claude and GPT models","description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
       "buckets":[
         {"bucketId":"3p-weekly","displayName":"Weekly Limit","window":"weekly","remainingFraction":0.08,"resetTime":"2026-06-20T10:40:07Z"},
         {"bucketId":"3p-5h","displayName":"Five Hour Limit","window":"5h","remainingFraction":1,"resetTime":"2026-06-13T15:40:07Z"}]}],
     "description":"Within each group, models share a weekly limit and a 5-hour limit."}}
    """

    private func decode(_ s: String) throws -> AntigravityQuotaSummary {
        try AntigravityQuotaSummary.decoder.decode(
            AntigravityQuotaSummary.self, from: Data(s.utf8))
    }

    func test_decode_twoGroupsTwoBuckets() throws {
        let q = try decode(sampleJSON)
        XCTAssertEqual(q.groups.count, 2)
        XCTAssertEqual(q.groups[0].displayName, "Gemini Models")
        XCTAssertEqual(q.groups[1].displayName, "Claude and GPT models")
        XCTAssertEqual(q.description, "Within each group, models share a weekly limit and a 5-hour limit.")
    }

    func test_bucketsKeyedByWindowNotIndex() throws {
        let gemini = try decode(sampleJSON).groups[0]
        XCTAssertEqual(gemini.weekly?.window, .weekly)
        XCTAssertEqual(gemini.fiveHour?.window, .fiveHour)
        XCTAssertEqual(gemini.weekly?.displayName, "Weekly Limit")
        XCTAssertEqual(gemini.fiveHour?.displayName, "Five Hour Limit")
    }

    func test_utilizationIsConsumedPercent() throws {
        let gemini = try decode(sampleJSON).groups[0]
        XCTAssertEqual(gemini.fiveHour?.utilization ?? -1, 80, accuracy: 0.001)
        XCTAssertEqual(gemini.weekly?.utilization ?? -1, 0, accuracy: 0.001)
    }

    func test_groupWorstUtilization() throws {
        let q = try decode(sampleJSON)
        XCTAssertEqual(q.groups[0].worstUtilization ?? -1, 80, accuracy: 0.001)
        XCTAssertEqual(q.groups[1].worstUtilization ?? -1, 92, accuracy: 0.001)
    }

    func test_worstPerWindowAcrossGroups() throws {
        let q = try decode(sampleJSON)
        XCTAssertEqual(q.worstFiveHour?.group.displayName, "Gemini Models")
        XCTAssertEqual(q.worstFiveHour?.bucket.utilization ?? -1, 80, accuracy: 0.001)
        XCTAssertEqual(q.worstWeekly?.group.displayName, "Claude and GPT models")
        XCTAssertEqual(q.worstWeekly?.bucket.utilization ?? -1, 92, accuracy: 0.001)
    }

    func test_bindingGroupKey_isMostConstrainedGroup() throws {
        let q = try decode(sampleJSON)
        XCTAssertEqual(q.bindingGroupKey, "3p")
    }

    func test_groupKey_fromBucketIdPrefix() throws {
        let q = try decode(sampleJSON)
        XCTAssertEqual(q.groups[0].key, "gemini")
        XCTAssertEqual(q.groups[1].key, "3p")
    }

    func test_resetTimeDecoded() throws {
        let gemini = try decode(sampleJSON).groups[0]
        let expected = ISO8601DateFormatter().date(from: "2026-06-13T15:40:07Z")
        XCTAssertEqual(gemini.fiveHour?.resetTime, expected)
    }

    func test_unknownWindow_tolerated() throws {
        let s = """
        {"response":{"groups":[{"displayName":"X","buckets":[
          {"window":"monthly","remainingFraction":0.5}]}]}}
        """
        let q = try decode(s)
        XCTAssertEqual(q.groups.first?.buckets.first?.window, .unknown)
        XCTAssertNil(q.groups.first?.weekly)
        XCTAssertNil(q.groups.first?.fiveHour)
    }

    func test_missingFields_default() throws {
        let q = try decode(#"{"response":{}}"#)
        XCTAssertEqual(q.groups.count, 0)
        XCTAssertNil(q.bindingGroupKey)
        XCTAssertNil(q.worstFiveHour)
    }

    func test_groupKey_fallsBackToDisplayNameSlug() throws {
        let s = #"{"response":{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"5h","remainingFraction":1}]}]}}"#
        XCTAssertEqual(try decode(s).groups[0].key, "gemini-models")
    }
}
