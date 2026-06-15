//
//  CodexStatsReader.swift
//  Kwota
//

import Foundation
import os

/// `JSONLogReader` over `~/.codex/sessions/**/rollout-*.jsonl`. Parses Codex
/// `token_count` events into `UsageEvent`s using the per-turn `last_token_usage`
/// delta, attributing each to the most recent `turn_context.model`. Keeps its
/// own per-file byte offsets (+ last-seen model) so incremental reads never
/// double-count and model attribution survives a read boundary between a
/// turn_context and its token_count events.
///
/// `@unchecked Sendable`: `offsets`/`mtimes`/`models` are mutated only inside
/// `read()`, which `StatsStore` serializes (never two reads in flight), so they
/// stay confined to one task at a time. `lastLine` is lock-guarded.
final class CodexStatsReader: JSONLogReader, @unchecked Sendable {
    private let root: URL
    private let fm: FileManager
    private var offsets: [URL: UInt64] = [:]
    private var mtimes: [URL: Date] = [:]
    private var models: [URL: String] = [:]
    private var totals: [URL: ReaderState.CodexTotals] = [:]   // last-seen cumulative total per file
    private let lastLineLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoParserNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parse an ISO-8601 timestamp with OR without fractional seconds.
    private static func parseTimestamp(_ s: String) -> Date? {
        isoParser.date(from: s) ?? isoParserNoFrac.date(from: s)
    }

    init(root: URL = CodexStatsReader.defaultRoot(), fileManager: FileManager = .default) {
        self.root = root
        self.fm = fileManager
    }

    static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    func lastSeenLine() -> String? { lastLineLock.withLock { $0 } }

    func read() -> [UsageEvent] {
        guard fm.fileExists(atPath: root.path) else { return [] }
        var emitted: [UsageEvent] = []
        let files = discoverFiles()
        // Prune cursors (+ models) for vanished files on the full walk, so
        // `state()` stays a syscall-free in-memory snapshot on the persist path.
        let live = Set(files)
        offsets = offsets.filter { live.contains($0.key) }
        mtimes = mtimes.filter { live.contains($0.key) }
        models = models.filter { live.contains($0.key) }
        totals = totals.filter { live.contains($0.key) }
        for fileURL in files { readOne(fileURL, into: &emitted) }
        return emitted
    }

    func read(only paths: Set<URL>) -> [UsageEvent] {
        guard fm.fileExists(atPath: root.path) else { return [] }
        var emitted: [UsageEvent] = []
        // Trailing separator so the prefix test rejects sibling dirs like
        // `~/.codex/sessions-backup/...` (a bare `hasPrefix("…/sessions")`
        // would accept them and fold backup/synced history into the ledger).
        let rootPrefix = Self.canonicalize(root).path + "/"
        for fileURL in paths {
            let normalized = Self.canonicalize(fileURL)
            guard normalized.path.hasPrefix(rootPrefix) else { continue }
            guard normalized.pathExtension == "jsonl",
                  normalized.lastPathComponent.hasPrefix("rollout-") else { continue }
            readOne(normalized, into: &emitted)
        }
        return emitted
    }

    private static func canonicalize(_ url: URL) -> URL {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(url.path, &buf) != nil { return URL(fileURLWithPath: String(cString: buf)) }
        return url
    }

