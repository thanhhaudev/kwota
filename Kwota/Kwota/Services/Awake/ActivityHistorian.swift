//
//  ActivityHistorian.swift
//  Kwota
//

import Foundation
import Observation

/// Ring-buffer of recent Claude assistant-event timestamps used by the Awake
/// tab's activity chart. Two intake paths:
///   * One-shot **backfill** scan of `~/.claude/projects/**/*.jsonl` kicked at
///     init (off the main actor via `OffMain.run`, then applied on main) —
///     seeds the buffer so the chart fills in a moment after launch.
///   * Streaming **record(_:)** call wired from `UsageMonitor.tick()` so new
///     assistant events flow in as the JSONL log grows.
///
/// Timestamps older than `windowSeconds` are pruned lazily on every read.
/// Insertion is dedup'd by `UsageEvent.uuid` so backfill + streaming don't
/// double-count the same event.
@MainActor
@Observable
final class ActivityHistorian {
    /// One assistant event found during the Claude backfill scan. `Sendable` so
    /// the scan can run off the main actor via `OffMain.run`.
    struct ScannedEvent: Sendable {
        let uuid: String
        let date: Date
    }

    private(set) var eventTimestamps: [Date] = []

    /// Coarse per-provider presence timestamps for non-Claude providers
    /// (`.codex`, `.antigravity`). Claude stays in `eventTimestamps` so its
    /// existing intake/dedup/prune logic is untouched. Observed so the chart
    /// updates live.
    private(set) var otherEvents: [ProviderID: [Date]] = [:]

    @ObservationIgnored private var seenUUIDs: Set<String> = []
    /// Per-provider dedup for non-Claude events. Claude dedups on `uuid`, but
    /// provider events carry only a date, so a reply parsed identically by both
    /// the live first-sight read and the one-shot launch backfill (which can
    /// overlap for a session created just after start()) would otherwise be
    /// counted twice. Keyed on the exact parsed `Date` — both paths run the same
    /// `scanner.timestamp`, so the same reply yields the same value.
    @ObservationIgnored private var seenOtherDates: [ProviderID: Set<Date>] = [:]
    @ObservationIgnored private let windowSeconds: TimeInterval
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let backfillRoot: URL
    /// Where to persist `otherEvents` so non-Claude history survives relaunch.
    /// Only the non-Claude providers are persisted: Claude is re-backfilled
    /// from `~/.claude/projects/**/*.jsonl` on every launch (Claude Code writes
    /// those itself), and interactive Codex CLI is re-backfilled from
    /// `~/.codex/sessions/**/rollout-*.jsonl`. But Codex via `/codex` app-server
    /// only bumps the shared SQLite WAL — `scheduleWALFlush` emits those at
    /// runtime with `clock()` timestamps, and there's no source file to scan
    /// from on relaunch. Without disk persistence the chart's Codex bars
    /// vanish whenever Kwota restarts even though the user was using Codex.
    @ObservationIgnored private let persistURL: URL?

    init(
        windowSeconds: TimeInterval = 24 * 3600,
        clock: @escaping () -> Date = { Date() },
        backfillRoot: URL? = nil,
        autoBackfill: Bool = true,
        autoBackfillDelay: TimeInterval = 0,
        persistURL: URL? = nil
    ) {
        self.windowSeconds = windowSeconds
        self.clock = clock
        // Default-value evaluation runs in a synchronous nonisolated context,
        // which can't safely call the MainActor-bound `defaultRoot()`. Resolve
        // inside the init body where we're guaranteed on the actor.
        self.backfillRoot = backfillRoot ?? FilesystemJSONLogReader.defaultRoot()
        self.persistURL = persistURL

        if let url = persistURL {
            let cutoff = clock().addingTimeInterval(-windowSeconds)
            let loaded = Self.loadPersisted(from: url, cutoff: cutoff)
            self.otherEvents = loaded.events
            self.seenOtherDates = loaded.seen
        }

        if autoBackfill {
            // `autoBackfillDelay > 0` defers the launch-time `~/.claude/projects`
            // scan so the first provider refresh (which bridges a URLRequest)
            // completes before the scan's heavy CF/JSON traffic kicks in. Some
            // hosts have been observed to crash `URLRequest._bridgeToObjectiveC`
            // under sustained concurrent CF allocation pressure at launch.
            // Tests default to zero so behavior is unchanged.
            let delay = autoBackfillDelay
            Task { [weak self] in
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                await self?.backfillAsync()
            }
        }
    }

