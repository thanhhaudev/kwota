//
//  ProviderActivityScanner.swift
//  Kwota
//

import Foundation

/// One provider's backfill configuration: where its activity files live, which
/// files to read, and how to pull an activity timestamp out of one JSONL line.
///
/// The `timestamp` closure returns non-nil only for lines that represent an
/// agent reply — the same unit Claude's `type=="assistant"` records count — so
/// backfill totals are comparable across providers. Non-reply lines (user
/// input, tool/reasoning steps, metadata) return nil and aren't counted.
struct ProviderActivityScanner: Sendable {
    let provider: ProviderID
    let roots: [URL]
    let matchesFile: @Sendable (URL) -> Bool
    /// Parse one raw JSONL line (UTF-8 bytes) into an activity Date, or nil.
    let timestamp: @Sendable (Data) -> Date?
    /// Optional whole-file predicate. A matched file for which this returns true
    /// is skipped entirely — none of its lines are counted. Used to drop Kwota's
    /// own cache-eval transcripts (which the provider CLI writes into the watched
    /// tree) from the activity chart. `nil` → nothing excluded.
    let excludeFile: (@Sendable (Data) -> Bool)?

    init(
        provider: ProviderID,
        roots: [URL],
        matchesFile: @escaping @Sendable (URL) -> Bool,
        timestamp: @escaping @Sendable (Data) -> Date?,
        excludeFile: (@Sendable (Data) -> Bool)? = nil
    ) {
        self.provider = provider
        self.roots = roots
        self.matchesFile = matchesFile
        self.timestamp = timestamp
        self.excludeFile = excludeFile
    }
}

/// Shared one-shot backfill scan + per-provider factory configs. Mirrors
/// `ActivityHistorian.scanClaudeBackfill` (the Claude path), including the
/// mtime-skip optimization: a file whose mtime predates the cutoff cannot
/// contain anything in-window, so it's never read.
enum ProviderActivityBackfill {
    /// One activity file an `ActivitySource` hadn't yet tracked: its consumable
    /// end-of-file (byte offset after the last complete line) plus the activity
    /// dates at/after the discovery cutoff. `Sendable` so discovery can run via
    /// `OffMain.run`.
    struct DiscoveredFile: Sendable {
        let path: String
        let endOffset: UInt64
        let dates: [Date]
    }

