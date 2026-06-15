//  CodexTraceReader.swift
//  Kwota
//
//  A `JSONLogReader` that sources Codex *ephemeral plugin-review* token usage
//  from codex's internal trace DB `~/.codex/logs_*.sqlite`. Plugin reviews
//  (`/codex:review`, `/codex:adversarial-review`) run as ephemeral app-server
//  threads and leave NO rollout JSONL, so `CodexStatsReader` can't see them —
//  but codex logs the OpenAI responses-API `usage` object for every turn to the
//  `logs` table, target `codex_api::endpoint::responses_websocket`. The cursor
//  is a per-DB high-water rowid (`id`) in `ReaderState.Entry.offset`; only rows
//  with a greater id are emitted, so a turn is never double-counted.
//
//  Threads that DO produce a rollout (interactive codex / TUI) are already
//  counted by `CodexStatsReader`, so their rows are excluded here.
//
//  DBs are opened read-only with the `unix-none` VFS (same as
//  `AntigravityStatsReader`) so we never contend with codex's live WAL writes;
//  un-checkpointed rows surface on a later poll. `@unchecked Sendable`:
//  `offsets`/`mtimes` are mutated only inside `read()`, which `StatsStore`
//  serializes. `lastLine` is lock-guarded.

import Foundation
import SQLite3
import os

final class CodexTraceReader: JSONLogReader, @unchecked Sendable {
    private let codexHome: URL
    private let sessionsRoot: URL
    private let fm: FileManager
    private var offsets: [URL: UInt64] = [:]   // high-water rowid consumed per logs DB
    private var mtimes: [URL: Date] = [:]
    private let lastLineLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Trace target that carries the responses-API `usage` dump.
    private static let usageTarget = "codex_api::endpoint::responses_websocket"

    init(codexHome: URL = CodexTraceReader.defaultHome(), fileManager: FileManager = .default) {
        self.codexHome = codexHome
        self.sessionsRoot = codexHome.appendingPathComponent("sessions")
        self.fm = fileManager
    }

    static func defaultHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    func lastSeenLine() -> String? { lastLineLock.withLock { $0 } }

    func read() -> [UsageEvent] {
        let dbs = discoverDBs()
        let live = Set(dbs)
        offsets = offsets.filter { live.contains($0.key) }
        mtimes = mtimes.filter { live.contains($0.key) }
        guard !dbs.isEmpty else { return [] }
        let rollout = rolloutThreadIDs()
        var emitted: [UsageEvent] = []
        for db in dbs { readOne(db, excluding: rollout, into: &emitted) }
        return emitted
    }

    func read(only paths: Set<URL>) -> [UsageEvent] {
        let prefix = Self.canonicalize(codexHome).path + "/"
        let dbs = paths.compactMap { url -> URL? in
            let n = Self.canonicalize(url)
            guard n.path.hasPrefix(prefix) else { return nil }
            let name = n.lastPathComponent
            guard name.hasPrefix("logs_"), name.hasSuffix(".sqlite") else { return nil }
            return n
        }
        guard !dbs.isEmpty else { return [] }
        let rollout = rolloutThreadIDs()
        var emitted: [UsageEvent] = []
        for db in dbs { readOne(db, excluding: rollout, into: &emitted) }
        return emitted
    }

    private static func canonicalize(_ url: URL) -> URL {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(url.path, &buf) != nil { return URL(fileURLWithPath: String(cString: buf)) }
        return url
    }

    private func discoverDBs() -> [URL] {
        guard let items = try? fm.contentsOfDirectory(
            at: codexHome, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return [] }
        return items.filter { $0.lastPathComponent.hasPrefix("logs_") && $0.pathExtension == "sqlite" }
    }

    /// UUIDs of threads that produced a rollout (already counted by
    /// `CodexStatsReader`). Filenames only — no content read.
    private func rolloutThreadIDs() -> Set<String> {
        guard let en = fm.enumerator(at: sessionsRoot, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else { return [] }
        var out = Set<String>()
        for case let url as URL in en
        where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
            if let uuid = Self.trailingUUID(url.deletingPathExtension().lastPathComponent) {
                out.insert(uuid)
            }
        }
        return out
    }

    /// Thread ID embedded in a rollout filename stem shaped
    /// `rollout-YYYY-MM-DDTHH-MM-SS-<threadId>`. The date portion contributes
    /// exactly 6 dash-joined components after splitting, so the thread ID is
    /// everything from index 6 onward re-joined with `-`. Codex normally uses
    /// an RFC-4122 UUID here; tests may use simpler strings.
    static func trailingUUID(_ stem: String) -> String? {
        let parts = stem.split(separator: "-")
        // Minimum: "rollout" + 5 date components + at least 1 id component = 7.
        guard parts.count >= 7 else { return nil }
        let id = parts.dropFirst(6).joined(separator: "-")
        return id.isEmpty ? nil : id
    }

