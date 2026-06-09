//
//  UsageMonitor.swift
//  Kwota
//

import Foundation
import Combine

@MainActor
final class UsageMonitor: ObservableObject {
    struct Ownership: Equatable {
        let profileId: UUID
        let boundary: Date
    }

    struct DailyCounterState: Codable, Equatable {
        let profileId: UUID
        let dayKey: String          // "yyyy-MM-dd" in UTC, matches UsageLedger.dayKey
        let count: Int
        /// Generation marker tying this counter to a specific ledger state.
        /// On restore the counter is discarded unless `ledger.lastUpdate`
        /// equals the value persisted here. Without this coupling, a
        /// corrupted/missing ledger would let a stale counter be combined
        /// with a JSONL replay and double-count today's usage.
        ///
        /// Known partial-persist limitation: a crash or counter-write
        /// failure AFTER `persistLedger` succeeds but BEFORE
        /// `persistDailyCounterState` lands leaves the on-disk pair with
        /// a newer ledger and a stale counter. On next launch the restore
        /// predicate rejects the counter (correct), but the ledger has
        /// already deduped today's UUIDs so JSONL replay produces no new
        /// events and the counter sits at 0 until UTC midnight. Accepted:
        /// `dailyTokens` has no production view consumer today (only the
        /// debug-tier `dailyTokensDisplay`), the trigger window is the
        /// microsecond gap between two sequential synchronous writes on
        /// the same MainActor tick, and the failure self-heals at the
        /// next day rollover. If a future view starts displaying daily
        /// totals derived from this counter, switch to atomic single-file
        /// persistence (combine into UsageLedger with schema bump).
        let ledgerLastUpdate: Date

        private enum CodingKeys: String, CodingKey {
            case profileId, dayKey, count, ledgerLastUpdate
        }

        init(profileId: UUID, dayKey: String, count: Int, ledgerLastUpdate: Date) {
            self.profileId = profileId
            self.dayKey = dayKey
            self.count = count
            self.ledgerLastUpdate = ledgerLastUpdate
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.profileId = try c.decode(UUID.self, forKey: .profileId)
            self.dayKey = try c.decode(String.self, forKey: .dayKey)
            self.count = try c.decode(Int.self, forKey: .count)
            // Default to distantPast when missing so old-format files are
            // treated as stale and discarded by the restore predicate. That
            // forfeits one day's worth of daily-counter accuracy on upgrade,
            // which is acceptable for a debug-tier value.
            self.ledgerLastUpdate = try c.decodeIfPresent(Date.self, forKey: .ledgerLastUpdate) ?? .distantPast
        }
    }

    /// On-disk wrapping format. schemaVersion 3 introduced the envelope shape
    /// (ledger + reader cursor). schemaVersion 2 files are pre-envelope (just
    /// a UsageLedger directly serialized at the top level) and migrated on
    /// load — see `loadEnvelope`.
    private struct PersistedLedgerEnvelope: Codable {
        var schemaVersion: Int
        var ledger: UsageLedger
        var readerState: ReaderState
    }

    var ownership: Ownership? {
        didSet {
            guard oldValue?.profileId != ownership?.profileId else { return }
            sessionSinceLaunch = .zero
            restoreOrResetDailyCounter()
            publishFromLedger()
        }
    }

    @Published private(set) var sessionTokens: Int = 0
    @Published private(set) var dailyTokens: Int = 0
    @Published private(set) var remainingPercent: Int = 100
    @Published private(set) var lastEvents: [UsageEvent] = []   // latest 20 for debug panel
    @Published private(set) var lastTickAt: Date?

    /// Optional sink for newly-ingested events. `UsageMonitor` owns deduping
    /// via `UsageLedger`, so callbacks only see events the ledger considered
    /// genuinely new on this tick — safe to feed into a downstream historian
    /// without re-dedup logic. Set after `init`; cleared on `stop()` is the
    /// caller's responsibility.
    var onNewEvents: (([UsageEvent]) -> Void)?

    let reader: JSONLogReader   // intentionally non-private: DebugPanelView reads `lastSeenLine()`
    private let ledgerURL: URL
    private let dailyCounterURL: URL
    private let appLaunchInstant: Date
    private let clock: () -> Date
    /// v1 jsonl-derived shim only. Hardcoded estimate; does not reflect real plan tier limits (Pro/Max/Team). MenuBarView V2 path computes percent from server-side anthropic-ratelimit-* headers instead.
    private let legacyDailyQuotaEstimate: Int