    /// Files matching `matchesFile` under `roots`, modified at/after `cutoff` and
    /// whose path isn't in `known`, each with its consumable end-offset and the
    /// activity dates at/after `cutoff`. Lets an activity source pick up files
    /// created during a *total* FSEvents blackout (when the live stream never
    /// reported them) — the gap the poll backstop alone can't close because it
    /// only revisits already-known paths.
    ///
    /// The `cutoff` is the source's `start()` time, which is also when launch
    /// backfill scanned: only lines newer than that are emitted, so a re-opened
    /// old session can't double-count content backfill already recorded. Offsets
    /// stop at the last complete line (matching `newLines`) so a partial trailing
    /// line is left for the next append. Pure / off-main-safe — no actor state.
    static func scanUntracked(
        roots: [URL],
        matchesFile: @Sendable (URL) -> Bool,
        timestamp: @Sendable (Data) -> Date?,
        known: Set<String>,
        cutoff: Date,
        excludeFile: (@Sendable (Data) -> Bool)? = nil
    ) -> [DiscoveredFile] {
        let fm = FileManager.default
        let roots = roots.filter { candidate in
            let candidatePath = candidate.path + "/"
            return !roots.contains { $0 != candidate && $0.path.hasPrefix(candidatePath) }
        }
        var out: [DiscoveredFile] = []
        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
            ) else { continue }
            for case let url as URL in enumerator {
                guard matchesFile(url), !known.contains(url.path) else { continue }
                if let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate, mtime < cutoff { continue }
                guard let data = try? Data(contentsOf: url) else { continue }
                if let excludeFile, excludeFile(data) { continue }
                let bytes = [UInt8](data)
                let newline = UInt8(ascii: "\n")
                var dates: [Date] = []
                var lineStart = 0
                var consumed = 0
                for i in 0..<bytes.count where bytes[i] == newline {
                    if i > lineStart, let d = timestamp(Data(bytes[lineStart..<i])), d >= cutoff {
                        dates.append(d)
                    }
                    lineStart = i + 1
                    consumed = i + 1
                }
                out.append(DiscoveredFile(path: url.path, endOffset: UInt64(consumed), dates: dates))
            }
        }
        return out
    }

    static func scan(_ scanner: ProviderActivityScanner, cutoff: Date) -> [Date] {
        let fm = FileManager.default
        var out: [Date] = []
        // Drop any root whose path is an ancestor of another root in the set —
        // a scanner may supply a broad fallback root (e.g. `~/.gemini`) for one
        // chain while a more specific descendant (e.g. `.../brain`) already
        // covers the same tree; keeping both would double-count every match.
        let roots = scanner.roots.filter { candidate in
            let candidatePath = candidate.path + "/"
            return !scanner.roots.contains { other in
                other != candidate && other.path.hasPrefix(candidatePath)
            }
        }
        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
            ) else { continue }
            for case let url as URL in enumerator {
                guard scanner.matchesFile(url) else { continue }
                if let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate, mtime < cutoff {
                    continue
                }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if let excludeFile = scanner.excludeFile, excludeFile(Data(text.utf8)) { continue }
                for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard let data = String(raw).data(using: .utf8),
                          let ts = scanner.timestamp(data),
                          ts >= cutoff else { continue }
                    out.append(ts)
                }
            }
        }
        out.sort()
        return out
    }

    // Codex stamps fractional seconds ("…:41.983Z"); Antigravity does not
    // ("…:29Z"). Try fractional first, then plain.
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    /// Codex: `~/.codex/sessions/**/rollout-*.jsonl`. Counts one event per
    /// `response_item` whose payload is the assistant's text reply
    /// (`payload.type=="message"`, `role=="assistant"`). Tool calls
    /// (`function_call`, `web_search_call`, etc.), their `_call_output`
    /// results, `reasoning`, and user/developer messages are NOT counted —
    /// each turn produces one event, matching Claude's per-`type=="assistant"`
    /// record unit and Antigravity's per-`PLANNER_RESPONSE` unit so the
    /// shared-scale multi-wave chart compares like with like. (Without this,
    /// a turn with N tool calls inflated the Codex wave by N× relative to
    /// the same turn on Claude/Antigravity, and a turn taken via `codex`
    /// CLI showed many more bars than the same turn taken via the
    /// app-server WAL path which already collapses to one event per turn.)
    /// Reuses `CodexActivitySource.watchRoots` (deepest existing of
    /// `~/.codex/sessions` → `~/.codex`); `[]` when Codex isn't installed.
    static func codex(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ProviderActivityScanner {
        ProviderActivityScanner(
            provider: .codex,
            roots: CodexActivitySource.watchRoots(home: home).map { URL(fileURLWithPath: $0) },
            matchesFile: { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" },
            timestamp: { data in
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (obj["type"] as? String) == "response_item",
                      let payload = obj["payload"] as? [String: Any],
                      let s = obj["timestamp"] as? String else { return nil }
                let ptype = (payload["type"] as? String) ?? ""
                let isAssistantMessage = ptype == "message" && (payload["role"] as? String) == "assistant"
                guard isAssistantMessage else { return nil }
                return parseDate(s)
            }
        )
    }

    /// Antigravity: `~/.gemini/**/brain/**/transcript.jsonl`, `PLANNER_RESPONSE`
    /// rows (the agent's reply; `USER_INPUT`, `EPHEMERAL_MESSAGE`, and
    /// `CONVERSATION_HISTORY` lines are not counted). Reuses
    /// `AntigravityActivitySource.watchRoots` (deepest existing of the IDE + CLI
    /// brain chains); `[]` when `~/.gemini` is absent.
    static func antigravity(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ProviderActivityScanner {
        ProviderActivityScanner(
            provider: .antigravity,
            roots: AntigravityActivitySource.watchRoots(home: home).map { URL(fileURLWithPath: $0) },
            matchesFile: { $0.lastPathComponent == "transcript.jsonl" },
            timestamp: { data in
                // `PLANNER_RESPONSE` is the agent's reply; other line types
                // (USER_INPUT, EPHEMERAL_MESSAGE, CONVERSATION_HISTORY) are not.
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (obj["type"] as? String) == "PLANNER_RESPONSE",
                      let s = obj["created_at"] as? String else { return nil }
                return parseDate(s)
            },
            // Drop Kwota's own cache-eval `agy -p` runs: they write a transcript
            // into the same `antigravity-cli/brain` tree this scanner reads, and
            // would otherwise count as phantom agent activity.
            excludeFile: { AntigravityCacheEvalFilter.isCacheEvalTranscript($0) }
        )
    }
}
