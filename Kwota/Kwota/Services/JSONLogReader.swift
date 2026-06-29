//
//  JSONLogReader.swift
//  Kwota
//

import Foundation
import os

protocol JSONLogReader: AnyObject, Sendable {
    func read() -> [UsageEvent]
    /// Incremental read variant. Only the named files are stat'd and
    /// opened; the directory tree is not enumerated. Use when the caller
    /// already knows which files changed (e.g., from an FSEvents callback).
    /// Default impl falls back to the full `read()` so test fakes that
    /// don't care about the distinction stay untouched.
    func read(only paths: Set<URL>) -> [UsageEvent]
    func lastSeenLine() -> String?
    /// Snapshot of the reader's per-file offset/mtime table. Codable so
    /// `UsageMonitor` can persist it as part of the ledger envelope.
    /// Implementations should drop entries for files that no longer exist
    /// to keep the snapshot bounded.
    func state() -> ReaderState
    /// Restore a previously-snapshotted state. Must be called before any
    /// `read()` so the next read picks up at the saved offset rather than
    /// re-emitting the entire history from offset 0.
    func restore(_ state: ReaderState)
}

extension JSONLogReader {
    /// Default: fall back to full read. Lets test fakes that don't care
    /// about incremental reads stay untouched.
    func read(only paths: Set<URL>) -> [UsageEvent] { read() }
    /// Default no-op so test fakes that don't care about persistence stay
    /// untouched. `FilesystemJSONLogReader` provides the real implementation.
    func state() -> ReaderState { ReaderState() }
    func restore(_ state: ReaderState) {}
}

/// Persistable per-file read cursor. Stored inside the ledger envelope on
/// disk; replaces the previous reliance on `UsageLedger.seenUUIDs` for
/// cross-restart dedup.
struct ReaderState: Codable, Equatable, Sendable {
    var entries: [String: Entry]

    enum CodexTracePrecision: String, Codable, Equatable, Sendable {
        case exact
        case totalOnly
    }

    struct CodexTraceTurn: Codable, Equatable, Sendable {
        var precision: CodexTracePrecision
        var timestamp: Date
        var model: String?
        var tokens: TokenBreakdown
    }

    struct Entry: Codable, Equatable, Sendable {
        var offset: UInt64
        var mtime: Date
        /// Codex only: last-seen `turn_context.model` for this file, so model
        /// attribution survives a read that begins after the turn_context line
        /// was already consumed. Always nil for the Claude reader.
        var model: String?
        /// Codex only: last-seen cumulative `total_token_usage` for this file.
        /// Codex emits refresh `token_count` events that repeat a per-turn
        /// `last_token_usage` already counted while the cumulative total stays
        /// flat, so summing `last` over-counts. The reader emits the delta of
        /// this cumulative instead; persisting it keeps the baseline correct
        /// across a read boundary and a relaunch. nil for Claude/Antigravity.
        var codexTotal: CodexTotals?
        /// Antigravity only: row indices the cursor advanced past but that failed
        /// to decode (partial proto drift / a corrupt blob). The reader re-queries
        /// these each read so they recover after a decoder fix, without blocking
        /// the valid rows after them. nil/empty for Claude/Codex.
        var failedIdx: [UInt64]?
        var codexTraceTurns: [String: CodexTraceTurn]?

        init(offset: UInt64, mtime: Date, model: String? = nil,
             codexTotal: CodexTotals? = nil, failedIdx: [UInt64]? = nil,
             codexTraceTurns: [String: CodexTraceTurn]? = nil) {
            self.offset = offset
            self.mtime = mtime
            self.model = model
            self.codexTotal = codexTotal
            self.failedIdx = failedIdx
            self.codexTraceTurns = codexTraceTurns
        }
    }

    /// Cumulative `total_token_usage` snapshot (Codex). Fields mirror the wire
    /// shape: `input` INCLUDES `cached`, `output` INCLUDES reasoning.
    struct CodexTotals: Codable, Equatable, Sendable {
        var input: Int
        var cached: Int
        var output: Int
    }

    init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }
}

/// `@unchecked Sendable`: `offsets`/`mtimes` are mutated only inside `read()`,
/// and `UsageMonitor` serializes reads (never two in flight), so they stay
/// confined to one task at a time. `lastLine` is the only field touched
/// cross-thread — `read()` writes it off the main actor (via `tickAsync`)
/// while the debug surfaces read it on the main actor — so it is lock-guarded.
final class FilesystemJSONLogReader: JSONLogReader, @unchecked Sendable {
    private let root: URL
    private let fm: FileManager
    private var offsets: [URL: UInt64] = [:]
    private var mtimes: [URL: Date] = [:]
    private let lastLineLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(root: URL = FilesystemJSONLogReader.defaultRoot(), fileManager: FileManager = .default) {
        self.root = root
        self.fm = fileManager
    }

    static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    func lastSeenLine() -> String? { lastLineLock.withLock { $0 } }

    func read() -> [UsageEvent] {
        guard fm.fileExists(atPath: root.path) else { return [] }
        var emitted: [UsageEvent] = []
        let files = discoverFiles()
        // Prune cursors for files that no longer exist HERE, on the full walk,
        // rather than stat'ing every cursor inside `state()` on the persist hot
        // path. `discoverFiles()` already enumerated the live set, so this costs
        // no extra syscalls and keeps the persisted snapshot bounded.
        let live = Set(files)
        offsets = offsets.filter { live.contains($0.key) }
        mtimes = mtimes.filter { live.contains($0.key) }
        for fileURL in files {
            readOne(fileURL, into: &emitted)
        }
        return emitted
    }

