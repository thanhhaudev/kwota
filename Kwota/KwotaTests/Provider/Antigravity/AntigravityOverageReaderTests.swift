//
//  AntigravityOverageReaderTests.swift
//  KwotaTests
//
//  Covers the two-layer protobuf decoder (pure) plus the SQLite read
//  layer against a temp DB fixture. Live state.vscdb format is documented
//  in the spec; these tests pin the encoder shape so the reader doesn't
//  silently break if Google ships a schema change.
//

import XCTest
import SQLite3
@testable import Kwota

@MainActor
final class AntigravityOverageReaderTests: XCTestCase {

    // MARK: - decodeModelCredits (pure protobuf decode)

    /// Wire bytes captured from a live state.vscdb where the toggle is ON.
    /// "CAE=" base64-decodes to `0x08 0x01` = field-1 varint 1.
    func test_decode_returnsTrue_whenSentinelKeyIsOne() {
        let bytes = Self.outerProto(key: "useAICreditsSentinelKey", innerB64: "CAE=")
        XCTAssertEqual(decodeModelCredits(bytes), true)
    }

    /// "CAA=" base64-decodes to `0x08 0x00` = field-1 varint 0 = OFF.
    func test_decode_returnsFalse_whenSentinelKeyIsZero() {
        let bytes = Self.outerProto(key: "useAICreditsSentinelKey", innerB64: "CAA=")
        XCTAssertEqual(decodeModelCredits(bytes), false)
    }

    /// The outer proto has the key we care about absent, but other keys
    /// present. Reader must return nil (no opinion), not false.
    func test_decode_returnsNil_whenSentinelKeyAbsent() {
        let bytes =
            Self.outerProto(key: "minimumCreditAmountForUsageKey", innerB64: "EDI=")
            + Self.outerProto(key: "availableCreditsSentinelKey", innerB64: "EOgH")
        XCTAssertNil(decodeModelCredits(bytes))
    }

    /// Truncated outer proto must not crash; returns nil.
    func test_decode_returnsNil_onTruncatedOuter() {
        let bytes = Data([0x0a, 0xff])
        XCTAssertNil(decodeModelCredits(bytes))
    }

    /// Inner base64 that doesn't decode into a sane proto returns nil.
    func test_decode_returnsNil_onMalformedInner() {
        let bytes = Self.outerProto(key: "useAICreditsSentinelKey", innerB64: "!!!")
        XCTAssertNil(decodeModelCredits(bytes))
    }

    /// Outer length-prefix encodes a value larger than the remaining
    /// buffer. Pre-fix this would cast the length to `Int` and then do
    /// cursor + Int(len) which the bounds check guarded, but a length
    /// past `Int.max` would trap on the cast itself before the guard
    /// could fire. Decoder must return nil cleanly.
    func test_decode_returnsNil_onLengthExceedingRemainingBuffer() {
        // tag 0x0a (length-delimited) + length varint encoding 1000
        // bytes, but the payload that follows is only a couple of bytes.
        let bytes = Data([0x0a, 0xe8, 0x07, 0x00, 0x01])
        XCTAssertNil(decodeModelCredits(bytes))
    }

    /// Maliciously-large length varint that, after decoding, exceeds
    /// `Int.max` on a 64-bit platform. Pre-fix this would trap inside
    /// `Int(UInt64)` and bring down the app on a torn-page read. The
    /// safe helper must reject and return nil.
    func test_decode_returnsNil_onLengthExceedingIntMax() {
        // Build a varint encoding UInt64.max manually: ten 0x7f bytes
        // (each contributes 7 bits) with continuation bit set, then a
        // final byte with no continuation bit and the high bits set.
        var lenVarint = Data()
        for _ in 0..<9 { lenVarint.append(0xff) }
        lenVarint.append(0x7f)
        var bytes = Data([0x0a])
        bytes.append(lenVarint)
        XCTAssertNil(decodeModelCredits(bytes))
    }

    /// Inner-string length inside a KV entry that overruns its own
    /// slice. Same crash surface as the outer case but exercises
    /// `decodeKVEntry` / `decodeInnerSentinel`.
    func test_decode_returnsNil_onInnerLengthOverrun() {
        // Outer entry length 8 bytes, inner key field 1 declares
        // length 200 (> 8 - tag/length overhead). Length is in-range
        // for Int but past the entry's own buffer.
        let entry = Data([
            0x0a,           // tag for inner field 1 (string key)
            0xc8, 0x01,     // varint length = 200
            0x41, 0x42,     // partial payload "AB"
            0x00, 0x00, 0x00
        ])
        var bytes = Data([0x0a])
        bytes.append(UInt8(entry.count))
        bytes.append(entry)
        XCTAssertNil(decodeModelCredits(bytes))
    }

    /// Multi-entry outer: present key wins regardless of order.
    func test_decode_findsSentinelKey_amongMultipleEntries() {
        let bytes =
            Self.outerProto(key: "minimumCreditAmountForUsageKey", innerB64: "EDI=")
            + Self.outerProto(key: "useAICreditsSentinelKey", innerB64: "CAE=")
            + Self.outerProto(key: "availableCreditsSentinelKey", innerB64: "EOgH")
        XCTAssertEqual(decodeModelCredits(bytes), true)
    }

