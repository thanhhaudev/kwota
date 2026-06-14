//  ProtobufScannerTests.swift
//  KwotaTests

import XCTest
@testable import Kwota

final class ProtobufScannerTests: XCTestCase {
    // Helpers: minimal proto encoders.
    static func varint(_ v: UInt64) -> Data {
        var x = v, out = Data()
        while x >= 0x80 { out.append(UInt8((x & 0x7f) | 0x80)); x >>= 7 }
        out.append(UInt8(x)); return out
    }
    static func tag(_ field: Int, _ wire: Int) -> Data { varint(UInt64(field << 3 | wire)) }
    static func varintField(_ field: Int, _ value: UInt64) -> Data { tag(field, 0) + varint(value) }
    static func stringField(_ field: Int, _ s: String) -> Data {
        let b = Data(s.utf8); return tag(field, 2) + varint(UInt64(b.count)) + b
    }
    static func msgField(_ field: Int, _ body: Data) -> Data {
        tag(field, 2) + varint(UInt64(body.count)) + body
    }

    /// Nested message `1 { 4 { 2=10, 3=20, 9=5 }, 9 { 4 { 1=1781344349 } }, 19="m" }`.
    func test_scan_extractsNestedVarintsAndStrings() {
        let inner4 = Self.varintField(2, 10) + Self.varintField(3, 20) + Self.varintField(9, 5)
        let inner9 = Self.msgField(4, Self.varintField(1, 1_781_344_349))
        let f1 = Self.msgField(4, inner4) + Self.msgField(9, inner9) + Self.stringField(19, "m")
        let blob = Self.msgField(1, f1)

        let r = ProtobufScanner.scan(blob, wanted: ["1.4.2", "1.4.3", "1.4.9", "1.9.4.1", "1.19"])
        XCTAssertEqual(r.varints["1.4.2"]?.first, 10)
        XCTAssertEqual(r.varints["1.4.3"]?.first, 20)
        XCTAssertEqual(r.varints["1.4.9"]?.first, 5)
        XCTAssertEqual(r.varints["1.9.4.1"]?.first, 1_781_344_349)
        XCTAssertEqual(r.strings["1.19"]?.first, "m")
    }

    /// A truncated length-delimited field must not crash; scan returns what it had.
    func test_scan_returnsCleanlyOnTruncation() {
        let blob = Data([0x0a, 0xff])   // field 1, len 0x7f… but no payload
        let r = ProtobufScanner.scan(blob, wanted: ["1.4.2"])
        XCTAssertNil(r.varints["1.4.2"]?.first)
    }
}
