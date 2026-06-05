//
//  AntigravityOverageReader.swift
//  Kwota
//
//  Reads the "Enable AI Credit Overages" toggle from Antigravity's
//  globalStorage SQLite database. Antigravity stores its model-credits
//  preferences as a nested protobuf-as-base64-string under the
//  `antigravityUnifiedStateSync.modelCredits` row of ItemTable. This
//  reader opens the DB read-only with the `unix-none` VFS so we never
//  block writes that the Antigravity process is doing concurrently.
//
//  Wire format (documented in the rework spec):
//
//     ItemTable[`antigravityUnifiedStateSync.modelCredits`] (column)
//      └─ on live installs the column is base64-encoded TEXT; older
//         builds stored the raw proto bytes. We normalize both to:
//      └─ outer proto: repeated { string key = 1; bytes value = 2 }
//          └─ value: { string field 1 } where the string is base64
//              └─ inner proto: { varint field 1|2 }
//                   - useAICreditsSentinelKey      → field 1 = 1|0 (ON|OFF)
//                   - availableCreditsSentinelKey  → field 2 = balance
//                   - minimumCreditAmountForUsageKey → field 2 = floor
//

import Foundation
import SQLite3

/// The three sentinels carried by the `modelCredits` blob. Every field is
/// optional: a torn-page / schema-drift read may surface some and not
/// others, and callers MUST treat a missing field as "unknown" — never as
/// a concrete zero/off — so a flaky read doesn't grey out a working wallet.
struct AntigravityModelCredits: Equatable {
    /// "Enable AI Credit Overages" toggle. true = AI Credits will drain;
    /// false = wallet present but inert; nil = unknown.
    let overagesEnabled: Bool?
    /// AI-credit balance Antigravity last synced to disk. Used as a
    /// fallback for the live API wallet when the API returns none.
    let availableCredits: Int64?
    /// Stranded-balance floor (observed 50): credits below this can't be
    /// spent. Decoded for completeness; not surfaced in the UI today.
    let minimumCreditForUsage: Int64?

    init(overagesEnabled: Bool?,
         availableCredits: Int64? = nil,
         minimumCreditForUsage: Int64? = nil) {
        self.overagesEnabled = overagesEnabled
        self.availableCredits = availableCredits
        self.minimumCreditForUsage = minimumCreditForUsage
    }

    /// Convenience for callers (and tests) that only carry the toggle.
    static func overages(_ enabled: Bool?) -> AntigravityModelCredits {
        AntigravityModelCredits(overagesEnabled: enabled)
    }
}

@MainActor
struct AntigravityOverageReader {
    let dbPath: URL

    init(dbPath: URL = AppPaths.antigravityGlobalStorageDB) {
        self.dbPath = dbPath
    }

    /// Returns the current "Enable AI Credit Overages" toggle.
    /// - `true`  → overages enabled (AI Credits will drain).
    /// - `false` → overages disabled (wallet present but inert).
    /// - `nil`   → DB missing, row missing, or decode failed. Callers
    ///   MUST treat nil as "unknown" — never as "off" — so a flaky read
    ///   doesn't quietly grey out a working wallet.
    func readOveragesEnabled() -> Bool? {
        readModelCredits()?.overagesEnabled
    }

    /// Reads all three modelCredits sentinels in one DB open. Returns nil
    /// when the DB/row is missing or the blob decodes to nothing at all;
    /// a partial decode (some sentinels present) returns a struct with the
    /// missing fields nil.
    func readModelCredits() -> AntigravityModelCredits? {
        guard let column = readModelCreditsBlob() else { return nil }
        let proto = normalizeModelCreditsColumn(column)
        let state = decodeModelCreditsState(proto)
        guard state.overagesEnabled != nil
                || state.availableCredits != nil
                || state.minimumCreditForUsage != nil
        else { return nil }
        return state
    }

    private func readModelCreditsBlob() -> Data? {
        guard FileManager.default.fileExists(atPath: dbPath.path) else { return nil }

        var dbPtr: OpaquePointer?
        // `unix-none` VFS = no locking. We are reading a live SQLite file
        // managed by another process, and the OS lock would otherwise
        // contend with Antigravity's own writes. With wide-open R/O and
        // no lock we can occasionally read a torn page; the decoder
        // returns nil in that case, which the UI degrades cleanly.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbPath.path, &dbPtr, flags, "unix-none") == SQLITE_OK,
              let db = dbPtr
        else {
            if let db = dbPtr { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = 'antigravityUnifiedStateSync.modelCredits' LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt = stmt
        else { return nil }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let raw = sqlite3_column_blob(stmt, 0) else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, 0))
        guard n > 0 else { return nil }
        return Data(bytes: raw, count: n)
    }
}