    private func readOne(_ fileURL: URL, into emitted: inout [UsageEvent]) {
        let attrs = (try? fm.attributesOfItem(atPath: fileURL.path)) ?? [:]
        let size = (attrs[.size] as? UInt64) ?? 0
        let mtime = attrs[.modificationDate] as? Date
        let stored = offsets[fileURL] ?? 0
        var startOffset = stored
        // Reset ONLY on a genuine shrink (truncation/rotation). A bare mtime
        // change at the same-or-larger size — `touch`, a backup/Time-Machine
        // restore, a same-size rewrite — must NOT reset: re-reading a
        // fully-consumed rollout re-emits every token_count event, and the
        // ledger has no per-event dedup, so tokens double-count permanently.
        // Rollouts are append-only, so a shrink is the only real rotation.
        if size < startOffset {
            startOffset = 0
            models[fileURL] = nil
            totals[fileURL] = nil   // rotation: cumulative total restarts too
        }
        if let m = mtime { mtimes[fileURL] = m }
        if size == startOffset { return }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: startOffset)
            let data = handle.readDataToEndOfFile()
            guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
            let consumable = data.prefix(through: lastNewline)
            let advanced = startOffset + UInt64(consumable.count)
            var currentModel = models[fileURL]
            var runningTotal = totals[fileURL]
            if let text = String(data: consumable, encoding: .utf8) {
                for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    let line = String(raw)
                    lastLineLock.withLock { $0 = line }
                    parse(line: line, file: fileURL, model: &currentModel,
                          total: &runningTotal, into: &emitted)
                }
            }
            models[fileURL] = currentModel
            totals[fileURL] = runningTotal
            offsets[fileURL] = advanced
        } catch {
            AppLog.shared.log("CodexStatsReader read failed for \(fileURL.lastPathComponent): \(error)", level: .warn)
        }
    }

    private func parse(line: String, file: URL, model currentModel: inout String?,
                       total runningTotal: inout ReaderState.CodexTotals?,
                       into emitted: inout [UsageEvent]) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String,
              let payload = obj["payload"] as? [String: Any] else { return }

        if type == "turn_context" {
            if let m = payload["model"] as? String, !m.isEmpty { currentModel = m }
            return
        }
        // Use the cumulative `total_token_usage`, NOT `last_token_usage`: Codex
        // emits refresh events (e.g. rate-limit updates) that repeat a non-zero
        // `last` already counted while the cumulative total stays flat, so summing
        // `last` double-counts (measured ~24% of real session files over-count).
        // The cumulative is authoritative; we emit its per-turn DELTA. An event
        // with no `total_token_usage` (rate-limit-only refresh) carries no usable
        // cumulative and is skipped entirely.
        guard type == "event_msg", (payload["type"] as? String) == "token_count",
              let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any] else { return }

        // Validate the timestamp BEFORE mutating `runningTotal`: a dropped event
        // must NOT advance the cumulative baseline, or its delta is lost forever
        // (the next event would diff against a total we skipped). Tolerate ISO
        // with or without fractional seconds.
        guard let tsString = obj["timestamp"] as? String,
              let ts = Self.parseTimestamp(tsString) else { return }

        let cur = ReaderState.CodexTotals(input: (total["input_tokens"] as? Int) ?? 0,
                                          cached: (total["cached_input_tokens"] as? Int) ?? 0,
                                          output: (total["output_tokens"] as? Int) ?? 0)
        // Baseline for the delta. Cumulative totals are monotonic within a
        // rollout; if any field went backwards (unexpected reset), rebase to 0
        // so we never emit a negative delta.
        var prev = runningTotal ?? ReaderState.CodexTotals(input: 0, cached: 0, output: 0)
        if cur.input < prev.input || cur.cached < prev.cached || cur.output < prev.output {
            prev = ReaderState.CodexTotals(input: 0, cached: 0, output: 0)
        }
        runningTotal = cur

        let dInputRaw = cur.input - prev.input   // includes cached
        let dCached   = cur.cached - prev.cached
        let dOutput   = cur.output - prev.output
        let tokens = TokenBreakdown(input: max(0, dInputRaw - dCached), output: dOutput,
                                    cacheCreation: 0, cacheRead: dCached)
        guard tokens != .zero else { return }

        let sessionId = file.deletingPathExtension().lastPathComponent
        emitted.append(UsageEvent(uuid: "\(sessionId)@\(tsString)", sessionId: sessionId,
                                  timestamp: ts, tokens: tokens, model: currentModel))
    }

    private func discoverFiles() -> [URL] {
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator
        where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
            files.append(url)
        }
        return files
    }

    func state() -> ReaderState {
        // Syscall-free in-memory snapshot (runs on the persist hot path); dead
        // cursors are pruned on the next full `read()` walk, not stat'd here.
        var snapshot: [String: ReaderState.Entry] = [:]
        for (url, offset) in offsets {
            snapshot[url.path] = .init(offset: offset, mtime: mtimes[url] ?? .distantPast,
                                       model: models[url], codexTotal: totals[url])
        }
        return ReaderState(entries: snapshot)
    }

    func restore(_ state: ReaderState) {
        offsets.removeAll(keepingCapacity: false)
        mtimes.removeAll(keepingCapacity: false)
        models.removeAll(keepingCapacity: false)
        totals.removeAll(keepingCapacity: false)
        for (path, entry) in state.entries {
            let url = URL(fileURLWithPath: path)
            offsets[url] = entry.offset
            mtimes[url] = entry.mtime
            if let m = entry.model { models[url] = m }
            if let t = entry.codexTotal { totals[url] = t }
        }
    }
}
