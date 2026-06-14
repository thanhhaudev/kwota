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
    private let lastLineLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

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
        for fileURL in discoverFiles() { readOne(fileURL, into: &emitted) }
        return emitted
    }

    func read(only paths: Set<URL>) -> [UsageEvent] {
        guard fm.fileExists(atPath: root.path) else { return [] }
        var emitted: [UsageEvent] = []
        let rootPath = Self.canonicalize(root).path
        for fileURL in paths {
            let normalized = Self.canonicalize(fileURL)
            guard normalized.path.hasPrefix(rootPath) else { continue }
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
        let mtimeChanged = mtime != nil && mtime != mtimes[fileURL] && mtimes[fileURL] != nil
        if size < startOffset || (mtimeChanged && size <= startOffset) {
            startOffset = 0
            models[fileURL] = nil
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
            if let text = String(data: consumable, encoding: .utf8) {
                for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    let line = String(raw)
                    lastLineLock.withLock { $0 = line }
                    parse(line: line, file: fileURL, model: &currentModel, into: &emitted)
                }
            }
            models[fileURL] = currentModel
            offsets[fileURL] = advanced
        } catch {
            AppLog.shared.log("CodexStatsReader read failed for \(fileURL.lastPathComponent): \(error)", level: .warn)
        }
    }

    private func parse(line: String, file: URL, model currentModel: inout String?,
                       into emitted: inout [UsageEvent]) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String,
              let payload = obj["payload"] as? [String: Any] else { return }

        if type == "turn_context" {
            if let m = payload["model"] as? String, !m.isEmpty { currentModel = m }
            return
        }
        guard type == "event_msg", (payload["type"] as? String) == "token_count",
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any] else { return }

        let inputRaw = (last["input_tokens"] as? Int) ?? 0
        let cached   = (last["cached_input_tokens"] as? Int) ?? 0
        let output   = (last["output_tokens"] as? Int) ?? 0
        let tokens = TokenBreakdown(input: max(0, inputRaw - cached), output: output,
                                    cacheCreation: 0, cacheRead: cached)
        guard tokens != .zero else { return }

        guard let tsString = obj["timestamp"] as? String,
              let ts = Self.isoParser.date(from: tsString) else { return }
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
        var snapshot: [String: ReaderState.Entry] = [:]
        for (url, offset) in offsets {
            guard fm.fileExists(atPath: url.path) else { continue }
            snapshot[url.path] = .init(offset: offset, mtime: mtimes[url] ?? .distantPast, model: models[url])
        }
        return ReaderState(entries: snapshot)
    }

    func restore(_ state: ReaderState) {
        offsets.removeAll(keepingCapacity: false)
        mtimes.removeAll(keepingCapacity: false)
        models.removeAll(keepingCapacity: false)
        for (path, entry) in state.entries {
            let url = URL(fileURLWithPath: path)
            offsets[url] = entry.offset
            mtimes[url] = entry.mtime
            if let m = entry.model { models[url] = m }
        }
    }
}