    func read(only paths: Set<URL>) -> [UsageEvent] {
        guard fm.fileExists(atPath: root.path) else { return [] }
        var emitted: [UsageEvent] = []
        for fileURL in paths {
            // Normalize via realpath so the offset key matches what
            // `discoverFiles()` produces. On macOS, FileManager resolves
            // `/var` -> `/private/var` for paths returned from
            // `contentsOfDirectory(at:)`, but `URL.standardizedFileURL`
            // / `URL.resolvingSymlinksInPath()` do NOT. Without realpath,
            // a file touched via read(only:) and re-read by a follow-up
            // full read() would land in two different dictionary keys.
            let normalized = Self.canonicalize(fileURL)
            // Defense-in-depth: only consume paths under our root. FSEvents
            // can (rarely) deliver paths outside the watched dir. Trailing
            // separator so a sibling like `projects-backup` isn't accepted by
            // a bare prefix match on `projects`.
            guard normalized.path.hasPrefix(Self.canonicalize(root).path + "/") else { continue }
            guard normalized.pathExtension == "jsonl" else { continue }
            readOne(normalized, into: &emitted)
        }
        return emitted
    }

    /// `realpath(3)` wrapper. Resolves both `..` components and `/var` ->
    /// `/private/var` style symlinks so URL keys stay stable across
    /// `read()` (via FileManager.enumerator) and `read(only:)` (caller-
    /// supplied paths). Falls back to the input URL when realpath fails,
    /// e.g. for a path that does not exist yet.
    private static func canonicalize(_ url: URL) -> URL {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(url.path, &buf) != nil {
            return URL(fileURLWithPath: String(cString: buf))
        }
        return url
    }

    /// Per-file logic shared by `read()` (full walk) and `read(only:)`
    /// (incremental, added in a follow-up commit). Advances
    /// `offsets[fileURL]` and emits parsed events. Idempotent: a call
    /// where `size == startOffset` is a no-op other than the mtime refresh.
    private func readOne(_ fileURL: URL, into emitted: inout [UsageEvent]) {
        let attrs = (try? fm.attributesOfItem(atPath: fileURL.path)) ?? [:]
        let size = (attrs[.size] as? UInt64) ?? 0
        let mtime = attrs[.modificationDate] as? Date
        let stored = offsets[fileURL] ?? 0
        var startOffset = stored
        // Reset ONLY on a genuine shrink (truncation/rotation). A bare mtime
        // change at the same-or-larger size — `touch`, a backup/Time-Machine
        // restore, a same-size rewrite — must NOT reset a fully-consumed file:
        // re-reading it re-emits every event, and neither the stats ledger nor
        // (post-v3) UsageMonitor dedups per event, so it double-counts. These
        // session transcripts are append-only, so a shrink is the only real
        // rotation signal.
        if size < startOffset {
            startOffset = 0
        }
        if let m = mtime { mtimes[fileURL] = m }
        if size == startOffset { return }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: startOffset)
            let data = handle.readDataToEndOfFile()

            // Only consume up to the last newline; defer any partial final line.
            guard let lastNewline = data.lastIndex(of: 0x0A) else {
                return   // no complete line yet; don't advance offset
            }
            let consumable = data.prefix(through: lastNewline)
            let advanced = startOffset + UInt64(consumable.count)

            if let text = String(data: consumable, encoding: .utf8) {
                for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    let line = String(raw)
                    lastLineLock.withLock { $0 = line }
                    if let event = parse(line: line) {
                        emitted.append(event)
                    }
                }
            }

            offsets[fileURL] = advanced
        } catch {
            AppLog.shared.log("JSONLogReader read failed for \(fileURL.lastPathComponent): \(error)", level: .warn)
        }
    }

    private func discoverFiles() -> [URL] {
        guard let projectDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [URL] = []
        for dir in projectDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            // Recurse: Claude Code writes subagent sessions to a nested
            // <project>/<sessionId>/subagents/agent-*.jsonl path. The parent
            // jsonl only bookends a subagent run with dispatch + return
            // turns, so without descending we miss every assistant message
            // in between — both a token under-count and the cause of
            // auto-awake idling out mid-subagent.
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                files.append(url)
            }
        }
        return files
    }

    private func parse(line: String) -> UsageEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            AppLog.shared.log("JSONLogReader parse failed (bad JSON)", level: .warn)
            return nil
        }
        guard (obj["type"] as? String) == "assistant" else { return nil }
        guard let message = obj["message"] as? [String: Any],
              let usageDict = message["usage"] as? [String: Any] else { return nil }
        guard let uuid = obj["uuid"] as? String,
              let sessionId = obj["sessionId"] as? String,
              let tsString = obj["timestamp"] as? String,
              let ts = Self.isoParser.date(from: tsString) else { return nil }

        let usageData = (try? JSONSerialization.data(withJSONObject: usageDict)) ?? Data()
        let tokens = (try? JSONDecoder().decode(TokenBreakdown.self, from: usageData)) ?? .zero
        let model = message["model"] as? String
        return UsageEvent(uuid: uuid, sessionId: sessionId, timestamp: ts, tokens: tokens, model: model)
    }

    // `state()` / `restore(_:)` touch `offsets`/`mtimes`; callers must not
    // invoke them concurrently with `read()`. `UsageMonitor` only calls
    // `restore()` before its first `read()` and `state()` after a read
    // completes, so they share the same single-task confinement.
    func state() -> ReaderState {
        // Pure in-memory snapshot — no per-file `fileExists`. This runs on the
        // persist hot path (every ingest, on the main actor), so stat'ing every
        // tracked cursor here was O(history) syscalls per event batch. Dead
        // cursors are dropped instead on the next full `read()` walk.
        var snapshot: [String: ReaderState.Entry] = [:]
        for (url, offset) in offsets {
            let mtime = mtimes[url] ?? .distantPast
            snapshot[url.path] = .init(offset: offset, mtime: mtime)
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
