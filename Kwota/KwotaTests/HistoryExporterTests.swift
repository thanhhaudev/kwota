//
//  HistoryExporterTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class HistoryExporterTests: XCTestCase {
    func test_csv_empty_returnsHeaderOnly() {
        XCTAssertEqual(HistoryExporter.csv([]), "at,fiveHour,sevenDay\n")
    }

    func test_csv_singleEntry_emitsRow() {
        let entry = UsageHistoryEntry(
            at: Date(timeIntervalSince1970: 1_700_000_000),
            fiveHour: 42.5,
            sevenDay: 71.0
        )
        let result = HistoryExporter.csv([entry])
        let lines = result.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "at,fiveHour,sevenDay")
        XCTAssertTrue(lines[1].contains("2023-11-14T22:13:20"))
        XCTAssertTrue(lines[1].contains("42.5"))
        XCTAssertTrue(lines[1].contains("71.0"))
    }

    func test_csv_nilFields_emitEmpty() {
        let entry = UsageHistoryEntry(
            at: Date(timeIntervalSince1970: 1_700_000_000),
            fiveHour: nil,
            sevenDay: 80.0
        )
        let result = HistoryExporter.csv([entry])
        let row = result.split(separator: "\n")[1]
        // Two commas, the middle column empty.
        let cols = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(cols.count, 3)
        XCTAssertEqual(cols[1], "")
        XCTAssertEqual(cols[2], "80.0")
    }

    func test_json_roundTrip() throws {
        let entries = [
            UsageHistoryEntry(at: Date(timeIntervalSince1970: 1_700_000_000), fiveHour: 42, sevenDay: nil),
            UsageHistoryEntry(at: Date(timeIntervalSince1970: 1_700_000_300), fiveHour: nil, sevenDay: 71),
        ]
        let data = try HistoryExporter.json(entries)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let decoded = try dec.decode([UsageHistoryEntry].self, from: data)
        XCTAssertEqual(decoded, entries)
    }
}
