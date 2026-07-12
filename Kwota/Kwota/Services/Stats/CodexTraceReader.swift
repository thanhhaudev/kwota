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
    private var traceTurns: [URL: [String: ReaderState.CodexTraceTurn]] = [:]
    private let lastLineLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Trace target that carries the responses-API `usage` dump.
    private static let usageTarget = "codex_api::endpoint::responses_websocket"
    private static let logTarget = "log"
    private static let turnTarget = "codex_core::session::turn"

    private struct TraceRow {
        var id: UInt64
        var ts: Int64
        var target: String
        var threadId: String?
        var processUUID: String?
        var body: String

        var isExactUsageCandidate: Bool {
            switch target {
            case CodexTraceReader.usageTarget:
                return body.contains("input_tokens")
            case CodexTraceReader.logTarget:
                return body.contains("response.completed") && body.contains(#""usage""#)
            default:
                return false
            }
        }
    }

    private struct TraceObservation {
        var key: String
        var sessionId: String
        var timestamp: Date
        var model: String?
        var tokens: TokenBreakdown
        var precision: ReaderState.CodexTracePrecision
    }

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
        traceTurns = traceTurns.filter { live.contains($0.key) }
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
            WHERE id > \(lower)
              AND (
                (target = '\(Self.usageTarget)' AND feedback_log_body LIKE '%input_tokens%')
                OR (target = '\(Self.logTarget)' AND feedback_log_body LIKE '%response.completed%' AND feedback_log_body LIKE '%"usage"%')
                OR (target = '\(Self.turnTarget)' AND feedback_log_body LIKE '%post sampling token usage%')
              )
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
        if currentMax < lower {
            lower = 0        // rotation/replace -> re-read from scratch
            traceTurns[db] = [:]
        }
        if let stored = offsets[db], stored == currentMax, currentMax >= lower {
            return   // up to date, no new rows
        }

        let contextLower = lower > 25 ? lower - 25 : 0
        let hasProcessUUID = hasColumn("process_uuid", in: "logs", handle: handle)
        let processUUIDSelect = hasProcessUUID ? "process_uuid" : "NULL AS process_uuid"
        let contextFilter = hasProcessUUID
            ? "OR (id > \(contextLower) AND target = '\(Self.turnTarget)' AND process_uuid IS NOT NULL AND thread_id IS NOT NULL)"
            : ""
        let sql = """
            SELECT id, ts, target, thread_id, \(processUUIDSelect), feedback_log_body FROM logs
            WHERE id <= \(currentMax)
              AND (
                (id > \(lower) AND target = '\(Self.usageTarget)' AND feedback_log_body LIKE '%input_tokens%')
                OR (id > \(lower) AND target = '\(Self.logTarget)' AND feedback_log_body LIKE '%response.completed%' AND feedback_log_body LIKE '%"usage"%')
                OR (id > \(lower) AND target = '\(Self.turnTarget)' AND feedback_log_body LIKE '%post sampling token usage%')
                \(contextFilter)
              )
            ORDER BY id ASC;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }

        var rows: [TraceRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let targetC = sqlite3_column_text(stmt, 2),
                  let bodyC = sqlite3_column_text(stmt, 5) else { continue }
            rows.append(TraceRow(
                id: UInt64(bitPattern: sqlite3_column_int64(stmt, 0)),
                ts: sqlite3_column_int64(stmt, 1),
                target: String(cString: targetC),
                threadId: Self.columnText(stmt, 3),
                processUUID: Self.columnText(stmt, 4),
                body: String(cString: bodyC)
            ))
        }

        var observations: [TraceObservation] = []
        var parsedOK = 0     // rows whose usage object decoded (billable OR zero) — schema intact
        var parseFailed = 0  // rows that matched the filter but whose usage object would not decode
        for row in rows where row.id > lower && row.isExactUsageCandidate {
            guard let tokens = Self.parseUsage(row.body) else { parseFailed += 1; continue }
            parsedOK += 1
            guard tokens != .zero else { continue }   // decoded but non-billable
            guard let observation = Self.exactObservation(from: row, tokens: tokens, rows: rows) else { continue }
            guard !rollout.contains(observation.sessionId) else { continue }
            observations.append(observation)
        }
        var fallbackByTurn: [String: TraceObservation] = [:]
        for row in rows where row.id > lower && row.target == Self.turnTarget {
            guard let parsed = Self.parsePostSampling(row.body),
                  let threadId = row.threadId,
                  !rollout.contains(threadId) else { continue }
            let key = "\(threadId)#\(parsed.turnId)"
            let obs = TraceObservation(
                key: key,
                sessionId: threadId,
                timestamp: Date(timeIntervalSince1970: TimeInterval(row.ts)),
                model: parsed.model,
                tokens: TokenBreakdown(totalOnly: parsed.total),
                precision: .totalOnly
            )
            if let current = fallbackByTurn[key] {
                if obs.tokens.totalOnly > current.tokens.totalOnly { fallbackByTurn[key] = obs }
            } else {
                fallbackByTurn[key] = obs
            }
        }
        let exactKeys = Set(observations.filter { $0.precision == .exact }.map(\.key))
        observations.append(contentsOf: fallbackByTurn.values.filter { !exactKeys.contains($0.key) })
        reconcile(observations.sorted(by: { $0.key < $1.key }), db: db, into: &emitted)
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

    private static func exactObservation(from row: TraceRow, tokens: TokenBreakdown, rows: [TraceRow]) -> TraceObservation? {
        guard row.isExactUsageCandidate else { return nil }
        guard let threadId = row.threadId ?? correlateThreadID(for: row, rows: rows) else { return nil }
        let key: String
        if let turnId = correlateTurnID(for: row, rows: rows) {
            key = "\(threadId)#\(turnId)"
        } else {
            key = "\(threadId)#exact#\(row.id)"
        }
        return TraceObservation(
            key: key,
            sessionId: threadId,
            timestamp: Date(timeIntervalSince1970: TimeInterval(row.ts)),
            model: parseModel(row.body),
            tokens: tokens,
            precision: .exact
        )
    }

    private static func correlateThreadID(for row: TraceRow, rows: [TraceRow]) -> String? {
        guard let pid = row.processUUID else { return nil }
        let candidates = rows.filter {
            $0.processUUID == pid &&
            $0.target == Self.turnTarget &&
            $0.threadId != nil &&
            abs(Int64($0.id) - Int64(row.id)) <= 25
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0].threadId
    }

    private static func correlateTurnID(for row: TraceRow, rows: [TraceRow]) -> String? {
        guard let pid = row.processUUID else { return nil }
        let candidates = rows.compactMap { candidate -> String? in
            guard candidate.processUUID == pid,
                  candidate.target == Self.turnTarget,
                  abs(Int64(candidate.id) - Int64(row.id)) <= 25 else { return nil }
            if let parsed = parsePostSampling(candidate.body) { return parsed.turnId }
            return parseToken(after: "turn_id=", in: candidate.body) ?? parseToken(after: "turn=", in: candidate.body)
        }
        let unique = Set(candidates)
        guard unique.count == 1 else { return nil }
        return unique.first
    }

    private func reconcile(_ observations: [TraceObservation], db: URL, into emitted: inout [UsageEvent]) {
        var state = traceTurns[db] ?? [:]
        for obs in observations {
            let previous = state[obs.key]
            switch (previous?.precision, obs.precision) {
            case (.exact, _):
                continue
            case (_, .totalOnly):
                // `total_usage_tokens` is `active_context_tokens` — the size of
                // the whole context, which is CUMULATIVE across a thread's turns.
                // Book only what this observation adds beyond what the thread has
                // already been credited with; booking the raw figure per turn
                // would re-count every earlier turn's context. (For the
                // single-turn threads the plugin actually produces, the baseline
                // is 0 and this reduces to the raw figure.)
                let baseline = Self.credited(thread: obs.sessionId, in: state)
                let delta = obs.tokens.totalOnly - baseline
                // Not growth: a re-read of an unchanged turn, or a compaction
                // that shrank the window. Nothing new was consumed.
                guard delta > 0 else { continue }
                emitted.append(Self.event(from: obs, tokens: TokenBreakdown(totalOnly: delta)))
                // Store what the turn has been CREDITED, not the raw context, so
                // the thread baseline stays a running sum and a later retraction
                // gives back exactly what was booked.
                let creditedForTurn = (previous?.tokens.totalOnly ?? 0) + delta
                state[obs.key] = ReaderState.CodexTraceTurn(
                    precision: .totalOnly, timestamp: obs.timestamp, model: obs.model,
                    tokens: TokenBreakdown(totalOnly: creditedForTurn))
                lastLineLock.withLock { $0 = "\(obs.sessionId)@\(obs.key)" }
            case (.totalOnly, .exact):
                if let previous {
                    // Retract the estimate in the bucket it was BOOKED IN, not
                    // the one the exact row happened to be read in. The two can
                    // differ (the turn straddles an hour/day boundary, or the
                    // exact row lands on a later poll); crediting the retraction
                    // to `obs.timestamp` would leave the original hour/day
                    // holding a positive total-only balance — a phantom
                    // "Headless (est.)" bar for a turn now counted as billable.
                    emitted.append(Self.event(
                        from: obs,
                        tokens: TokenBreakdown(totalOnly: -previous.tokens.totalOnly),
                        at: previous.timestamp,
                        model: previous.model))
                }
                emitted.append(Self.event(from: obs, tokens: obs.tokens))
                state[obs.key] = ReaderState.CodexTraceTurn(
                    precision: .exact, timestamp: obs.timestamp, model: obs.model, tokens: obs.tokens)
                lastLineLock.withLock { $0 = "\(obs.sessionId)@\(obs.key)" }
            case (.none, .exact):
                emitted.append(Self.event(from: obs, tokens: obs.tokens))
                state[obs.key] = ReaderState.CodexTraceTurn(
                    precision: .exact, timestamp: obs.timestamp, model: obs.model, tokens: obs.tokens)
                lastLineLock.withLock { $0 = "\(obs.sessionId)@\(obs.key)" }
            }
        }
        traceTurns[db] = state
    }

    /// Tokens already credited to `thread` across every turn we've booked for it.
    ///
    /// This is the baseline a cumulative `active_context_tokens` reading is
    /// measured against, so it must count everything already attributed to the
    /// thread's context — including its EXACT turns: `billable`
    /// (`(input − cached) + output`) is the content newly added to the
    /// conversation, the same quantity a context reading grows by. Leaving exact
    /// turns out would let a later total-only turn re-book their content.
    private static func credited(thread: String,
                                 in state: [String: ReaderState.CodexTraceTurn]) -> Int {
        state.reduce(0) { sum, entry in
            guard Self.threadID(ofKey: entry.key) == thread else { return sum }
            return sum + entry.value.tokens.totalOnly + entry.value.tokens.billable
        }
    }

    /// Observation keys are `<threadId>#<turnId>` (exact rows that can't be
    /// correlated to a turn fall back to `<threadId>#exact#<rowId>`), so the
    /// thread is always the segment before the first `#`.
    private static func threadID(ofKey key: String) -> Substring {
        key.prefix { $0 != "#" }
    }

    /// `at`/`model` override the observation's own stamp — used by the
    /// total-only retraction, which must be booked against the ORIGINAL
    /// observation's bucket, not the exact row's.
    private static func event(from obs: TraceObservation, tokens: TokenBreakdown,
                              at timestamp: Date? = nil, model: String? = nil) -> UsageEvent {
        UsageEvent(
            uuid: "\(obs.key)#\(tokens.input)#\(tokens.output)#\(tokens.cacheRead)#\(tokens.totalOnly)",
            sessionId: obs.sessionId,
            timestamp: timestamp ?? obs.timestamp,
            tokens: tokens,
            model: model ?? obs.model
        )
    }

    private static func parsePostSampling(_ body: String) -> (turnId: String, model: String?, total: Int)? {
        guard body.contains("post sampling token usage") else { return nil }
        guard let total = parseInt(after: "total_usage_tokens=", in: body) else { return nil }
        let turnId = parseToken(after: "turn_id=", in: body) ?? parseToken(after: "turn=", in: body)
        guard let turnId else { return nil }
        return (turnId, parseModel(body) ?? parseToken(after: "model=", in: body), total)
    }

    private static func parseToken(after marker: String, in body: String) -> String? {
        guard let range = body.range(of: marker) else { return nil }
        let tail = body[range.upperBound...]
        let token = tail.prefix { !$0.isWhitespace && $0 != "," && $0 != ")" }
        return token.isEmpty ? nil : String(token)
    }

    private static func parseInt(after marker: String, in body: String) -> Int? {
        guard let raw = parseToken(after: marker, in: body) else { return nil }
        return Int(raw)
    }

    /// First `model=<token>` span attribute in the body; token ends at whitespace.
    static func parseModel(_ body: String) -> String? {
        if let r = body.range(of: "model=") {
            let tok = body[r.upperBound...].prefix { !$0.isWhitespace }
            return tok.isEmpty ? nil : String(tok)
        }
        guard let r = body.range(of: #""model":""#) else { return nil }
        let tok = body[r.upperBound...].prefix { $0 != "\"" }
        return tok.isEmpty ? nil : String(tok)
    }

    private static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: text)
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

    private func hasColumn(_ column: String, in table: String, handle: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let name = sqlite3_column_text(stmt, 1) else { continue }
            if String(cString: name) == column { return true }
        }
        return false
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
            snapshot[url.path] = .init(offset: id, mtime: mtimes[url] ?? .distantPast,
                                       codexTraceTurns: traceTurns[url])
        }
        return ReaderState(entries: snapshot)
    }

    func restore(_ state: ReaderState) {
        offsets.removeAll(keepingCapacity: false)
        mtimes.removeAll(keepingCapacity: false)
        traceTurns.removeAll(keepingCapacity: false)
        for (path, entry) in state.entries {
            let url = URL(fileURLWithPath: path)
            offsets[url] = entry.offset
            mtimes[url] = entry.mtime
            traceTurns[url] = entry.codexTraceTurns ?? [:]
        }
    }
}
