//
//  StatsStore.swift
//  Kwota
//

import Foundation
import Observation

/// Owns the persisted token-usage rollup (`StatsLedger`) and the independent
/// reader offsets used to tail provider logs. Separate from `UsageMonitor`'s
/// `UsageLedger` so the stable envelope-v3 persist path is untouched.
///
/// Claude ingest path: `StatsStore` keeps its OWN `JSONLogReader` with its own
/// persisted offsets. First launch (empty offsets) reads `~/.claude` history
/// from offset 0 — that is the backfill. Subsequent ticks read only newly
/// appended bytes, so events are never double-counted and dedup needs no
/// `seenUUIDs`. `MenuBarViewModel` drives `readChanged(_:)` from the
/// `UsageMonitor.onChangedPaths` hook, reusing the existing FSEvents pipeline.
@MainActor
@Observable
final class StatsStore {
    private(set) var ledger: StatsLedger
    /// Bumped on every merge so SwiftUI views observing the store re-render.
    private(set) var revision: Int = 0

    private let reader: JSONLogReader
    private let ledgerURL: URL
    private let clock: () -> Date
    private let pruneDays: Int

    private let persistDebounce: TimeInterval
    private let persistQueue = DispatchQueue(label: "com.thanhhaudev.kwota.stats-persist", qos: .utility)
    private var pendingPersist: DispatchWorkItem?

    init(reader: JSONLogReader,
         ledgerURL: URL = StatsStore.defaultLedgerURL(),
         clock: @escaping () -> Date = { Date() },
         pruneDays: Int = 90,
         persistDebounce: TimeInterval = 1.0) {
        self.reader = reader
        self.ledgerURL = ledgerURL
        self.clock = clock
        self.pruneDays = pruneDays
        self.persistDebounce = persistDebounce
        let (loaded, readerState) = Self.loadEnvelope(at: ledgerURL)
        self.ledger = loaded
        reader.restore(readerState)
    }

    nonisolated static func defaultLedgerURL() -> URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("stats-ledger.json")
    }

    // MARK: Ingest

    /// Read the changed paths (nil = full walk) with this store's own offsets
    /// and merge whatever events come back. Reuses `UsageMonitor`'s FSEvents
    /// signal but keeps independent offsets so backfill/incremental is correct.
    func readChanged(_ paths: Set<URL>?, provider: ProviderID) async {
        let events: [UsageEvent] = await OffMain.run { [reader] in
            if let paths { return reader.read(only: paths) }
            return reader.read()
        }
        ingest(events, provider: provider)
    }

    /// Merge already-read events into the rollup. Pure/synchronous.
    func ingest(_ events: [UsageEvent], provider: ProviderID) {
        guard !events.isEmpty else { return }
        let now = clock()
        for e in events {
            let day = ledger.dayKey(for: e.timestamp)
            ledger.merge(provider: provider, day: day, model: e.model ?? "unknown", delta: e.tokens, now: now)
        }
        ledger.prune(olderThan: pruneDays, now: now)
        revision &+= 1
        schedulePersist()
    }

    // MARK: Queries

    func total(provider: ProviderID, sinceDay: String?) -> TokenBreakdown {
        ledger.total(provider: provider, sinceDay: sinceDay)
    }
    func totalsByModel(provider: ProviderID, sinceDay: String?) -> [String: TokenBreakdown] {
        ledger.totalsByModel(provider: provider, sinceDay: sinceDay)
    }
    func dailySeries(provider: ProviderID, sinceDay: String?) -> [(day: String, byModel: [String: TokenBreakdown])] {
        ledger.dailySeries(provider: provider, sinceDay: sinceDay)
    }
    /// "yyyy-MM-dd" key for `daysAgo` days before now, UTC. nil for "All".
    func sinceDayKey(daysAgo: Int?) -> String? {
        guard let daysAgo else { return nil }
        let cal = StatsLedger.utcCalendarForKeys
        let day = cal.date(byAdding: .day, value: -daysAgo, to: clock()) ?? clock()
        return ledger.dayKey(for: day)
    }

    // MARK: Persistence

    /// On-disk shape: rollup + reader offsets in one blob, so a restart resumes
    /// tailing where it left off.
    private struct Envelope: Codable {
        var ledger: StatsLedger
        var readerState: ReaderState
    }

    private func schedulePersist() {
        pendingPersist?.cancel()
        let snapshot = Envelope(ledger: ledger, readerState: reader.state())
        let url = ledgerURL
        let action = { Self.write(snapshot, to: url) }
        if persistDebounce <= 0 { persistQueue.async(execute: action); return }
        let item = DispatchWorkItem(block: action)
        pendingPersist = item
        persistQueue.asyncAfter(deadline: .now() + persistDebounce, execute: item)
    }

    /// Test seam: run any pending write synchronously now.
    func flushPersistForTesting() {
        pendingPersist?.cancel()
        let snapshot = Envelope(ledger: ledger, readerState: reader.state())
        persistQueue.sync { Self.write(snapshot, to: self.ledgerURL) }
    }

    nonisolated private static func write(_ env: Envelope, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(env)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.shared.log("StatsStore persist failed: \(error)", level: .warn)
        }
    }

    nonisolated private static func loadEnvelope(at url: URL) -> (StatsLedger, ReaderState) {
        guard let data = try? Data(contentsOf: url),
              let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return (StatsLedger(), ReaderState())
        }
        return (env.ledger, env.readerState)
    }
}