// MARK: - Pure decoder (unit-testable in isolation)

/// Normalize a raw `modelCredits` column to outer-proto bytes. Live
/// installs store the proto base64-encoded as a TEXT value; older builds
/// stored the raw proto bytes. The outer proto always begins with the KV
/// tag `0x0a`, a byte that never starts a base64 payload (base64's
/// alphabet is `A-Za-z0-9+/=`), so the first byte disambiguates: `0x0a`
/// → already raw; anything else → try base64, falling back to the raw
/// bytes if the decode fails (the proto decoder then returns nil on junk).
///
/// Pure function — no IO. Internal so tests can pin its behavior.
func normalizeModelCreditsColumn(_ column: Data) -> Data {
    guard let first = column.first, first != 0x0a else { return column }
    guard let text = String(data: column, encoding: .ascii) else { return column }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let decoded = Data(base64Encoded: trimmed) { return decoded }
    return column
}

/// Decode the `modelCredits` outer proto into its three sentinels. Walks
/// every `{ string key=1; bytes value=2 }` entry and dispatches on the
/// key. A malformed/truncated entry is skipped (its sentinel stays nil)
/// rather than aborting the whole decode, so one torn field can't blank
/// the others.
///
/// Pure function — no IO. Internal so tests can pin its behavior without
/// going through SQLite.
func decodeModelCreditsState(_ data: Data) -> AntigravityModelCredits {
    var overages: Bool?
    var available: Int64?
    var minimum: Int64?
    var cursor = data.startIndex
    while cursor < data.endIndex {
        guard let tag = readVarint(data, &cursor) else { break }
        // We only care about field 1, wire-type 2 (= 0x0a). Skip others.
        if tag != 0x0a {
            guard skipField(data, &cursor, tag: tag) else { break }
            continue
        }
        guard let entryLen = readVarint(data, &cursor),
              let n = safeLength(entryLen, cursor: cursor, in: data)
        else { break }
        let entryEnd = data.index(cursor, offsetBy: n)
        let entry = Data(data[cursor..<entryEnd])
        cursor = entryEnd
        guard let kv = decodeKVEntry(entry) else { continue }
        switch kv.key {
        case "useAICreditsSentinelKey":       overages = kv.value != 0
        case "availableCreditsSentinelKey":   available = Int64(exactly: kv.value)
        case "minimumCreditAmountForUsageKey": minimum = Int64(exactly: kv.value)
        default: break
        }
    }
    return AntigravityModelCredits(
        overagesEnabled: overages,
        availableCredits: available,
        minimumCreditForUsage: minimum
    )
}

/// Decode the `useAICreditsSentinelKey` boolean only — thin wrapper kept
/// for existing callers/tests that care about just the toggle.
func decodeModelCredits(_ data: Data) -> Bool? {
    decodeModelCreditsState(data).overagesEnabled
}

/// One `{ string key=1, bytes value=2 }` entry. Returns the key and its
/// decoded inner varint, or nil if the entry is malformed or its inner
/// value doesn't decode (caller skips it).
///
/// `entry` is passed as plain `Data` (re-wrapped from a SubSequence by
/// the caller) so `readVarint` / `skipField` have one signature to bind
/// against. Foundation's `Data.SubSequence == Data` so the underlying
/// storage is the same — no copy beyond the existing slice.
private func decodeKVEntry(_ data: Data) -> (key: String, value: UInt64)? {
    var cursor = data.startIndex
    var key: String?
    var valueBytes: Data?
    while cursor < data.endIndex {
        guard let tag = readVarint(data, &cursor) else { return nil }
        switch tag {
        case 0x0a: // string key
            guard let len = readVarint(data, &cursor),
                  let n = safeLength(len, cursor: cursor, in: data)
            else { return nil }
            let end = data.index(cursor, offsetBy: n)
            guard let s = String(data: data[cursor..<end], encoding: .utf8) else { return nil }
            key = s
            cursor = end
        case 0x12: // value bytes (contains the base64-string proto)
            guard let len = readVarint(data, &cursor),
                  let n = safeLength(len, cursor: cursor, in: data)
            else { return nil }
            let end = data.index(cursor, offsetBy: n)
            valueBytes = Data(data[cursor..<end])
            cursor = end
        default:
            guard skipField(data, &cursor, tag: tag) else { return nil }
        }
    }
    guard let key, let value = decodeInnerSentinel(valueBytes) else { return nil }
    return (key, value)
}