    // MARK: - normalizeModelCreditsColumn

    /// Raw proto bytes (leading 0x0a) pass through untouched.
    func test_normalize_passesThroughRawProto() {
        let raw = Self.outerProto(key: "useAICreditsSentinelKey", innerB64: "CAE=")
        XCTAssertEqual(normalizeModelCreditsColumn(raw), raw)
    }

    /// Live-format: the whole proto is base64-encoded as a TEXT value.
    /// Normalize must base64-decode back to the raw proto.
    func test_normalize_decodesBase64TextColumn() {
        let raw = Self.outerProto(key: "useAICreditsSentinelKey", innerB64: "CAE=")
        let base64Text = raw.base64EncodedData()
        XCTAssertEqual(normalizeModelCreditsColumn(base64Text), raw)
    }

    /// Trailing whitespace/newline on the TEXT value is tolerated.
    func test_normalize_decodesBase64Text_withTrailingNewline() {
        let raw = Self.outerProto(key: "useAICreditsSentinelKey", innerB64: "CAE=")
        var base64Text = raw.base64EncodedData()
        base64Text.append(0x0a) // '\n'
        XCTAssertEqual(normalizeModelCreditsColumn(base64Text), raw)
    }

    /// Non-ASCII junk that is neither raw proto nor base64 is returned
    /// unchanged; the proto decoder then yields nil downstream.
    func test_normalize_fallsBackToRaw_onNonAsciiJunk() {
        let junk = Data([0x99, 0x98, 0x97])
        XCTAssertEqual(normalizeModelCreditsColumn(junk), junk)
    }

    // MARK: - decodeModelCreditsState (all three sentinels)

    func test_decodeState_extractsAllThreeSentinels() {
        let bytes =
            Self.outerProto(key: "minimumCreditAmountForUsageKey", innerB64: "EDI=")   // 50
            + Self.outerProto(key: "useAICreditsSentinelKey", innerB64: "CAE=")          // 1 → on
            + Self.outerProto(key: "availableCreditsSentinelKey", innerB64: "EOgH")      // 1000
        let state = decodeModelCreditsState(bytes)
        XCTAssertEqual(state.overagesEnabled, true)
        XCTAssertEqual(state.availableCredits, 1000)
        XCTAssertEqual(state.minimumCreditForUsage, 50)
    }

    /// availableCredits present, overage toggle absent: the integer
    /// sentinel decodes (field-2 varint) even with no boolean sentinel.
    func test_decodeState_decodesAvailable_withoutToggle() {
        let bytes = Self.outerProto(key: "availableCreditsSentinelKey", innerB64: "EOgH")
        let state = decodeModelCreditsState(bytes)
        XCTAssertNil(state.overagesEnabled)
        XCTAssertEqual(state.availableCredits, 1000)
    }

    /// A malformed entry must not blank the sibling sentinels — the good
    /// entries before and after it still decode.
    func test_decodeState_partialDecode_survivesMalformedEntry() {
        let bytes =
            Self.outerProto(key: "useAICreditsSentinelKey", innerB64: "CAE=")
            + Self.outerProto(key: "availableCreditsSentinelKey", innerB64: "!!!")  // bad inner
            + Self.outerProto(key: "minimumCreditAmountForUsageKey", innerB64: "EDI=")
        let state = decodeModelCreditsState(bytes)
        XCTAssertEqual(state.overagesEnabled, true)
        XCTAssertNil(state.availableCredits)              // dropped (malformed)
        XCTAssertEqual(state.minimumCreditForUsage, 50)   // survived
    }

    // MARK: - readModelCredits (file IO, live base64-TEXT format)

    /// Regression: the live state.vscdb stores modelCredits base64-encoded
    /// as TEXT. Pre-fix the reader fed the raw base64 ASCII bytes straight
    /// into the proto decoder (first byte 0x43 → wire-type 3) and always
    /// returned nil, blanking the On/Off caption. Reader must now decode.
    func test_readModelCredits_decodesBase64TextColumn() throws {
        let raw =
            Self.outerProto(key: "useAICreditsSentinelKey", innerB64: "CAE=")
            + Self.outerProto(key: "availableCreditsSentinelKey", innerB64: "EOgH")
        // sqlite3_column_blob returns identical bytes for a TEXT or BLOB
        // column, so storing the base64 ASCII bytes faithfully reproduces
        // what the reader sees against the live TEXT column.
        let temp = try makeTempDB(modelCreditsBytes: raw.base64EncodedData())
        defer { try? FileManager.default.removeItem(at: temp) }
        let reader = AntigravityOverageReader(dbPath: temp)
        let credits = reader.readModelCredits()
        XCTAssertEqual(credits?.overagesEnabled, true)
        XCTAssertEqual(credits?.availableCredits, 1000)
        // And the legacy convenience accessor still resolves the toggle.
        XCTAssertEqual(reader.readOveragesEnabled(), true)
    }

