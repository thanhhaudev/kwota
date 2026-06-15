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
    private struct Pending { var fullWalk = false; var paths: Set<URL> = []; var gen = 0 }
    private var pending: [ProviderID: Pending] = [:]

    /// Per-provider generation counter, bumped by `clear(provider:)`. A read
    /// captures the generation before it suspends off-main and drops its batch
    /// if `clear` bumped it meanwhile — otherwise an in-flight read (e.g. the
    /// startup backfill) would re-ingest just-cleared history after the wipe.
    private var generation: [ProviderID: Int] = [:]

    /// Wall-clock time of the last `clear(provider:)`, persisted in the envelope.
    /// Two roles, both keyed on this instant: (1) when a Clear races an in-flight
    /// read, the dropped batch is split here (events at/after it are kept); (2)
    /// `ingest` drops anything older than it, so a Clear survives even a quit
    /// during a backfill — the next launch re-reads the wiped history but filters
    /// it out instead of repopulating the ledger.
    private var clearTime: [ProviderID: Date] = [:]

    /// Cached cursor snapshot per provider, refreshed only at the safe point
    /// right after a read completes (no read is then concurrent). `clear`,
    /// `flush`, and `schedulePersist` build the envelope from THIS cache, so
    /// `reader.state()` is never called on the main actor while `reader.read()`
    /// mutates the same offset dictionaries off-main — which would be a data
    /// race on those (unlocked) dictionaries.
    private var lastReaderStates: [ProviderID: ReaderState] = [:]

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
        let (loaded, loadedHourly, states, cleared) = Self.loadEnvelope(at: ledgerURL)
        self.ledger = loaded
        self.hourly = loadedHourly
        self.clearTime = cleared
        for (provider, reader) in readers {
            let restored = states[provider] ?? ReaderState()
            reader.restore(restored)
            lastReaderStates[provider] = restored
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
            // Stamp the generation when the pending entry is first created so a
            // clear AFTER enqueue but BEFORE the read drains is caught by the
            // post-read guard. Keep the earliest (pre-clear) gen on coalesce.
            var p = pending[provider] ?? Pending(gen: generation[provider] ?? 0)
            if paths == nil { p.fullWalk = true; p.paths.removeAll() }
            else if !p.fullWalk { p.paths.formUnion(paths!) }
            pending[provider] = p
            return
        }
        isReading = true
        defer { isReading = false }
        var curProvider = provider
        var curPaths = paths
        // The initial (non-pending) request's generation, captured at entry; no
        // `await` happens before the loop body, so this matches today's behavior.
        var curGen = generation[curProvider] ?? 0
        while true {
            guard let reader = readers[curProvider] else { return }
            let req = curPaths
            let gen = curGen
            let events: [UsageEvent] = await OffMain.run {
                if let req { return reader.read(only: req) }
                return reader.read()
            }
            // Safe point: the read has completed and the next one hasn't begun,
            // so reading the reader's cursors here can't race `read()`. Refresh
            // the cache that clear/flush/persist snapshot from.
            lastReaderStates[curProvider] = reader.state()
            // If `clear(provider:)` ran while we were suspended off-main, the
            // batch we just read is pre-clear history — dropping it (the reader
            // already advanced past it) is what makes Clear stick. Without this,
            // a Clear during the startup backfill would be silently undone.
            if (generation[curProvider] ?? 0) == gen {
                ingest(events, provider: curProvider)
            } else {
                // Cleared mid-read. The batch is pre-clear history being wiped —
                // EXCEPT any events that arrived after the clear (timestamp >=
                // clearTime) and got swept into this same batch; dropping those
                // would permanently lose post-clear activity. Keep them, drop the
                // rest. The cursor advanced either way, so the wiped history isn't
                // re-read (and re-counted) on next launch.
                let cutoff = clearTime[curProvider]
                let postClear = cutoff.map { c in events.filter { $0.timestamp >= c } } ?? []
                if postClear.isEmpty {
                    schedulePersist()
                } else {
                    ingest(postClear, provider: curProvider)   // ingest() persists
                }
            }
            // Drain order across providers is unordered (Dictionary.first), which
            // is safe: each provider has independent offsets, so order can't
            // affect totals. Don't "fix" this into ordered iteration — it would
            // add churn for no correctness gain.
            guard let (nextProvider, p) = pending.first else { return }
            pending.removeValue(forKey: nextProvider)
            curProvider = nextProvider
            curPaths = p.fullWalk ? nil : p.paths
            curGen = p.gen
        }
    }

    /// Merge already-read events into the rollup. Pure/synchronous.
    func ingest(_ events: [UsageEvent], provider: ProviderID) {
        guard !events.isEmpty else { return }
        let now = clock()
        let hourCutoffDate = now.addingTimeInterval(-Self.hourlyRetention)
        // Drop anything older than the Clear watermark. This is what makes a
        // Clear stick across a quit-during-backfill: on the next launch the
        // backfill re-reads the wiped history (the cursor was never advanced),
        // and these events are filtered here instead of repopulating the ledger.
        let clearedBefore = clearTime[provider]
        for e in events {
            if let clearedBefore, e.timestamp < clearedBefore { continue }
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
        // Invalidate any in-flight read for this provider so it can't re-ingest
        // the history we just wiped after it resumes from off-main.
        generation[provider, default: 0] += 1
        clearTime[provider] = now
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

    /// "yyyy-MM-dd" → (year, month, day). Local to the store so it doesn't
    /// depend on the view layer's parser.
    private static func parseDay(_ key: String) -> (Int, Int, Int)? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return (p[0], p[1], p[2])
    }

    /// Per-day series for the chart, padded so every UTC day in the range's
    /// window is present (empty `byModel` for days with no usage). Window:
    ///   daysAgo != nil → [today-daysAgo … today]   (week=7 days, month=30)
    ///   daysAgo == nil → [earliest ledger day … today]  (all time; empty → today only)
    /// Ascending by day key. Drives the chart's bars, x-axis span, and the
    /// per-day average (denominator = window day count). Days are generated with
    /// the UTC keys calendar so they match stored ledger keys exactly.
    func paddedDailySeries(provider: ProviderID, daysAgo: Int?)
        -> [(day: String, byModel: [String: TokenBreakdown])] {
        let cal = StatsLedger.utcCalendarForKeys
        let now = clock()
        let data = Dictionary(uniqueKeysWithValues:
            ledger.dailySeries(provider: provider, sinceDay: nil).map { ($0.day, $0.byModel) })

        let startDate: Date
        if let daysAgo {
            startDate = cal.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        } else if let earliest = data.keys.min(),
                  let (y, m, d) = Self.parseDay(earliest),
                  let date = cal.date(from: DateComponents(year: y, month: m, day: d)) {
            startDate = date
        } else {
            startDate = now   // empty ledger → today only
        }

        var out: [(day: String, byModel: [String: TokenBreakdown])] = []
        var cursor = cal.startOfDay(for: startDate)
        let end = cal.startOfDay(for: now)
        var guardCount = 0
        while cursor <= end, guardCount < 4000 {   // bound: pathological earliest-key can't spin forever
            let key = ledger.dayKey(for: cursor)
            out.append((day: key, byModel: data[key] ?? [:]))
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
            guardCount += 1
        }
        return out
    }

    /// The chart series at an adaptive granularity. Starts from the padded daily
    /// series (full window, gap days filled), picks a granularity from the
    /// window's day-span, and — for week/month/year — sums each model's tokens
    /// into buckets keyed by the bucket's START day ("yyyy-MM-dd", UTC), keeping
    /// empty buckets. `.day` returns the padded daily series unchanged. Ascending.
    func chartSeries(provider: ProviderID, daysAgo: Int?)
        -> (granularity: StatsGranularity, points: [(day: String, byModel: [String: TokenBreakdown])]) {
        let daily = paddedDailySeries(provider: provider, daysAgo: daysAgo)
        let gran = StatsGranularity.forSpan(days: daily.count)
        guard gran != .day else { return (.day, daily) }

        let cal = StatsLedger.utcCalendarForKeys
        var order: [String] = []
        var buckets: [String: [String: TokenBreakdown]] = [:]
        for entry in daily {
            guard let (y, m, d) = Self.parseDay(entry.day),
                  let date = cal.date(from: DateComponents(year: y, month: m, day: d)) else { continue }
            let start = cal.dateInterval(of: gran.component, for: date)?.start ?? date
            let key = ledger.dayKey(for: start)
            if buckets[key] == nil { buckets[key] = [:]; order.append(key) }   // keep empty buckets
            for (model, tok) in entry.byModel {
                buckets[key]![model] = (buckets[key]![model] ?? .zero) + tok
            }
        }
        return (gran, order.map { (day: $0, byModel: buckets[$0] ?? [:]) })
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
        /// Per-provider Clear watermark, keyed by `ProviderID.rawValue`. Events
        /// older than this are dropped on ingest so a Clear survives even if the
        /// app quits while a backfill is still in flight (the cursor would then
        /// be stale on disk and re-read the wiped history next launch).
        var clearedAt: [String: Date]?
    }

    private func makeEnvelope() -> Envelope {
        // Build from the cached cursor snapshots (refreshed at the safe post-read
        // point), NOT live `reader.state()` — this runs from clear/flush/persist
        // on the main actor, possibly while a read mutates the reader's offsets
        // off-main, so touching the reader here would be a data race.
        var states: [String: ReaderState] = [:]
        for (provider, snapshot) in lastReaderStates { states[provider.rawValue] = snapshot }
        var cleared: [String: Date] = [:]
        for (provider, date) in clearTime { cleared[provider.rawValue] = date }
        return Envelope(ledger: ledger,
                        readerState: states[ProviderID.claude.rawValue],
                        readerStates: states,
                        hourly: hourly,
                        clearedAt: cleared.isEmpty ? nil : cleared)
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
        -> (StatsLedger, StatsLedger, [ProviderID: ReaderState], [ProviderID: Date]) {
        guard let data = try? Data(contentsOf: url),
              let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return (StatsLedger(), StatsLedger(), [:], [:])
        }
        var states: [ProviderID: ReaderState] = [:]
        if let perProvider = env.readerStates {
            for (raw, st) in perProvider { states[ProviderID(rawValue: raw)] = st }
        } else if let legacy = env.readerState {
            states[.claude] = legacy   // Plan 1 envelope → Claude offsets
        }
        var cleared: [ProviderID: Date] = [:]
        for (raw, date) in env.clearedAt ?? [:] { cleared[ProviderID(rawValue: raw)] = date }
        return (env.ledger, env.hourly ?? StatsLedger(), states, cleared)
    }
}
