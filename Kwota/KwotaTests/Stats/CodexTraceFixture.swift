//  CodexTraceFixture.swift
//  KwotaTests

import Foundation
import SQLite3
@testable import Kwota

/// SQLITE_TRANSIENT tells SQLite to copy the bound bytes (the Swift String is
/// transient). Swift can't see the C macro, so redeclare it.
private let SQLITE_TRANSIENT_KWOTA = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Builds a throwaway `~/.codex` directory containing a `logs_<gen>.sqlite`
/// shaped like codex's real trace DB, plus optional rollout files, so
/// `CodexTraceReader` can be exercised hermetically (no real-home reads).
enum CodexTraceFixture {
    struct Row {
        var id: Int64
        var ts: Int64
        var threadId: String
        var body: String
        var target: String = "codex_api::endpoint::responses_websocket"
    }

    /// Create a temp codex home with one `logs_<gen>.sqlite` holding `rows`.
    @discardableResult
    static func makeHome(gen: Int = 2, rows: [Row]) -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-trace-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        writeDB(at: home.appendingPathComponent("logs_\(gen).sqlite"), rows: rows)
        return home
    }

    /// (Re)write a `logs_*.sqlite` at `url` with exactly `rows`.
    static func writeDB(at url: URL, rows: [Row]) {
        var ptr: OpaquePointer?
        guard sqlite3_open_v2(url.path, &ptr,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let h = ptr else { return }
        defer { sqlite3_close(h) }
        sqlite3_exec(h, """
            CREATE TABLE IF NOT EXISTS logs (
              id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, ts_nanos INTEGER NOT NULL DEFAULT 0,
              level TEXT NOT NULL DEFAULT 'TRACE', target TEXT NOT NULL,
              feedback_log_body TEXT, thread_id TEXT);
            """, nil, nil, nil)
        for r in rows {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(h, """
                INSERT INTO logs (id, ts, ts_nanos, level, target, feedback_log_body, thread_id)
                VALUES (?,?,0,'TRACE',?,?,?);
                """, -1, &st, nil) == SQLITE_OK, let st else { continue }
            sqlite3_bind_int64(st, 1, r.id)
            sqlite3_bind_int64(st, 2, r.ts)
            sqlite3_bind_text(st, 3, r.target, -1, SQLITE_TRANSIENT_KWOTA)
            sqlite3_bind_text(st, 4, r.body, -1, SQLITE_TRANSIENT_KWOTA)
            sqlite3_bind_text(st, 5, r.threadId, -1, SQLITE_TRANSIENT_KWOTA)
            sqlite3_step(st)
            sqlite3_finalize(st)
        }
    }

    /// A row body shaped like a real `responses_websocket` trace line: a span
    /// prefix carrying `model=<m>` followed by the responses-API `usage` JSON.
    static func usageBody(model: String, input: Int, cached: Int, output: Int) -> String {
        "turn{thread.id=x model=\(model) codex.turn.reasoning_effort=medium}:run: "
        + "\"usage\":{\"input_tokens\":\(input),"
        + "\"input_tokens_details\":{\"cached_tokens\":\(cached)},"
        + "\"output_tokens\":\(output),"
        + "\"output_tokens_details\":{\"reasoning_tokens\":0},"
        + "\"total_tokens\":\(input + output)}"
    }

    /// Drop a rollout file for `threadId` so the reader's rollout-thread scan
    /// sees it (filename only; content is irrelevant).
    static func addRollout(home: URL, threadId: String, day: String = "2026/06/15") {
        let dir = home.appendingPathComponent("sessions/\(day)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("rollout-2026-06-15T10-00-00-\(threadId).jsonl")
        try? Data("{}\n".utf8).write(to: f)
    }

    static func cleanup(_ home: URL) { try? FileManager.default.removeItem(at: home) }
}
