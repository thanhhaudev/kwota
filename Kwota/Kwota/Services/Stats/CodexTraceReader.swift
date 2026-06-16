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

/// Minimal seam so tests can inject a spy without subclassing `FileManager`
/// (the URL-based `enumerator` overload is `@nonobjc` and can't be overridden).
protocol CodexFileManager: AnyObject {
    func contentsOfDirectory(at url: URL,
                             includingPropertiesForKeys keys: [URLResourceKey]?,
                             options mask: FileManager.DirectoryEnumerationOptions) throws -> [URL]
    func enumerator(at url: URL,
                    includingPropertiesForKeys keys: [URLResourceKey]?,
                    options mask: FileManager.DirectoryEnumerationOptions,
                    errorHandler handler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator?
    func fileExists(atPath path: String) -> Bool
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any]
}

extension FileManager: CodexFileManager {}

final class CodexTraceReader: JSONLogReader, @unchecked Sendable {
    private let codexHome: URL
    private let sessionsRoot: URL
    private let fm: any CodexFileManager
    private var offsets: [URL: UInt64] = [:]   // high-water rowid consumed per logs DB
    private var mtimes: [URL: Date] = [:]
    private let lastLineLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Trace target that carries the responses-API `usage` dump.
    private static let usageTarget = "codex_api::endpoint::responses_websocket"

    init(codexHome: URL = CodexTraceReader.defaultHome(), fileManager: any CodexFileManager = FileManager.default) {
        self.codexHome = codexHome
        self.sessionsRoot = codexHome.appendingPathComponent("sessions")
        self.fm = fileManager
    }

    static func defaultHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    func lastSeenLine() -> String? { lastLineLock.withLock { $0 } }

    func read() -> [UsageEvent] {
        guard let dbs = discoverDBs() else { return [] }   // discovery error → keep offsets, skip
        let live = Set(dbs)
        offsets = offsets.filter { live.contains($0.key) }
        mtimes = mtimes.filter { live.contains($0.key) }
        return ingest(dbs)
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
        return ingest(dbs)
    }

    /// Shared read path. For each DB, probe whether it has a NEW USAGE row above
    /// the cursor. DBs whose only new rows are unrelated trace noise get their
    /// cursor advanced WITHOUT walking the sessions tree. The rollout-exclusion
    /// set (a recursive sessions walk) is built only when at least one DB has new
    /// usage; if it's untrusted, skip without advancing.
    private func ingest(_ dbs: [URL]) -> [UsageEvent] {
        guard !dbs.isEmpty else { return [] }
        var fresh: [URL] = []
        for db in dbs {
            switch probe(db) {
            case .none: continue                          // empty/unreadable or no new rows
            case .some((let hasUsage, let maxId)):
                if hasUsage { fresh.append(db) }
                else { offsets[db] = maxId }              // advance past noise, no sessions walk
            }
        }
        guard !fresh.isEmpty else { return [] }
        guard let rollout = rolloutThreadIDs() else { return [] }   // untrusted → skip
        var emitted: [UsageEvent] = []
        for db in fresh { readOne(db, excluding: rollout, into: &emitted) }
        return emitted
    }

    /// Cheap per-DB probe: `(hasNewUsage, maxRowId)`, or nil when the DB is
    /// empty/unreadable or has no rows beyond the cursor. A shrink (rotation) is
    /// reported as hasUsage so `readOne` re-reads from scratch.
    private func probe(_ db: URL) -> (hasUsage: Bool, maxId: UInt64)? {
        guard let handle = openReadOnly(db) else { return nil }
        defer { sqlite3_close(handle) }
        guard let currentMax = maxRowID(handle) else { return nil }   // empty table
        let lower = offsets[db] ?? 0
        if currentMax == lower { return nil }            // no new rows
        if currentMax < lower { return (true, currentMax) }   // rotation → force re-read
        return (existsUsageRow(handle, above: lower) ?? true, currentMax)
    }

