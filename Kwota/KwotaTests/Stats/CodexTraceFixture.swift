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
        var threadId: String?
        var processUUID: String? = nil
        var body: String
        var target: String = "codex_api::endpoint::responses_websocket"
    }

    struct DumpedRow {
        var threadId: String?
        var processUUID: String?
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
              feedback_log_body TEXT, thread_id TEXT, process_uuid TEXT);
            """, nil, nil, nil)
        sqlite3_exec(h, "DELETE FROM logs;", nil, nil, nil)
        for r in rows {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(h, """
                INSERT INTO logs (id, ts, ts_nanos, level, target, feedback_log_body, thread_id, process_uuid)
                VALUES (?,?,0,'TRACE',?,?,?,?);
                """, -1, &st, nil) == SQLITE_OK, let st else { continue }
            sqlite3_bind_int64(st, 1, r.id)
            sqlite3_bind_int64(st, 2, r.ts)
            sqlite3_bind_text(st, 3, r.target, -1, SQLITE_TRANSIENT_KWOTA)
            sqlite3_bind_text(st, 4, r.body, -1, SQLITE_TRANSIENT_KWOTA)
            bindTextOrNull(st, 5, r.threadId)
            bindTextOrNull(st, 6, r.processUUID)
            sqlite3_step(st)
            sqlite3_finalize(st)
        }
    }

    static func writeLegacyDBWithoutProcessUUID(at url: URL, rows: [Row]) {
        var ptr: OpaquePointer?
        guard sqlite3_open_v2(url.path, &ptr,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let h = ptr else { return }
        defer { sqlite3_close(h) }
        sqlite3_exec(h, "DROP TABLE IF EXISTS logs;", nil, nil, nil)
        sqlite3_exec(h, """
            CREATE TABLE logs (
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
            bindTextOrNull(st, 5, r.threadId)
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

    static func responseCompletedBody(model: String, input: Int, cached: Int, output: Int) -> String {
        #"Received message {"type":"response.completed","response":{"model":""# + model + #"","usage":{"input_tokens":"#
        + "\(input)"
        + #", "input_tokens_details":{"cached_tokens":"#
        + "\(cached)"
        + #"},"output_tokens":"#
        + "\(output)"
        + #", "output_tokens_details":{"reasoning_tokens":0},"total_tokens":"#
        + "\(input + output)"
        + #"}}}"#
    }

    static func postSamplingBody(model: String, total: Int, turnId: String) -> String {
        "post sampling token usage turn_id=\(turnId) model=\(model) total_usage_tokens=\(total)"
    }

    static func dumpRows(home: URL) -> [DumpedRow] {
        let url = home.appendingPathComponent("logs_2.sqlite")
        var ptr: OpaquePointer?
        guard sqlite3_open_v2(url.path, &ptr, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let h = ptr else { return [] }
        defer { sqlite3_close(h) }

        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, "SELECT thread_id, process_uuid FROM logs ORDER BY id;", -1, &st, nil) == SQLITE_OK,
              let st else { return [] }
        defer { sqlite3_finalize(st) }

        var rows: [DumpedRow] = []
        while sqlite3_step(st) == SQLITE_ROW {
            rows.append(DumpedRow(
                threadId: columnText(st, 0),
                processUUID: columnText(st, 1)
            ))
        }
        return rows
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

    private static func bindTextOrNull(_ st: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(st, index, value, -1, SQLITE_TRANSIENT_KWOTA)
        } else {
            sqlite3_bind_null(st, index)
        }
    }

    private static func columnText(_ st: OpaquePointer, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(st, index) else { return nil }
        return String(cString: text)
    }
}