    nonisolated static func defaultPersistURL() -> URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("activity-events.json")
    }

    /// Streaming intake from `UsageMonitor.tick`. Filters out events older than
    /// the window and events whose `uuid` has already been recorded (so the
    /// startup backfill + first live tick can't double-count).
    func record(_ events: [UsageEvent]) {
        let cutoff = clock().addingTimeInterval(-windowSeconds)
        var added = false
        for ev in events {
            guard ev.timestamp >= cutoff, !seenUUIDs.contains(ev.uuid) else { continue }
            seenUUIDs.insert(ev.uuid)
            eventTimestamps.append(ev.timestamp)
            added = true
        }
        if added {
            eventTimestamps.sort()
        }
        prune()
    }

    /// Live append for non-Claude providers (from the activity sink in
    /// `MenuBarViewModel`). Claude is rejected — it flows through the richer,
    /// uuid-deduped `record(_ events:)` path instead. Drops out-of-window
    /// dates, keeps the per-provider array sorted, and prunes.
    func record(provider: ProviderID, at date: Date) {
        guard provider != .claude else { return }
        let cutoff = clock().addingTimeInterval(-windowSeconds)
        guard date >= cutoff else { return }
        guard seenOtherDates[provider]?.contains(date) != true else { return }
        seenOtherDates[provider, default: []].insert(date)
        var arr = otherEvents[provider] ?? []
        arr.append(date)
        arr.sort()
        otherEvents[provider] = arr
        prune()
        persist()
    }

    /// Timestamps for one provider. `.claude` returns the existing Claude store;
    /// others read `otherEvents`.
    func timestamps(for provider: ProviderID) -> [Date] {
        provider == .claude ? eventTimestamps : (otherEvents[provider] ?? [])
    }

    /// Providers with at least one timestamp inside `range`, in a stable display
    /// order (`.claude`, `.codex`, `.antigravity`). Providers without timestamps
    /// in `range` are omitted.
    func activeProviders(in range: ClosedRange<Date>) -> [ProviderID] {
        let order: [ProviderID] = [.claude, .codex, .antigravity]
        return order.filter { provider in
            timestamps(for: provider).contains { range.contains($0) }
        }
    }

    /// Merge provider backfill results into `otherEvents` on the main actor.
    func applyProviderBackfill(_ results: [(provider: ProviderID, dates: [Date])]) {
        var changed = false
        for r in results where r.provider != .claude && !r.dates.isEmpty {
            var seen = seenOtherDates[r.provider] ?? []
            var arr = otherEvents[r.provider] ?? []
            for d in r.dates where !seen.contains(d) {
                seen.insert(d)
                arr.append(d)
                changed = true
            }
            seenOtherDates[r.provider] = seen
            arr.sort()
            otherEvents[r.provider] = arr
        }
        prune()
        if changed { persist() }
    }

    /// Synchronous provider backfill (scan on the current thread). Kept for
    /// tests / callers already off the hot path.
    func backfillProviders(_ scanners: [ProviderActivityScanner]) {
        let cutoff = clock().addingTimeInterval(-windowSeconds)
        let results = scanners.filter { $0.provider != .claude }.map {
            (provider: $0.provider, dates: ProviderActivityBackfill.scan($0, cutoff: cutoff))
        }
        applyProviderBackfill(results)
    }

    /// Off-main provider backfill: scan on a background queue, apply on main.
    func backfillProvidersAsync(_ scanners: [ProviderActivityScanner]) async {
        let cutoff = clock().addingTimeInterval(-windowSeconds)
        let results = await OffMain.run {
            scanners.filter { $0.provider != .claude }.map {
                (provider: $0.provider, dates: ProviderActivityBackfill.scan($0, cutoff: cutoff))
            }
        }
        applyProviderBackfill(results)
    }

    /// Pure off-main scan of `~/.claude/projects` for in-window assistant
    /// events. No dedup here — `applyClaudeBackfill` dedups against `seenUUIDs`
    /// so it also catches events that streamed in via `record(_:)` between
    /// launch and scan completion. Runs inside `OffMain.run` (no actor state).
    /// Parses each `*.jsonl` line looking for `type == "assistant"` records
    /// with a usable `timestamp`, drops anything older than the window.
    nonisolated static func scanClaudeBackfill(root: URL, cutoff: Date) -> [ScannedEvent] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        guard let projectDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        var out: [ScannedEvent] = []
        for dir in projectDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let kids = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in kids where file.pathExtension == "jsonl" {
                // JSONL files in ~/.claude/projects are append-only — mtime
                // reflects the last appended event. A file whose mtime is older
                // than our cutoff cannot contain anything in-window, so skip the
                // read+parse entirely.
                if let mtime = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate, mtime < cutoff { continue }
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard let data = String(raw).data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          (obj["type"] as? String) == "assistant",
                          let uuid = obj["uuid"] as? String,
                          let tsString = obj["timestamp"] as? String,
                          let ts = iso.date(from: tsString),
                          ts >= cutoff
                    else { continue }
                    out.append(ScannedEvent(uuid: uuid, date: ts))
                }
            }
        }
        return out
    }

    /// Merge a Claude backfill scan into the store on the main actor: dedup by
    /// `uuid` (against both prior backfill rows and streamed `record(_:)` rows),
    /// then sort + prune.
    func applyClaudeBackfill(_ events: [ScannedEvent]) {
        var added = false
        for ev in events where !seenUUIDs.contains(ev.uuid) {
            seenUUIDs.insert(ev.uuid)
            eventTimestamps.append(ev.date)
            added = true
        }
        if added { eventTimestamps.sort() }
        prune()
    }

    /// Off-main Claude backfill: scan on a background queue, apply on main.
    func backfillAsync() async {
        let root = backfillRoot
        let cutoff = clock().addingTimeInterval(-windowSeconds)
        let events = await OffMain.run { ActivityHistorian.scanClaudeBackfill(root: root, cutoff: cutoff) }
        applyClaudeBackfill(events)
    }

    /// Number of recorded events whose timestamp falls inside the half-open
    /// interval `[bucketStart, bucketStart + bucketSize)`, for each contiguous
    /// bucket spanning `[windowStart, now]`. Returns one entry per bucket
    /// regardless of count (zero-count buckets are included) — the chart
    /// renderer decides which to draw based on the corresponding awake-mode.
    nonisolated func eventCounts(
        windowStart: Date,
        now: Date,
        bucketSize: TimeInterval,
        timestamps: [Date]
    ) -> [(start: Date, count: Int)] {
        guard windowStart < now, bucketSize > 0 else { return [] }
        var out: [(start: Date, count: Int)] = []
        var t = windowStart
        var i = timestamps.firstIndex { $0 >= windowStart } ?? timestamps.endIndex
        while t < now {
            let end = t.addingTimeInterval(bucketSize)
            var c = 0
            while i < timestamps.endIndex, timestamps[i] < end {
                c += 1
                i += 1
            }
            out.append((start: t, count: c))
            t = end
        }
        return out
    }

    /// Public read-only snapshot for the view layer.
    var timestamps: [Date] { eventTimestamps }

    private func prune() {
        let cutoff = clock().addingTimeInterval(-windowSeconds)
        if let firstIn = eventTimestamps.firstIndex(where: { $0 >= cutoff }), firstIn > 0 {
            eventTimestamps.removeFirst(firstIn)
        } else if let last = eventTimestamps.last, last < cutoff {
            eventTimestamps.removeAll()
            // seenUUIDs intentionally NOT cleared here — backfill seenUUIDs
            // still need to suppress the same uuid being re-emitted by
            // streaming. They drift larger forever, but at ~36 bytes each ×
            // typical event volume it stays well under 1 MB even after weeks.
        }

        // Prune each non-Claude provider's bucket to the same window.
        for (provider, arr) in otherEvents {
            if let firstIn = arr.firstIndex(where: { $0 >= cutoff }) {
                if firstIn > 0 { otherEvents[provider] = Array(arr[firstIn...]) }
            } else if !arr.isEmpty {
                otherEvents[provider] = []
            }
        }
        // Keep the dedup set bounded to the window — no intake path re-emits a
        // date that has aged out (offsets only advance; backfill is one-shot).
        for (provider, dates) in seenOtherDates {
            let kept = dates.filter { $0 >= cutoff }
            if kept.count != dates.count { seenOtherDates[provider] = kept }
        }
    }

    // MARK: - Persistence

    /// On-disk format for non-Claude provider history. Keyed on `ProviderID`'s
    /// raw value (String) so the JSON object stays human-readable and so
    /// unknown providers from a future build degrade silently to ignored
    /// entries on the older binary instead of failing the whole decode.
    private struct ActivityHistorianPersisted: Codable {
        let lastPersistedAt: Date
        let providerEvents: [String: [Date]]
    }

    private static func loadPersisted(
        from url: URL, cutoff: Date
    ) -> (events: [ProviderID: [Date]], seen: [ProviderID: Set<Date>]) {
        var events: [ProviderID: [Date]] = [:]
        var seen: [ProviderID: Set<Date>] = [:]
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return (events, seen)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(ActivityHistorianPersisted.self, from: data) else {
            return (events, seen)
        }
        // Strict rawValue match — ProviderID's default init folds unknown
        // values to `.claude`, which would corrupt Claude's store with
        // provider events from a future-build file. We only persist non-Claude
        // events, so any "claude" key here is a malformed file and gets
        // skipped along with unknown providers.
        let known: [String: ProviderID] = ["codex": .codex, "antigravity": .antigravity]
        for (rawProvider, dates) in payload.providerEvents {
            guard let provider = known[rawProvider] else { continue }
            let inWindow = dates.filter { $0 >= cutoff }
            guard !inWindow.isEmpty else { continue }
            events[provider] = inWindow.sorted()
            seen[provider] = Set(inWindow)
        }
        return (events, seen)
    }

    /// Synchronous atomic write — payload is a few KB JSON, main-thread cost
    /// is well under a ms. Matches `AwakeSessionLog.persist`. No-op when
    /// `persistURL == nil` (tests without disk).
    private func persist() {
        guard let url = persistURL else { return }
        let payload = ActivityHistorianPersisted(
            lastPersistedAt: clock(),
            providerEvents: Dictionary(
                uniqueKeysWithValues: otherEvents.map { ($0.key.rawValue, $0.value) }
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(payload)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.shared.log("ActivityHistorian persist failed: \(error)", level: .error)
        }
    }
}