    private var ledger: UsageLedger
    private var sessionSinceLaunch: TokenBreakdown = .zero
    /// Per-ownership daily counter. Resets when the ownership profile id
    /// changes or when the UTC day rolls over. Source-of-truth for the
    /// debug-tier `dailyTokens` publish — the ledger aggregate cannot
    /// answer "tokens since boundary" precisely once the boundary is
    /// intra-day, so we maintain this counter alongside.
    private var dailyBillableSinceOwnership: Int = 0
    private var dailyCounterDayKey: String?
    private var timer: Timer?
    private var listenTask: Task<Void, Never>?
    /// Serializes `tickAsync` reads (see `tickAsync`). `@MainActor` state, only
    /// touched on the main actor at the suspension-free head of `tickAsync`.
    private var isReading = false
    private var readAgain = false

    /// Serial background queue for `persistLedger`/`persistDailyCounterState`.
    /// Separate from `readQueue` so a long write can't block the read path and
    /// vice versa. Background QoS so it never preempts UI work.
    private let persistQueue = DispatchQueue(
        label: "com.thanhhaudev.kwota.usage-persist",
        qos: .utility
    )
    /// Trailing-debounce work items. Cancelled + rescheduled on every dirty
    /// notification; fire on `persistQueue` after `persistDebounce` seconds.
    /// The matching `pending…Action` closure captures the snapshot at
    /// scheduling time so `flushPersistForTesting()` can re-run the write
    /// after cancellation (a cancelled `DispatchWorkItem.perform()` is a
    /// no-op, so the closure has to live outside the work item).
    private var pendingLedgerPersist: DispatchWorkItem?
    private var pendingLedgerAction: (() -> Void)?
    private var pendingCounterPersist: DispatchWorkItem?
    private var pendingCounterAction: (() -> Void)?
    /// Debounce window. Production default 1.0s; tests inject longer windows
    /// plus `flushPersistForTesting()` for deterministic ordering.
    private let persistDebounce: TimeInterval
    /// Optional hook fired on `persistQueue` after a successful ledger write.
    /// Used by tests to count writes; nil in production.
    private let persistDidWriteForTesting: (() -> Void)?

    /// Yields once per batch of writes under `~/.claude/projects`. Production
    /// gets a real FSEvents stream via `UsageMonitor.live()`; the default is
    /// inert so unit tests (which inject a fake reader and drive `tick()`
    /// directly) never spin up a real watcher on the host's `~/.claude`.
    private let fileEvents: AsyncStream<Void>
    /// Backstop poll. FSEvents drives ingestion the instant Claude writes, but
    /// a slow timer still runs to (a) catch any coalesced/missed event and
    /// (b) roll the daily counter over at UTC midnight on a quiet day with no
    /// file writes. 60s, not the old 5s, because the event stream — not the
    /// timer — is now the primary trigger.
    private let safetyPollInterval: TimeInterval

    init(
        reader: JSONLogReader = FilesystemJSONLogReader(),
        ledgerURL: URL = UsageMonitor.defaultLedgerURL(),
        dailyCounterURL: URL = UsageMonitor.defaultDailyCounterURL(),
        appLaunchInstant: Date = Date(),
        clock: @escaping () -> Date = { Date() },
        fileEvents: AsyncStream<Void> = AsyncStream { _ in },
        safetyPollInterval: TimeInterval = 60,
        legacyDailyQuotaEstimate: Int = 1_000_000,
        persistDebounce: TimeInterval = 1.0,
        persistDidWriteForTesting: (() -> Void)? = nil
    ) {
        self.reader = reader
        self.ledgerURL = ledgerURL
        self.dailyCounterURL = dailyCounterURL
        self.appLaunchInstant = appLaunchInstant
        self.clock = clock
        self.fileEvents = fileEvents
        self.safetyPollInterval = safetyPollInterval
        self.legacyDailyQuotaEstimate = legacyDailyQuotaEstimate
        self.persistDebounce = persistDebounce
        self.persistDidWriteForTesting = persistDidWriteForTesting
        let (loadedLedger, loadedReaderState) = Self.loadEnvelope(at: ledgerURL)
        self.ledger = loadedLedger
        reader.restore(loadedReaderState)
        publishFromLedger()
    }

    /// Production wiring: a real filesystem reader plus an FSEvents stream over
    /// `~/.claude/projects`, so ingestion is event-driven instead of polled.
    static func live() -> UsageMonitor {
        UsageMonitor(fileEvents: UsageMonitor.defaultFileEvents())
    }