/// Inner shape (the proto stored under field 2 of the KV entry):
///     { string field 1 = base64-encoded-bytes }
/// Decode the field-1 string, base64-decode it into bytes, then read the
/// leading varint. Booleans encode under field 1 (tag `0x08`); integer
/// sentinels (available credits, minimum floor) encode under field 2
/// (tag `0x10`). Either is accepted; the raw varint is returned and the
/// caller interprets it per key.
private func decodeInnerSentinel(_ bytes: Data?) -> UInt64? {
    guard let bytes = bytes else { return nil }
    var cursor = bytes.startIndex
    guard let tag = readVarint(bytes, &cursor), tag == 0x0a,
          let len = readVarint(bytes, &cursor),
          let n = safeLength(len, cursor: cursor, in: bytes)
    else { return nil }
    let end = bytes.index(cursor, offsetBy: n)
    guard let b64 = String(data: bytes[cursor..<end], encoding: .ascii),
          let inner = Data(base64Encoded: b64)
    else { return nil }
    var innerCursor = inner.startIndex
    guard let innerTag = readVarint(inner, &innerCursor),
          innerTag == 0x08 || innerTag == 0x10,
          let value = readVarint(inner, &innerCursor)
    else { return nil }
    return value
}

// MARK: - Protobuf varint primitives

/// Read a base-128 varint at `cursor`, advancing it. Returns nil on
/// truncation. Caps at 10 bytes (proto3 max).
private func readVarint(_ data: Data, _ cursor: inout Data.Index) -> UInt64? {
    var result: UInt64 = 0
    var shift: UInt64 = 0
    var read = 0
    while cursor < data.endIndex {
        let byte = data[cursor]
        cursor = data.index(after: cursor)
        result |= UInt64(byte & 0x7f) << shift
        if byte & 0x80 == 0 { return result }
        shift += 7
        read += 1
        if read > 10 { return nil }
    }
    return nil
}

/// Skip an unknown field given its tag. Wire types:
///   0 varint, 1 fixed64, 2 length-delimited, 5 fixed32. We never see
///   1 or 5 in this DB but handle them so a schema bump won't crash.
private func skipField(_ data: Data, _ cursor: inout Data.Index, tag: UInt64) -> Bool {
    let wireType = tag & 0x7
    switch wireType {
    case 0:
        return readVarint(data, &cursor) != nil
    case 1:
        guard let n = safeLength(8, cursor: cursor, in: data) else { return false }
        cursor = data.index(cursor, offsetBy: n)
        return true
    case 2:
        guard let len = readVarint(data, &cursor),
              let n = safeLength(len, cursor: cursor, in: data)
        else { return false }
        cursor = data.index(cursor, offsetBy: n)
        return true
    case 5:
        guard let n = safeLength(4, cursor: cursor, in: data) else { return false }
        cursor = data.index(cursor, offsetBy: n)
        return true
    default:
        return false
    }
}

/// Convert a wire-encoded `UInt64` length into a safe `Int` byte count,
/// or nil if the length doesn't fit in `Int` or would overrun the
/// remaining buffer from `cursor`. Used by every length-delimited
/// decode step so a torn-page / schema-drift blob can never trap on
/// `Int(len)` cast or on `cursor + Int(len)` arithmetic.
///
/// 64-bit macOS: `Int(exactly:)` rejects any `UInt64` > `Int.max`
/// (which the unchecked `Int(_:)` cast would otherwise trap on).
private func safeLength(_ len: UInt64, cursor: Data.Index, in data: Data) -> Int? {
    guard let n = Int(exactly: len) else { return nil }
    let remaining = data.distance(from: cursor, to: data.endIndex)
    guard n >= 0, n <= remaining else { return nil }
    return n
}
