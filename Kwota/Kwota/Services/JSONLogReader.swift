//
//  JSONLogReader.swift
//  Kwota
//

import Foundation
import os

protocol JSONLogReader: AnyObject, Sendable {
    func read() -> [UsageEvent]
    func lastSeenLine() -> String?
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

        for fileURL in discoverFiles() {
            let attrs = (try? fm.attributesOfItem(atPath: fileURL.path)) ?? [:]
            let size = (attrs[.size] as? UInt64) ?? 0
            let mtime = attrs[.modificationDate] as? Date
            let stored = offsets[fileURL] ?? 0
            var startOffset = stored
            // Reset on rotation: file size shrank OR mtime changed while offset >= size
            // (atomic overwrite produces a new mtime even with same byte length)
            let mtimeChanged = mtime != nil && mtime != mtimes[fileURL] && mtimes[fileURL] != nil
            if size < startOffset || (mtimeChanged && size <= startOffset) {
                startOffset = 0
            }
            if let m = mtime { mtimes[fileURL] = m }
            if size == startOffset { continue }

            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { continue }
            defer { try? handle.close() }

            do {
                try handle.seek(toOffset: startOffset)
                let data = handle.readDataToEndOfFile()

                // Only consume up to the last newline; defer any partial final line.
                guard let lastNewline = data.lastIndex(of: 0x0A) else {
                    continue   // no complete line yet; don't advance offset
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
        return emitted
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
        return UsageEvent(uuid: uuid, sessionId: sessionId, timestamp: ts, tokens: tokens)
    }
}