    func start() {
        stop()
        // Primary trigger: tick whenever the projects tree changes. FSEvents
        // can fire many times per second while Claude is actively writing, so
        // this path uses `tickAsync` to keep the directory walk off the main
        // thread (a synchronous `read()` here re-enumerated the whole
        // `~/.claude/projects` tree on main and stalled the UI).
        listenTask = Task { @MainActor [weak self, fileEvents] in
            for await _ in fileEvents { await self?.tickAsync() }
        }
        // Backstop + daily-counter rollover, see `safetyPollInterval`.
        let t = Timer(timeInterval: safetyPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tickAsync() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Immediate first read — also off the main thread. This is the
        // heaviest read of the session (every file is walked from offset 0,
        // the whole `~/.claude/projects` history), so doing it synchronously
        // here blocked `MenuBarViewModel.init` and stalled app launch.
        Task { @MainActor [weak self] in await self?.tickAsync() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        listenTask?.cancel()
        listenTask = nil
        flushPendingPersist()
    }

    deinit {
        // Timer.invalidate is documented thread-safe; safe from nonisolated deinit.
        timer?.invalidate()
        listenTask?.cancel()
    }

    /// Synchronous read + ingest. Used for the one-time startup read and by
    /// tests; production change-driven ticks go through `tickAsync`.
    func tick() {
        ingest(reader.read())
    }

    /// Serial background queue for the (synchronous, blocking) `reader.read()`
    /// walk. A `Task.detached` whose closure has no suspension point runs
    /// inline on the calling thread — i.e. the main actor — so it does NOT
    /// move the walk off main; bridging through a real `DispatchQueue`
    /// guarantees it. The queue's seriality also backstops the `isReading`
    /// guard against overlapping reads racing on the reader's offsets.
    /// Per-instance (not static): one monitor's long real-filesystem read must
    /// never serialize behind/ahead of another's — that coupled unrelated
    /// instances and starved parallel tests sharing the process.
    private let readQueue = DispatchQueue(label: "com.thanhhaudev.kwota.usage-read", qos: .utility)

    /// Production tick path: runs the (heavy, frequent) filesystem walk off the
    /// main thread, then ingests on the main actor. Reads are serialized via
    /// `isReading` — `read()` mutates the reader's per-file offsets, so two
    /// concurrent walks would race; a tick that arrives mid-read sets
    /// `readAgain` so the in-flight read re-runs once to catch the new data.
    func tickAsync() async {
        if isReading { readAgain = true; return }
        isReading = true
        defer { isReading = false }
        repeat {
            readAgain = false
            let events = await withCheckedContinuation { (cont: CheckedContinuation<[UsageEvent], Never>) in
                readQueue.async { [reader] in
                    cont.resume(returning: reader.read())
                }
            }
            ingest(events)
        } while readAgain
    }

    private func ingest(_ events: [UsageEvent]) {
        let now = clock()
        lastTickAt = now

        let currentDayKey = ledger.dayKey(for: now)
        if currentDayKey != dailyCounterDayKey {
            dailyBillableSinceOwnership = 0
            dailyCounterDayKey = currentDayKey
        }

        let scoped: [UsageEvent]
        if let ownership {
            scoped = events.filter { $0.timestamp >= ownership.boundary }
        } else {
            scoped = []
        }
        let newEvents = ledger.ingest(events: scoped, now: now)
        for ev in newEvents where ev.timestamp >= appLaunchInstant {
            sessionSinceLaunch = sessionSinceLaunch + ev.tokens
        }
        for ev in newEvents where ledger.dayKey(for: ev.timestamp) == currentDayKey {
            dailyBillableSinceOwnership += ev.tokens.billable
        }
        ledger.prune(olderThan: 7, now: now)
        persistLedger()
        persistDailyCounterState()
        if !newEvents.isEmpty {
            lastEvents = (lastEvents + newEvents).suffix(20)
            onNewEvents?(newEvents)
        }
        publishFromLedger()
    }

    nonisolated static func defaultLedgerURL() -> URL {
        // Routes through `AppPaths` so the ledger lives next to the rest of
        // the app's on-disk state under `~/Library/Application Support/
        // com.thanhhaudev.Kwota/`. Pre-fix builds wrote to `…/Kwota/
        // ledger.json` (a sibling, bundle-id-mismatched directory); that
        // file is left orphaned — MVP, single-user dev, ledger rebuilds on
        // first launch from the JSONL log, no migration code shipped.
        AppPaths.applicationSupportDirectory.appendingPathComponent("ledger.json")
    }

    nonisolated static func defaultDailyCounterURL() -> URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("usage-monitor-daily.json")
    }

    /// FSEvents stream over `~/.claude/projects`, file-level. Yields once per
    /// batch of writes under the tree (0.5s coalescing). Same idiom as
    /// `CodexActivitySource.defaultFileEvents`. Tests inject a synthetic
    /// stream instead, so this only runs in the live app.
    nonisolated static func defaultFileEvents() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let dir = FilesystemJSONLogReader.defaultRoot().path
            guard FileManager.default.fileExists(atPath: dir) else {
                continuation.finish(); return    // no projects yet → never emits
            }
            final class Box { let cont: AsyncStream<Void>.Continuation
                init(_ c: AsyncStream<Void>.Continuation) { cont = c } }
            let box = Box(continuation)
            var ctx = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passRetained(box).toOpaque(),
                retain: nil, release: nil, copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().cont.yield(())
            }
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &ctx,
                [dir] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.5,   // coalescing latency (s)
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            ) else {
                Unmanaged<Box>.fromOpaque(ctx.info!).release()
                continuation.finish(); return
            }
            // Wrap the non-Sendable FSEventStreamRef so the @Sendable
            // onTermination closure is Swift-6 clean.
            final class StreamHolder: @unchecked Sendable {
                let stream: FSEventStreamRef
                let info: UnsafeMutableRawPointer
                init(_ s: FSEventStreamRef, _ i: UnsafeMutableRawPointer) { stream = s; info = i }
            }
            let holder = StreamHolder(stream, ctx.info!)
            let queue = DispatchQueue(label: "usage-monitor-fsevents")
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            continuation.onTermination = { _ in
                FSEventStreamStop(holder.stream)
                FSEventStreamInvalidate(holder.stream)
                FSEventStreamRelease(holder.stream)
                Unmanaged<Box>.fromOpaque(holder.info).release()
            }
        }
    }

    private func restoreOrResetDailyCounter() {
        guard let ownership else {
            dailyBillableSinceOwnership = 0
            dailyCounterDayKey = nil
            return
        }
        let currentDayKey = ledger.dayKey(for: clock())
        if let persisted = loadDailyCounterState(),
           persisted.profileId == ownership.profileId,
           persisted.dayKey == currentDayKey,
           persisted.ledgerLastUpdate == ledger.lastUpdate {
            dailyBillableSinceOwnership = persisted.count
            dailyCounterDayKey = persisted.dayKey
        } else {
            dailyBillableSinceOwnership = 0
            dailyCounterDayKey = currentDayKey
        }
    }

    private func loadDailyCounterState() -> DailyCounterState? {
        guard FileManager.default.fileExists(atPath: dailyCounterURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: dailyCounterURL)
            return try JSONDecoder().decode(DailyCounterState.self, from: data)
        } catch {
            AppLog.shared.log("UsageMonitor daily-counter load failed: \(error)", level: .warn)
            return nil
        }
    }

    private func persistDailyCounterState() {
        guard let ownership, let dayKey = dailyCounterDayKey else { return }
        let state = DailyCounterState(
            profileId: ownership.profileId,
            dayKey: dayKey,
            count: dailyBillableSinceOwnership,
            ledgerLastUpdate: ledger.lastUpdate
        )
        let url = dailyCounterURL
        pendingCounterPersist?.cancel()
        let action: () -> Void = { Self.writeCounter(state, to: url) }
        let item = DispatchWorkItem(block: action)
        pendingCounterPersist = item
        pendingCounterAction = action
        persistQueue.asyncAfter(deadline: .now() + persistDebounce, execute: item)
    }

    /// Pure write helper. `nonisolated static` so it can run on
    /// `persistQueue` without touching `@MainActor` state.
    private nonisolated static func writeCounter(_ state: DailyCounterState, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.shared.log("UsageMonitor daily-counter persist failed: \(error)", level: .error)
        }
    }

    private func publishFromLedger() {
        sessionTokens = sessionSinceLaunch.billable
        dailyTokens = dailyBillableSinceOwnership
        remainingPercent = Self.percent(used: dailyBillableSinceOwnership, quota: legacyDailyQuotaEstimate)
    }

    private static func percent(used: Int, quota: Int) -> Int {
        guard quota > 0 else { return 0 }
        let remaining = max(0.0, 1.0 - Double(used) / Double(quota))
        return Int((remaining * 100.0).rounded())
    }

    /// Returns the (ledger, readerState) pair from the envelope file. The
    /// reader state is empty when the on-disk file is legacy v2 (pre-envelope);
    /// the caller must still invoke `reader.restore(.init())` so the
    /// "restore is always called before read" contract holds.
    private static func loadEnvelope(at url: URL) -> (UsageLedger, ReaderState) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (UsageLedger(), ReaderState())
        }
        do {
            let data = try Data(contentsOf: url)
            // Try v3 envelope first.
            if let envelope = try? JSONDecoder().decode(PersistedLedgerEnvelope.self, from: data),
               envelope.schemaVersion >= 3 {
                return (envelope.ledger, envelope.readerState)
            }
            // Fallback: legacy v2 ledger directly at the top level. UsageLedger's
            // custom decoder already drops seenUUIDs into an empty Set.
            let legacyLedger = try JSONDecoder().decode(UsageLedger.self, from: data)
            if legacyLedger.schemaVersion < 2 {
                AppLog.shared.log(
                    "UsageMonitor: ledger schema v\(legacyLedger.schemaVersion) < 2, dropping (will rebuild from JSONL with UTC dayKeys)",
                    level: .info
                )
                return (UsageLedger(), ReaderState())
            }
            AppLog.shared.log(
                "UsageMonitor: legacy v2 ledger migrated to envelope schema (readerState empty, will re-walk once)",
                level: .info
            )
            return (legacyLedger, ReaderState())
        } catch {
            AppLog.shared.log("UsageMonitor ledger load failed: \(error)", level: .warn)
            return (UsageLedger(), ReaderState())
        }
    }

    /// Trailing-debounce persist. Each call cancels any pending write and
    /// reschedules a single write `persistDebounce` seconds later on
    /// `persistQueue`. The ledger value is snapshotted on the caller's actor
    /// (cheap — `UsageLedger` is a value type) and the encode/write run off
    /// main. `flushPersistForTesting()` and `stop()` force pending writes
    /// to complete synchronously.
    private func persistLedger() {
        pendingLedgerPersist?.cancel()
        let snapshot = ledger
        let readerSnapshot = reader.state()   // ≤100 fileExists checks; ≤1 Hz under debounce; safe on main
        let url = ledgerURL
        let onWrite = persistDidWriteForTesting
        let action: () -> Void = {
            Self.writeEnvelope(ledger: snapshot, readerState: readerSnapshot, to: url)
            onWrite?()
        }
        let item = DispatchWorkItem(block: action)
        pendingLedgerPersist = item
        pendingLedgerAction = action
        persistQueue.asyncAfter(deadline: .now() + persistDebounce, execute: item)
    }

    /// Pure write helper. `nonisolated static` so it can run on
    /// `persistQueue` without touching `@MainActor` state.
    private nonisolated static func writeEnvelope(
        ledger: UsageLedger,
        readerState: ReaderState,
        to url: URL
    ) {
        let envelope = PersistedLedgerEnvelope(
            schemaVersion: 3,
            ledger: ledger,
            readerState: readerState
        )
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(envelope)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.shared.log("UsageMonitor persist failed: \(error)", level: .error)
        }
    }

    /// Cancel pending persist work items and run their captured actions
    /// synchronously on `persistQueue`. Called from `stop()` (so app quit
    /// cannot lose state inside the debounce window) and from
    /// `flushPersistForTesting()` (so tests can deterministically observe
    /// post-write state).
    ///
    /// Cancelled `DispatchWorkItem.perform()` is a no-op, which is why we
    /// keep the raw action closures alongside the work items and re-execute
    /// those directly. `sync` is safe because `persistQueue` is serial and
    /// we hold no shared locks across the call.
    private func flushPendingPersist() {
        pendingLedgerPersist?.cancel()
        pendingCounterPersist?.cancel()
        let ledgerAction = pendingLedgerAction
        let counterAction = pendingCounterAction
        pendingLedgerPersist = nil
        pendingLedgerAction = nil
        pendingCounterPersist = nil
        pendingCounterAction = nil
        persistQueue.sync {
            ledgerAction?()
            counterAction?()
        }
    }

    /// Synchronously executes any pending persist work and waits for it to
    /// land on disk. Production code does not call this; it exists so unit
    /// tests can deterministically assert post-write state without sleeping.
    func flushPersistForTesting() {
        flushPendingPersist()
    }
}