    /// Legacy raw-proto BLOB format still reads (back-compat).
    func test_readModelCredits_decodesRawProtoBlob() throws {
        let raw = Self.outerProto(key: "useAICreditsSentinelKey", innerB64: "CAA=")
        let temp = try makeTempDB(modelCreditsBytes: raw)
        defer { try? FileManager.default.removeItem(at: temp) }
        let reader = AntigravityOverageReader(dbPath: temp)
        XCTAssertEqual(reader.readModelCredits()?.overagesEnabled, false)
    }

    func test_readModelCredits_returnsNil_whenRowMissing() throws {
        let temp = try makeTempDB(modelCreditsBytes: nil)
        defer { try? FileManager.default.removeItem(at: temp) }
        let reader = AntigravityOverageReader(dbPath: temp)
        XCTAssertNil(reader.readModelCredits())
    }

    // MARK: - readOveragesEnabled (file IO)

    func test_readOveragesEnabled_returnsNil_whenFileMissing() {
        let missing = URL(fileURLWithPath: "/var/empty/does-not-exist.vscdb")
        let reader = AntigravityOverageReader(dbPath: missing)
        XCTAssertNil(reader.readOveragesEnabled())
    }

    func test_readOveragesEnabled_returnsTrue_fromTempDB() throws {
        let temp = try makeTempDB(modelCreditsBytes:
            Self.outerProto(key: "useAICreditsSentinelKey", innerB64: "CAE=")
        )
        defer { try? FileManager.default.removeItem(at: temp) }
        let reader = AntigravityOverageReader(dbPath: temp)
        XCTAssertEqual(reader.readOveragesEnabled(), true)
    }

    func test_readOveragesEnabled_returnsFalse_fromTempDB() throws {
        let temp = try makeTempDB(modelCreditsBytes:
            Self.outerProto(key: "useAICreditsSentinelKey", innerB64: "CAA=")
        )
        defer { try? FileManager.default.removeItem(at: temp) }
        let reader = AntigravityOverageReader(dbPath: temp)
        XCTAssertEqual(reader.readOveragesEnabled(), false)
    }

    func test_readOveragesEnabled_returnsNil_whenKeyRowMissing() throws {
        let temp = try makeTempDB(modelCreditsBytes: nil)
        defer { try? FileManager.default.removeItem(at: temp) }
        let reader = AntigravityOverageReader(dbPath: temp)
        XCTAssertNil(reader.readOveragesEnabled())
    }

    // MARK: - Fixture helpers

    /// Build an outer KV entry as `field 1 (length-delimited)` containing
    /// a nested `{ key, value }` proto. The `value` field carries a single
    /// base64-encoded string at its `field 1`.
    private static func outerProto(key: String, innerB64: String) -> Data {
        let keyBytes = key.data(using: .utf8)!
        let innerBytes = innerB64.data(using: .ascii)!

        // value = { field 1 (length-delimited) = innerBytes }
        var valuePayload = Data()
        valuePayload.append(0x0a)
        valuePayload.append(varint(UInt64(innerBytes.count)))
        valuePayload.append(innerBytes)

        // entry = { field 1 = key, field 2 = value }
        var entry = Data()
        entry.append(0x0a)
        entry.append(varint(UInt64(keyBytes.count)))
        entry.append(keyBytes)
        entry.append(0x12)
        entry.append(varint(UInt64(valuePayload.count)))
        entry.append(valuePayload)

        // outer wrapping: field 1 (length-delimited) = entry
        var out = Data()
        out.append(0x0a)
        out.append(varint(UInt64(entry.count)))
        out.append(entry)
        return out
    }

    private static func varint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        while v >= 0x80 {
            out.append(UInt8((v & 0x7f) | 0x80))
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }

    /// Build a temp SQLite DB with the ItemTable schema and an optional
    /// `antigravityUnifiedStateSync.modelCredits` row. Returns the URL of
    /// the temp file; caller must delete.
    private func makeTempDB(modelCreditsBytes: Data?) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-overage-\(UUID().uuidString).vscdb")
        var dbPtr: OpaquePointer?
        guard sqlite3_open_v2(url.path, &dbPtr,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                              nil) == SQLITE_OK,
              let db = dbPtr
        else { throw NSError(domain: "agy-overage-test", code: 1) }
        defer { sqlite3_close(db) }

        let schema = "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);"
        if sqlite3_exec(db, schema, nil, nil, nil) != SQLITE_OK {
            throw NSError(domain: "agy-overage-test", code: 2)
        }
        if let bytes = modelCreditsBytes {
            var stmt: OpaquePointer?
            let insert = "INSERT INTO ItemTable (key, value) VALUES (?, ?);"
            sqlite3_prepare_v2(db, insert, -1, &stmt, nil)
            defer { sqlite3_finalize(stmt) }
            let key = "antigravityUnifiedStateSync.modelCredits"
            // SQLITE_TRANSIENT so SQLite copies the bytes
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, key, -1, transient)
            _ = bytes.withUnsafeBytes { buf in
                sqlite3_bind_blob(stmt, 2, buf.baseAddress, Int32(buf.count), transient)
            }
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw NSError(domain: "agy-overage-test", code: 3)
            }
        }
        return url
    }
}
