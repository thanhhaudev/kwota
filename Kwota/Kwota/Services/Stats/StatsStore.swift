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
    /// Hourly rollup keyed by "yyyy-MM-dd HH" (UTC), pruned to a recent window.
    /// Drives the Today view's by-hour chart; the daily `ledger` is kept forever.
    private(set) var hourly: StatsLedger
    /// Bumped on every merge so SwiftUI views observing the store re-render.
    private(set) var revision: Int = 0

    /// How far back hourly buckets are retained. Today's view only needs today;
    /// 48h keeps the window intact across the UTC midnight boundary.
    private static let hourlyRetention: TimeInterval = 48 * 3600

    private let readers: [ProviderID: JSONLogReader]
    private let ledgerURL: URL
    private let clock: () -> Date
    /// Calendar/timezone for the hourly rollup + "today" key. Defaults to the
    /// viewer's LOCAL calendar so the Today by-hour chart reads in their own
    /// time (the daily ledger stays UTC). Injected as UTC in tests for
    /// determinism.
    private let calendar: Calendar
    private let persistDebounce: TimeInterval
    private let persistQueue = DispatchQueue(label: "com.thanhhaudev.kwota.stats-persist", qos: .utility)
    private var pendingPersist: DispatchWorkItem?

    // MARK: Read serialization

    /// True while a `readChanged` session is in progress off-main.
    /// Re-entrant calls coalesce into the per-provider pending state below
    /// instead of racing on a reader's mutable offsets. Each provider keeps
    /// its own pending request so no provider's signal is dropped while
    /// another provider's read is in flight.
    private var isReading = false
    private struct Pending { var fullWalk = false; var paths: Set<URL> = [] }
    private var pending: [ProviderID: Pending] = [:]

    init(readers: [ProviderID: JSONLogReader],
         ledgerURL: URL = StatsStore.defaultLedgerURL(),
         clock: @escaping () -> Date = { Date() },
         calendar: Calendar = .current,
         persistDebounce: TimeInterval = 1.0) {
        self.readers = readers
        self.ledgerURL = ledgerURL
        self.clock = clock
        self.calendar = calendar
        self.persistDebounce = persistDebounce
        let (loaded, loadedHourly, states) = Self.loadEnvelope(at: ledgerURL)
        self.ledger = loaded
        self.hourly = loadedHourly
        for (provider, reader) in readers {
            reader.restore(states[provider] ?? ReaderState())
        }
    }

    /// Back-compat convenience used by existing call sites and tests.
    convenience init(reader: JSONLogReader,
                     ledgerURL: URL = StatsStore.defaultLedgerURL(),
                     clock: @escaping () -> Date = { Date() },
                     calendar: Calendar = .current,
                     persistDebounce: TimeInterval = 1.0) {
        self.init(readers: [.claude: reader], ledgerURL: ledgerURL,
                  clock: clock, calendar: calendar, persistDebounce: persistDebounce)
    }

    nonisolated static func defaultLedgerURL() -> URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("stats-ledger.json")
    }

    // MARK: Ingest

    /// Read the changed paths (nil = full walk) with this store's own offsets
    /// and merge whatever events come back. Reuses `UsageMonitor`'s FSEvents
    /// signal but keeps independent offsets so backfill/incremental is correct.
    ///
    /// Reads are serialized via `isReading` — `read()` mutates a reader's
    /// per-file offsets, so two concurrent walks would race. A call that
    /// arrives mid-read is COALESCED into the per-provider `pending` map; the
    /// in-flight loop drains that deferred state to drive the next iteration.
    /// Within a provider, a nil (full-walk) request supersedes any pending
    /// paths; a later path request is subsumed by a pending full walk. Each
    /// provider keeps an independent pending entry, so a signal for one
    /// provider is never lost while another provider's read is in flight.
    func readChanged(_ paths: Set<URL>?, provider: ProviderID) async {
        guard readers[provider] != nil else { return }
        if isReading {
            var p = pending[provider] ?? Pending()
            if paths == nil { p.fullWalk = true; p.paths.removeAll() }
            else if !p.fullWalk { p.paths.formUnion(paths!) }
            pending[provider] = p
            return
        }
        isReading = true
        defer { isReading = false }
        var curProvider = provider
        var curPaths = paths
        while true {
            guard let reader = readers[curProvider] else { return }
            let req = curPaths
            let events: [UsageEvent] = await OffMain.run {
                if let req { return reader.read(only: req) }
                return reader.read()
            }
            ingest(events, provider: curProvider)
            // Drain order across providers is unordered (Dictionary.first), which
            // is safe: each provider has independent offsets, so order can't
            // affect totals. Don't "fix" this into ordered iteration — it would
            // add churn for no correctness gain.
            guard let (nextProvider, p) = pending.first else { return }
            pending.removeValue(forKey: nextProvider)
            curProvider = nextProvider
            curPaths = p.fullWalk ? nil : p.paths
        }
    }

    /// Merge already-read events into the rollup. Pure/synchronous.
    func ingest(_ events: [UsageEvent], provider: ProviderID) {
        guard !events.isEmpty else { return }
        let now = clock()
        let hourCutoffDate = now.addingTimeInterval(-Self.hourlyRetention)
        for e in events {
            let model = e.model ?? "unknown"
            let day = ledger.dayKey(for: e.timestamp)
            ledger.merge(provider: provider, day: day, model: model, delta: e.tokens, now: now)
            // Hourly only tracks the recent window — skip old backfill events so
            // we don't churn buckets that prune would immediately drop.
            if e.timestamp >= hourCutoffDate {
                hourly.merge(provider: provider, day: ledger.hourKey(for: e.timestamp, calendar: calendar),
                             model: model, delta: e.tokens, now: now)
            }
        }
        hourly.prune(beforeKey: ledger.hourKey(for: hourCutoffDate, calendar: calendar))
        revision &+= 1
        schedulePersist()
    }

    /// Wipe one provider's rollup (user-triggered). Reader offsets are kept, so
    /// cleared history is NOT re-ingested — counting resumes from new activity.
    func clear(provider: ProviderID) {
        let now = clock()
        ledger.clear(provider: provider, now: now)
        hourly.clear(provider: provider, now: now)
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
    /// Hour-of-day (0–23) buckets for `dayKey` ("yyyy-MM-dd", UTC), ascending.
    /// Drives the Today by-hour chart. Empty once the day ages out of the
    /// hourly retention window.
    func hourlySeries(provider: ProviderID, dayKey: String) -> [(hour: Int, byModel: [String: TokenBreakdown])] {
        hourly.dailySeries(provider: provider, sinceDay: nil)
            .compactMap { entry in
                guard entry.day.hasPrefix(dayKey + " "),
                      let hour = Int(entry.day.suffix(2)) else { return nil }
                return (hour: hour, byModel: entry.byModel)
            }
            .sorted { $0.hour < $1.hour }
    }
    /// Today's "yyyy-MM-dd" key in the store's (local) calendar — the day the
    /// hourly buckets are filed under, for the Today by-hour chart.
    func currentDayKey() -> String {
        ledger.dayKey(for: clock(), calendar: calendar)
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
        /// Legacy single-reader (Claude) offsets from Plan 1. Still written so an
        /// older binary can downgrade without re-backfilling Claude.
        var readerState: ReaderState?
        /// Per-provider offsets, keyed by `ProviderID.rawValue`. Preferred on load.
        var readerStates: [String: ReaderState]?
        /// Optional so envelopes written before the hourly rollup decode cleanly
        /// (they simply start with an empty hourly window).
        var hourly: StatsLedger?
    }

    private func makeEnvelope() -> Envelope {
        // Snapshot each reader's offsets ONCE — `state()` does a fileExists scan
        // per tracked file, so the legacy `readerState` reuses Claude's already-
        // computed snapshot rather than scanning a second time.
        var states: [String: ReaderState] = [:]
        for (provider, reader) in readers { states[provider.rawValue] = reader.state() }
        return Envelope(ledger: ledger,
                        readerState: states[ProviderID.claude.rawValue],
                        readerStates: states,
                        hourly: hourly)
    }

    private func schedulePersist() {
        pendingPersist?.cancel()
        let snapshot = makeEnvelope()
        let url = ledgerURL
        let action = { Self.write(snapshot, to: url) }
        if persistDebounce <= 0 { persistQueue.async(execute: action); return }
        let item = DispatchWorkItem(block: action)
        pendingPersist = item
        persistQueue.asyncAfter(deadline: .now() + persistDebounce, execute: item)
    }

    /// Synchronously flush any pending persist to disk. Called on clean exit
    /// (via MenuBarViewModel teardown) so the last ingest is never silently
    /// dropped within the debounce window. Also used by tests for deterministic
    /// ordering.
    func flush() {
        pendingPersist?.cancel()
        let snapshot = makeEnvelope()
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

    nonisolated private static func loadEnvelope(at url: URL)
        -> (StatsLedger, StatsLedger, [ProviderID: ReaderState]) {
        guard let data = try? Data(contentsOf: url),
              let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return (StatsLedger(), StatsLedger(), [:])
        }
        var states: [ProviderID: ReaderState] = [:]
        if let perProvider = env.readerStates {
            for (raw, st) in perProvider { states[ProviderID(rawValue: raw)] = st }
        } else if let legacy = env.readerState {
            states[.claude] = legacy   // Plan 1 envelope → Claude offsets
        }
        return (env.ledger, env.hourly ?? StatsLedger(), states)
    }
}