    private func readOne(_ db: URL, excluding rollout: Set<String>, into emitted: inout [UsageEvent]) {
        if let m = (try? fm.attributesOfItem(atPath: db.path))?[.modificationDate] as? Date {
            mtimes[db] = m
        }
        guard let handle = openReadOnly(db) else { return }   // soft-degrade: keep cursor, skip
        defer { sqlite3_close(handle) }

        guard let currentMax = maxRowID(handle) else { return }   // empty table
        var lower = offsets[db] ?? 0
        if currentMax < lower { lower = 0 }        // rotation/replace -> re-read from scratch
        if let stored = offsets[db], stored == currentMax, currentMax >= lower {
            return   // up to date, no new rows
        }

        let sql = """
            SELECT id, ts, thread_id, feedback_log_body FROM logs
            WHERE id > \(lower) AND id <= \(currentMax)
              AND target = '\(Self.usageTarget)'
              AND feedback_log_body LIKE '%"usage":{"input_tokens"%'
            ORDER BY id ASC;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = UInt64(bitPattern: sqlite3_column_int64(stmt, 0))
            let ts = sqlite3_column_int64(stmt, 1)
            guard let tidC = sqlite3_column_text(stmt, 2) else { continue }
            let threadId = String(cString: tidC)
            guard !rollout.contains(threadId) else { continue }
            guard let bodyC = sqlite3_column_text(stmt, 3) else { continue }
            let body = String(cString: bodyC)
            lastLineLock.withLock { $0 = "\(threadId)@\(id)" }
            guard let tokens = Self.parseUsage(body), tokens != .zero else { continue }
            emitted.append(UsageEvent(
                uuid: "\(threadId)@\(id)", sessionId: threadId,
                timestamp: Date(timeIntervalSince1970: TimeInterval(ts)),
                tokens: tokens, model: Self.parseModel(body)))
        }
        offsets[db] = currentMax   // advance past ALL scanned rows, not just usage rows
    }

    /// Extract `"usage":{...}` (responses-API shape) from a row body and map it
    /// to a `TokenBreakdown`. `input` is the non-cached input; `cacheRead` the
    /// cached input. Returns nil if the object is absent or malformed.
    static func parseUsage(_ body: String) -> TokenBreakdown? {
        guard let key = body.range(of: "\"usage\":") else { return nil }
        let after = body[key.upperBound...]
        guard let open = after.firstIndex(of: "{") else { return nil }
        var depth = 0
        var end: String.Index?
        var i = open
        while i < after.endIndex {
            switch after[i] {
            case "{": depth += 1
            case "}": depth -= 1; if depth == 0 { end = after.index(after: i) }
            default: break
            }
            if end != nil { break }
            i = after.index(after: i)
        }
        guard let end,
              let data = String(after[open..<end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let input = (obj["input_tokens"] as? Int) ?? 0
        let output = (obj["output_tokens"] as? Int) ?? 0
        let cached = ((obj["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int) ?? 0
        return TokenBreakdown(input: max(0, input - cached), output: output,
                              cacheCreation: 0, cacheRead: cached)
    }

    /// First `model=<token>` span attribute in the body; token ends at whitespace.
    static func parseModel(_ body: String) -> String? {
        guard let r = body.range(of: "model=") else { return nil }
        let tok = body[r.upperBound...].prefix { !$0.isWhitespace }
        return tok.isEmpty ? nil : String(tok)
    }

    private func maxRowID(_ handle: OpaquePointer) -> UInt64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT max(id) FROM logs;", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL
        else { return nil }
        return UInt64(bitPattern: sqlite3_column_int64(stmt, 0))
    }

    private func openReadOnly(_ db: URL) -> OpaquePointer? {
        guard fm.fileExists(atPath: db.path) else { return nil }
        var ptr: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(db.path, &ptr, flags, "unix-none") == SQLITE_OK, let ptr else {
            if let ptr { sqlite3_close(ptr) }
            AppLog.shared.log("CodexTraceReader open failed: \(db.lastPathComponent)", level: .warn)
            return nil
        }
        return ptr
    }

    func state() -> ReaderState {
        var snapshot: [String: ReaderState.Entry] = [:]
        for (url, id) in offsets {
            snapshot[url.path] = .init(offset: id, mtime: mtimes[url] ?? .distantPast)
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
