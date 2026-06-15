//  CodexCompositeReader.swift
//  Kwota
//
//  Presents the two Codex stats sources — rollout JSONL (`CodexStatsReader`) and
//  the trace DB (`CodexTraceReader`) — as a single `.codex` `JSONLogReader`, so
//  `StatsStore` (one reader per provider) is untouched. Their file paths are
//  disjoint (rollout-*.jsonl under sessions/ vs logs_*.sqlite), so one
//  `ReaderState` carries both cursors; `restore` routes each entry to its owner.
//  Each sub-reader self-filters paths in `read(only:)`, so a rollout FSEvents
//  signal never opens SQLite and the trace poll never walks the rollout tree.

import Foundation

final class CodexCompositeReader: JSONLogReader, @unchecked Sendable {
    private let rollout: JSONLogReader
    private let trace: JSONLogReader

    init(rollout: JSONLogReader, trace: JSONLogReader) {
        self.rollout = rollout
        self.trace = trace
    }

    func read() -> [UsageEvent] { rollout.read() + trace.read() }

    func read(only paths: Set<URL>) -> [UsageEvent] {
        rollout.read(only: paths) + trace.read(only: paths)
    }

    func lastSeenLine() -> String? { trace.lastSeenLine() ?? rollout.lastSeenLine() }

    func state() -> ReaderState {
        var entries = rollout.state().entries
        for (k, v) in trace.state().entries { entries[k] = v }
        return ReaderState(entries: entries)
    }

    func restore(_ state: ReaderState) {
        var rolloutE: [String: ReaderState.Entry] = [:]
        var traceE: [String: ReaderState.Entry] = [:]
        for (path, entry) in state.entries {
            if Self.isTracePath(path) { traceE[path] = entry } else { rolloutE[path] = entry }
        }
        rollout.restore(ReaderState(entries: rolloutE))
        trace.restore(ReaderState(entries: traceE))
    }

    /// A `logs_*.sqlite` path belongs to the trace reader; everything else
    /// (rollout-*.jsonl) to the rollout reader.
    static func isTracePath(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("logs_") && name.hasSuffix(".sqlite")
    }
}
