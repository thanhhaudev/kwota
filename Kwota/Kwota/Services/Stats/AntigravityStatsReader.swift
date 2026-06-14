//  AntigravityStatsReader.swift
//  Kwota
//
//  A `JSONLogReader` that sources per-turn token usage from Antigravity's
//  conversation SQLite DBs (`gen_metadata` table) instead of JSONL. The cursor
//  is a per-DB high-water `idx` stored in `ReaderState.Entry.offset`; only rows
//  with `idx` greater than the high-water are emitted, so a turn is never
//  double-counted. DBs are opened read-only with the `unix-none` VFS so we never
//  block Antigravity's live WAL writes (recent un-checkpointed rows simply
//  surface on the next read — the watcher's poll backstop covers the lag).
//
//  `@unchecked Sendable`: `offsets`/`mtimes` are mutated only inside `read()`,
//  which `StatsStore` serializes (never two reads in flight). `lastLine` is
//  lock-guarded.

import Foundation
import SQLite3
import os

final class AntigravityStatsReader: JSONLogReader, @unchecked Sendable {
    private let roots: [URL]
    private let fm: FileManager
    private let clock: () -> Date
    private var offsets: [URL: UInt64] = [:]   // high-water idx consumed per DB
    private var mtimes: [URL: Date] = [:]
    private let lastLineLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    init(roots: [URL] = AppPaths.antigravityConversationDirs,
         fileManager: FileManager = .default,
         clock: @escaping () -> Date = { Date() }) {
        self.roots = roots
        self.fm = fileManager
        self.clock = clock
    }

    func lastSeenLine() -> String? { lastLineLock.withLock { $0 } }

    func read() -> [UsageEvent] {
        var emitted: [UsageEvent] = []
        let dbs = discoverDBs()
        // Prune cursors for vanished DBs on the full walk so `state()` stays a
        // syscall-free in-memory snapshot (matches the Claude/Codex contract).
        let live = Set(dbs)
        offsets = offsets.filter { live.contains($0.key) }
        mtimes = mtimes.filter { live.contains($0.key) }
        for db in dbs { readOne(db, into: &emitted) }
        return emitted
    }

    private func discoverDBs() -> [URL] {
        var out: [URL] = []
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { continue }
            for url in items where url.pathExtension == "db" { out.append(url) }
        }
        return out
    }

    private func readOne(_ db: URL, into emitted: inout [UsageEvent]) {
        let attrs = (try? fm.attributesOfItem(atPath: db.path)) ?? [:]
        let mtime = attrs[.modificationDate] as? Date
        // mtime gate: skip an unchanged DB we've already consumed (no sqlite open).
        if let known = mtimes[db], let mtime, known == mtime, offsets[db] != nil { return }
        if let mtime { mtimes[db] = mtime }

        guard let handle = openReadOnly(db) else { return }   // soft-degrade: keep cursor, skip
        defer { sqlite3_close(handle) }

        let stored = offsets[db]
        // Rotation: if the table shrank below our high-water (conversation reset
        // reusing the same file), reset and re-read from scratch.
        var highWater = stored
        // `idx` is a monotonic PRIMARY KEY, so a genuine shrink is the only
        // rotation we can detect; a reset that reuses idx without net-shrinking
        // is (acceptably) not caught — same append-only assumption as the JSONL readers.
        if let stored, let maxIdx = maxIdx(handle), maxIdx < stored { highWater = nil }

        let sql: String
        if let highWater {
            sql = "SELECT idx, data FROM gen_metadata WHERE idx > \(highWater) ORDER BY idx ASC;"
        } else {
            sql = "SELECT idx, data FROM gen_metadata ORDER BY idx ASC;"
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }

        let sessionId = db.deletingPathExtension().lastPathComponent
        var lastTS: Date?
        var maxSeen = highWater
        var rowsExamined = 0
        var rowsDecoded = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idx = UInt64(bitPattern: sqlite3_column_int64(stmt, 0))
            maxSeen = max(maxSeen ?? 0, idx)
            guard let raw = sqlite3_column_blob(stmt, 1) else { continue }
            let n = Int(sqlite3_column_bytes(stmt, 1))
            guard n > 0 else { continue }
            let blob = Data(bytes: raw, count: n)
            lastLineLock.withLock { $0 = "\(sessionId)#\(idx)" }
            rowsExamined += 1
            guard let usage = decodeAntigravityGenMetadata(blob), usage.tokens != .zero else { continue }
            rowsDecoded += 1
            // Timestamp fallback chain: row ts → previous valid row ts → DB mtime → now.
            let ts = usage.timestamp ?? lastTS ?? mtime ?? clock()
            if usage.timestamp != nil { lastTS = usage.timestamp }
            emitted.append(UsageEvent(uuid: "\(sessionId)#\(idx)", sessionId: sessionId,
                                      timestamp: ts, tokens: usage.tokens, model: usage.model))
        }
        // Whole-batch decode failure is the drift signal: a single torn row is a
        // normal soft-degrade (skipped per-row), but if every new row in this DB
        // decoded to nothing, the reverse-engineered proto field-map likely moved.
        if rowsExamined > 0, rowsDecoded == 0 {
            AppLog.shared.log(
                "AntigravityStatsReader: \(rowsExamined) row(s) in \(db.lastPathComponent) decoded to nothing — gen_metadata proto field-map may have drifted",
                level: .warn)
        }
        if let maxSeen { offsets[db] = maxSeen }
    }

    private func maxIdx(_ handle: OpaquePointer) -> UInt64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT max(idx) FROM gen_metadata;", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return UInt64(bitPattern: sqlite3_column_int64(stmt, 0))
    }

    /// Open read-only with no locking (`unix-none` VFS) so we never contend with
    /// Antigravity's live writes. Same pattern as `AntigravityOverageReader`.
    private func openReadOnly(_ db: URL) -> OpaquePointer? {
        guard fm.fileExists(atPath: db.path) else { return nil }
        var ptr: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(db.path, &ptr, flags, "unix-none") == SQLITE_OK, let ptr else {
            if let ptr { sqlite3_close(ptr) }
            AppLog.shared.log("AntigravityStatsReader open failed: \(db.lastPathComponent)", level: .warn)
            return nil
        }
        return ptr
    }

    func state() -> ReaderState {
        // Syscall-free in-memory snapshot; dead cursors pruned on the next read().
        var snapshot: [String: ReaderState.Entry] = [:]
        for (url, idx) in offsets {
            snapshot[url.path] = .init(offset: idx, mtime: mtimes[url] ?? .distantPast)
        }
        return ReaderState(entries: snapshot)
    }

    func restore(_ state: ReaderState) {
        offsets.removeAll(keepingCapacity: false)
        mtimes.removeAll(keepingCapacity: false)
        for (path, entry) in state.entries {
            let url = URL(fileURLWithPath: path)
            offsets[url] = entry.offset
            mtimes[url] = entry.mtime
        }
    }
}
