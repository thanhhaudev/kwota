//  AntigravityProtoFixture.swift
//  KwotaTests
//
//  Builds `gen_metadata`-shaped protobuf blobs and temp SQLite DBs that match
//  the wire format reverse-engineered from real Antigravity conversation DBs.

import Foundation
import SQLite3
@testable import Kwota

enum AntigravityProtoFixture {
    static func varint(_ v: UInt64) -> Data {
        var x = v, out = Data()
        while x >= 0x80 { out.append(UInt8((x & 0x7f) | 0x80)); x >>= 7 }
        out.append(UInt8(x)); return out
    }
    static func tag(_ field: Int, _ wire: Int) -> Data { varint(UInt64(field << 3 | wire)) }
    static func vfield(_ field: Int, _ value: UInt64) -> Data { tag(field, 0) + varint(value) }
    static func sfield(_ field: Int, _ s: String) -> Data {
        let b = Data(s.utf8); return tag(field, 2) + varint(UInt64(b.count)) + b
    }
    static func mfield(_ field: Int, _ body: Data) -> Data {
        tag(field, 2) + varint(UInt64(body.count)) + body
    }

    /// One `gen_metadata.data` blob:
    ///   1 { 4 { 1=1016, 2=input, 3=output, 5=cache, 6=24, 9=thinking },
    ///       9 { 4 { 1=ts } }, 19=apiModel, 21=displayModel }
    static func genBlob(input: UInt64, output: UInt64, cache: UInt64, thinking: UInt64,
                        ts: UInt64?, apiModel: String? = "gemini-pro-default",
                        displayModel: String? = "Gemini 3.1 Pro (High)",
                        includeConstants: Bool = true) -> Data {
        var inner4 = Data()
        if includeConstants { inner4 += vfield(1, 1016) }
        inner4 += vfield(2, input) + vfield(3, output) + vfield(5, cache)
        if includeConstants { inner4 += vfield(6, 24) }
        inner4 += vfield(9, thinking)

        var f1 = mfield(4, inner4)
        if let ts { f1 += mfield(9, mfield(4, vfield(1, ts))) }
        if let apiModel { f1 += sfield(19, apiModel) }
        if let displayModel { f1 += sfield(21, displayModel) }
        return mfield(1, f1)
    }

    /// Build a temp conversation DB directory containing one `<id>.db` with a
    /// `gen_metadata` table populated from `blobs` (idx assigned 0,1,2,…).
    /// Returns (rootDir, dbURL). Caller removes rootDir.
    @discardableResult
    static func makeConversationDB(id: String = UUID().uuidString,
                                   blobs: [Data]) throws -> (root: URL, db: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-stats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = root.appendingPathComponent("\(id).db")
        try writeGenMetadata(db: db, blobs: blobs, startIdx: 0)
        return (root, db)
    }

    /// Append `blobs` to an existing (or new) DB starting at `startIdx`.
    static func writeGenMetadata(db: URL, blobs: [Data], startIdx: Int) throws {
        var dbPtr: OpaquePointer?
        guard sqlite3_open_v2(db.path, &dbPtr,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let handle = dbPtr else { throw NSError(domain: "agy-stats-test", code: 1) }
        defer { sqlite3_close(handle) }
        let schema = "CREATE TABLE IF NOT EXISTS gen_metadata (idx INTEGER PRIMARY KEY, data BLOB, size INTEGER NOT NULL DEFAULT 0);"
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "agy-stats-test", code: 2)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, blob) in blobs.enumerated() {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "INSERT INTO gen_metadata (idx, data, size) VALUES (?, ?, ?);", -1, &stmt, nil) == SQLITE_OK else {
                throw NSError(domain: "agy-stats-test", code: 4)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(startIdx + offset))
            _ = blob.withUnsafeBytes { buf in
                sqlite3_bind_blob(stmt, 2, buf.baseAddress, Int32(buf.count), transient)
            }
            sqlite3_bind_int64(stmt, 3, Int64(blob.count))
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw NSError(domain: "agy-stats-test", code: 3) }
        }
    }

    /// Overwrite the blob of an existing row (same idx). Simulates a row that
    /// becomes decodable after a decoder fix — the bytes our parser can read change.
    static func updateBlob(db: URL, idx: Int, blob: Data) throws {
        var dbPtr: OpaquePointer?
        guard sqlite3_open_v2(db.path, &dbPtr, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let handle = dbPtr else { throw NSError(domain: "agy-stats-test", code: 20) }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "UPDATE gen_metadata SET data = ?, size = ? WHERE idx = ?;",
                                 -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "agy-stats-test", code: 21)
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = blob.withUnsafeBytes { buf in
            sqlite3_bind_blob(stmt, 1, buf.baseAddress, Int32(buf.count), transient)
        }
        sqlite3_bind_int64(stmt, 2, Int64(blob.count))
        sqlite3_bind_int64(stmt, 3, Int64(idx))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw NSError(domain: "agy-stats-test", code: 22) }
    }

    /// Open a WAL-mode writer connection on `db` and return the open handle.
    /// The caller MUST keep it open (and `sqlite3_close` it at end of test) so
    /// inserted rows stay in the `-wal` sidecar (no checkpoint migrates them to
    /// the main DB file) — faithfully reproducing Antigravity's live WAL writes.
    static func openWALWriter(db: URL) throws -> OpaquePointer {
        var ptr: OpaquePointer?
        guard sqlite3_open_v2(db.path, &ptr,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let handle = ptr else { throw NSError(domain: "agy-stats-test", code: 10) }
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA wal_autocheckpoint=0;", nil, nil, nil)
        guard sqlite3_exec(handle,
            "CREATE TABLE IF NOT EXISTS gen_metadata (idx INTEGER PRIMARY KEY, data BLOB, size INTEGER NOT NULL DEFAULT 0);",
            nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle); throw NSError(domain: "agy-stats-test", code: 11)
        }
        return handle
    }

    /// Insert `blobs` (idx from `startIdx`) on an open WAL-writer handle, committed
    /// to the WAL but NOT checkpointed.
    static func insertWAL(_ handle: OpaquePointer, blobs: [Data], startIdx: Int) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, blob) in blobs.enumerated() {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "INSERT INTO gen_metadata (idx, data, size) VALUES (?, ?, ?);", -1, &stmt, nil) == SQLITE_OK else {
                throw NSError(domain: "agy-stats-test", code: 12)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(startIdx + offset))
            _ = blob.withUnsafeBytes { buf in
                sqlite3_bind_blob(stmt, 2, buf.baseAddress, Int32(buf.count), transient)
            }
            sqlite3_bind_int64(stmt, 3, Int64(blob.count))
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw NSError(domain: "agy-stats-test", code: 13) }
        }
    }
}