    /// Whether any new row (id > lower) under the usage target carries token
    /// usage. Returns nil on a query error so the caller fails CLOSED (never
    /// advances past possibly-usage rows). Uses a format-independent
    /// `input_tokens` substring; `parseUsage` (in readOne) is the authority on
    /// the exact shape, so whitespace/key-order variations aren't dropped here.
    private func existsUsageRow(_ handle: OpaquePointer, above lower: UInt64) -> Bool? {
        let sql = """
            SELECT 1 FROM logs
            WHERE id > \(lower) AND target = '\(Self.usageTarget)'
              AND feedback_log_body LIKE '%input_tokens%'
            LIMIT 1;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func canonicalize(_ url: URL) -> URL {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(url.path, &buf) != nil { return URL(fileURLWithPath: String(cString: buf)) }
        return url
    }

    /// Returns nil when the codex home can't be listed (transient error) so the
    /// caller keeps its cursors and retries — returning [] there would prune all
    /// offsets and re-ingest every DB on the next successful poll (double-count).
    /// An empty array means the dir was listed and genuinely has no logs DBs.
    private func discoverDBs() -> [URL]? {
        guard let items = try? fm.contentsOfDirectory(
            at: codexHome, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return nil }
        return items.filter { $0.lastPathComponent.hasPrefix("logs_") && $0.pathExtension == "sqlite" }
    }

    /// Returns nil when the set can't be trusted, so the caller skips rather than
    /// fail-OPEN double-counting rollout-backed threads. Untrusted = the sessions
    /// dir exists but the enumerator can't start, OR ANY error occurs mid-walk
    /// (e.g. a descendant deleted during enumeration → partial set). A missing
    /// sessions dir is a trusted empty set (no rollouts exist) and is NOT walked.
    private func rolloutThreadIDs() -> Set<String>? {
        guard fm.fileExists(atPath: sessionsRoot.path) else { return [] }
        var traversalFailed = false
        guard let en = fm.enumerator(at: sessionsRoot, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles],
                                     errorHandler: { _, _ in traversalFailed = true; return true }) else { return nil }
        var out = Set<String>()
        for case let url as URL in en
        where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
            if let uuid = Self.trailingUUID(url.deletingPathExtension().lastPathComponent) {
                out.insert(uuid)
            }
        }
        return traversalFailed ? nil : out
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
              AND feedback_log_body LIKE '%input_tokens%'
            ORDER BY id ASC;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }

        var parsedOK = 0     // rows whose usage object decoded (billable OR zero) — schema intact
        var parseFailed = 0  // rows that matched the filter but whose usage object would not decode
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = UInt64(bitPattern: sqlite3_column_int64(stmt, 0))
            let ts = sqlite3_column_int64(stmt, 1)
            guard let tidC = sqlite3_column_text(stmt, 2) else { continue }
            let threadId = String(cString: tidC)
            guard !rollout.contains(threadId) else { continue }
            guard let bodyC = sqlite3_column_text(stmt, 3) else { continue }
            let body = String(cString: bodyC)
            lastLineLock.withLock { $0 = "\(threadId)@\(id)" }
            guard let tokens = Self.parseUsage(body) else { parseFailed += 1; continue }
            parsedOK += 1
            guard tokens != .zero else { continue }   // decoded but non-billable
            emitted.append(UsageEvent(
                uuid: "\(threadId)@\(id)", sessionId: threadId,
                timestamp: Date(timeIntervalSince1970: TimeInterval(ts)),
                tokens: tokens, model: Self.parseModel(body)))
        }
        // Whole-batch parse FAILURE is the drift signal: if every filter-matched
        // usage row in this batch failed to parse, the responses-API usage shape
        // likely moved — hold the cursor so the rows are re-read after a decoder fix
        // rather than silently lost. A lone failure among parseable rows advances
        // normally: the `%input_tokens%` LIKE filter can substring-match non-usage
        // rows, so per-row fail-closed would be a permanent re-scan poison pill.
        // (Unlike the Antigravity reader — whose proto rows can't false-positive —
        // this reader intentionally does NOT defer-retry individual rows.)
        if parseFailed > 0, parsedOK == 0 {
            AppLog.shared.log(
                "CodexTraceReader: \(parseFailed) usage row(s) in \(db.lastPathComponent) matched but failed to parse — responses-API usage shape may have drifted; not advancing cursor",
                level: .warn)
            return
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
