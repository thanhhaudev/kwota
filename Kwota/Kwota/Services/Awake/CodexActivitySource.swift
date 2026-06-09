//
//  CodexActivitySource.swift
//  Kwota
//

import Foundation
import Combine
import CoreServices
import AppKit

/// Codex work activity: emits a `.fileWrite` per session append (keep-awake)
/// and an `.agentResponse` per newly-appended assistant reply (chart), only
/// while a Codex account is live.
@MainActor
final class CodexActivitySource: ActivitySource {
    private let subject = PassthroughSubject<ActivityEvent, Never>()
    private let isLive: () -> Bool
    private let makeFileEvents: () -> AsyncStream<String>
    private let clock: () -> Date
    private let scanner: ProviderActivityScanner
    private let pollInterval: TimeInterval
    private let notificationCenter: NotificationCenter
    /// Byte offset already consumed per watched file. First sight of a path
    /// snapshots its end-of-file (launch backfill already covers prior content).
    private var offsets: [String: UInt64] = [:]
    /// When `start()` ran. Discovery only ingests lines at/after this instant —
    /// the same moment launch backfill scanned — so a re-found file can't
    /// double-count what backfill already recorded.
    private var startedAt = Date.distantPast
    private var consumeTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    /// Pending debounce flush for `~/.codex/logs_*.sqlite-wal` bumps — `codex
    /// app-server` (the runtime the Claude Code plugin uses) persists every
    /// turn there instead of rollout JSONL, so the sessions/ tree alone never
    /// reflects plugin-driven activity. One turn fires many WAL appends in
    /// rapid succession; the rolling 0.5s timer collapses them into a single
    /// `.agentResponse`. Zero IO — no file read, no stat, no SQLite open.
    private var walFlushTask: Task<Void, Never>?
    private let walDebounce: TimeInterval = 0.5

    /// Last observed mtime per `~/.codex/logs_*.sqlite-wal`. Updated by both
    /// the FSEvent branch (stat at notify-time) and the stat-poll backstop;
    /// either path bumping it suppresses a redundant fire from the other so
    /// the same turn isn't double-counted.
    private var logsWALMtimes: [String: Date] = [:]
    /// Tight stat-only loop for WAL files. FSEvents is unreliable for SQLite
    /// WAL writes that overwrite preallocated space without extending the
    /// file (the common case when `codex app-server` commits within an
    /// already-grown WAL), so the chart can't depend on FSEvents alone.
    /// Polling at the cadence of a typical Codex turn (~5–30s) catches every
    /// turn with negligible cost: one `attributesOfItem` per WAL file per
    /// tick, no open/read/lock — invisible to Codex's writer.
    private var walPollTask: Task<Void, Never>?
    private let walPollInterval: TimeInterval
    private let walProbe: () -> [(path: String, mtime: Date)]
    /// Per-burst trust flag for the next debounced WAL flush. `logs_*.sqlite-wal`
    /// is shared across every `codex app-server` on the machine — orphan brokers
    /// from other projects' worktrees keep bumping it after their session ends.
    /// We only emit a keep-awake pulse for a WAL flush if SOMETHING in the
    /// debounce window observed a live `codex-companion.mjs` process at WAL bump
    /// time. The flag is set at observation time (so a companion that exits
    /// during the 0.5s debounce window doesn't drop the final emit of a real
    /// `/codex` burst) and cleared at fire time (so once the burst finishes,
    /// later orphan bumps don't inherit the prior call's authorization — that
    /// would reintroduce the exact "WAL noise wakes the Mac forever" bug this
    /// gate exists to prevent). Set is monotone-true within a burst: any bump
    /// in the burst that sees the companion alive trusts the whole burst.
    /// Claude `.agentResponse` history is deliberately NOT a trust signal —
    /// it's a global last-Claude-response across every project on the machine,
    /// and gating on it would let any unrelated Claude chat re-authorize WAL
    /// noise from other-project zombies. The companion process IS the precise
    /// Codex-scoped bridge for the "/codex and wait" flow.
    private var pendingFlushTrusted: Bool = false
    /// `/codex` slash command (the codex-companion plugin) spawns `node
    /// codex-companion.mjs` as a Bash-tool child of Claude Code while the
    /// request is in flight; the process exits when the call returns. Its
    /// presence is an unambiguous "user is actively driving codex right
    /// now" signal — orthogonal to Claude's `.agentResponse` cadence and
    /// rollout-JSONL writes (the companion talks to app-server via socket
    /// and never touches `sessions/`).
    private let isClaudeCodexCompanionRunning: () -> Bool

    var activityPublisher: AnyPublisher<ActivityEvent, Never> {
        subject.eraseToAnyPublisher()
    }

    init(
        isLive: @escaping () -> Bool,
        makeFileEvents: @escaping () -> AsyncStream<String> = { CodexActivitySource.defaultFileEvents() },
        clock: @escaping () -> Date = { Date() },
        scanner: ProviderActivityScanner = ProviderActivityBackfill.codex(),
        // 60s, mirroring CodexAccountWatcher: a periodic re-read of files FSEvents
        // has already discovered, so a stalled FSEvents stream (e.g. after a
        // sleep/wake) can't silently freeze the activity chart mid-session.
        pollInterval: TimeInterval = 60,
        // 5s — matches a typical Codex turn (~5–30s) so each turn produces its
        // own chart event without collapsing multiple turns into one. Far
        // tighter than `pollInterval` because the WAL probe is metadata-only
        // (`stat`) while the rollout poll reopens and reads file content.
        walPollInterval: TimeInterval = 5,
        walProbe: @escaping () -> [(path: String, mtime: Date)] = { CodexActivitySource.defaultWALProbe() },
        isClaudeCodexCompanionRunning: @escaping () -> Bool = { false },
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.isLive = isLive
        self.makeFileEvents = makeFileEvents
        self.clock = clock
        self.scanner = scanner
        self.pollInterval = pollInterval
        self.walPollInterval = walPollInterval
        self.walProbe = walProbe
        self.isClaudeCodexCompanionRunning = isClaudeCodexCompanionRunning
        self.notificationCenter = notificationCenter
    }

    /// Default companion check via `pgrep -u <uid> -f <pattern>`. Tightened
    /// past a raw `codex-companion.mjs` substring match so that:
    ///   * Cross-user processes are excluded (`-u <uid>` restricts to the
    ///     current user) — prevents another login's stale companion from
    ///     bridging WAL trust on this user's Kwota.
    ///   * The match is anchored to the official Claude Code plugin install
    ///     path (`openai-codex/codex/<version>/scripts/codex-companion.mjs`).
    ///     Random user scripts or grep'd command lines that happen to mention
    ///     the filename don't pass.
    /// Both narrow the false-positive surface called out by the adversarial
    /// review without taking on a heartbeat-file dependency in the plugin.
    /// Stdout/stderr → `/dev/null` (we only care about exit status); returns
    /// false on any spawn error so a sandbox/permission denial degrades to
    /// "no bridge" instead of crashing the WAL gate.
    nonisolated static func defaultCompanionRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = [
            "-u", String(getuid()),
            "-f", "openai-codex/codex/[^/]+/scripts/codex-companion\\.mjs",
        ]
        p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    func start() {
        stop()
        // Defensive: `stop()` already clears, but if a future caller invokes
        // `start()` without going through `stop()` first the flag must still
        // be a clean false. Belt-and-suspenders for the per-burst invariant.
        pendingFlushTrusted = false
        startedAt = clock()
        // Baseline the WAL mtimes so the first real tick only fires for
        // mtime ADVANCES — a pre-existing WAL (from before launch) isn't a
        // turn, and replaying historical content here would double-count what
        // the launch backfill already covered for rollout JSONL.
        seedWALMtimes()
        startConsuming()
        // Poll backstop: FSEvents delivery isn't guaranteed for a long-running
        // process (it can stall after a sleep/wake), and the stream is armed once
        // with no recovery — so a stall would silently freeze the chart until the
        // app is relaunched. Re-reading already-discovered files on a timer closes
        // that gap. Mirrors CodexAccountWatcher's FSEvents-plus-poll design.
        pollTask = Task { @MainActor [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.pollAndDiscover()
            }
        }
        // WAL stat-poll backstop: FSEvents is unreliable for SQLite WAL
        // content-overwrites (no file-size extension → no kernel notification
        // in practice), so the chart can't depend on the stream alone. A
        // separate timer stat'ing only `~/.codex/logs_*.sqlite-wal` catches
        // every turn at the cost of a single metadata call per file per tick.
        walPollTask = Task { @MainActor [weak self, walPollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(walPollInterval * 1_000_000_000))
                if Task.isCancelled { return }
                self?.pollLogsWAL()
            }
        }
        // On wake, re-arm the FSEvents stream (a fresh stream resumes delivery and
        // discovers sessions created while asleep) and catch up immediately rather
        // than waiting for the next poll tick.
        wakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.startConsuming()
                await self.pollAndDiscover()
                self.pollLogsWAL()
            }
        }
    }

    /// (Re)create the FSEvents stream and its consume loop. Cancelling the prior
    /// task ends iteration of the old (single-use) `AsyncStream`, whose
    /// `onTermination` tears the old FSEvents stream down; the factory then builds
    /// a fresh stream — this is what makes wake re-arm possible.
    private func startConsuming() {
        consumeTask?.cancel()
        let stream = makeFileEvents()
        consumeTask = Task { @MainActor [weak self] in
            for await path in stream {
                // Promote `self` per iteration, not across the whole loop: the
                // source owns this task and an FSEvents stream never finishes on
                // its own, so holding `self` across the await would keep the
                // source alive and defeat `deinit`. Matches CodexAccountWatcher.
                guard let self else { return }
                // App-server WAL bumps: `~/.codex/logs_*.sqlite-wal` grows on
                // every turn of `codex app-server` (the Claude Code plugin's
                // runtime). The WAL filename is the signal; we never open it.
                // Debounce coalesces a turn's worth of appends into one event.
                if Self.isLogsWAL(path) {
                    guard self.isLive() else { continue }
                    // Suppress the next stat-poll tick from re-firing for the
                    // same bump: record the current mtime so `pollLogsWAL`'s
                    // advance check returns false until the next real append.
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                       let mtime = attrs[.modificationDate] as? Date {
                        self.logsWALMtimes[path] = mtime
                    }
                    if self.isClaudeCodexCompanionRunning() {
                        self.pendingFlushTrusted = true
                    }
                    self.scheduleWALFlush()
                    continue
                }
                // Rollout JSONL appends (interactive `codex` / `codex exec`).
                // The FSEvents watch is rooted at `~/.codex` (so other relevant
                // files in that tree are seen too), so keep only writes under a
                // `sessions/` tree for this branch.
                guard path.contains("/sessions/") else { continue }
                guard self.isLive() else { continue }
                // Any append keeps the Mac awake (content-blind, sensitive).
                self.subject.send(ActivityEvent(date: self.clock(), provider: .codex, kind: .fileWrite))
                self.emitAgentResponses(at: path)
            }
        }
    }

    /// Backstop tick: re-read files FSEvents already discovered, from their last
    /// consumed offset. Catches appends the live stream missed while stalled —
    /// the common case, an active session whose file keeps growing. Cheap: it
    /// only revisits known paths and reads the unconsumed tail, never scans the
    /// tree. A keep-awake pulse fires only when a file actually grew, so idle
    /// ticks don't trip it.
    ///
    /// Brand-new session files created during a blackout (not yet a known path)
    /// are picked up separately by `discoverUntrackedFiles`, run each cycle.
    private func pollKnownFiles() {
        guard isLive() else { return }
        for path in Array(offsets.keys) {
            let lines = newLines(at: path)
            guard !lines.isEmpty else { continue }
            subject.send(ActivityEvent(date: clock(), provider: .codex, kind: .fileWrite))
            for line in lines where !line.isEmpty {
                if let date = scanner.timestamp(line) {
                    subject.send(ActivityEvent(date: date, provider: .codex, kind: .agentResponse))
                }
            }
        }
    }

    /// One backstop cycle: catch up files already known, then discover any
    /// matching session files the live stream never reported (created during a
    /// blackout) so they're picked up without waiting for a relaunch.
    private func pollAndDiscover() async {
        pollKnownFiles()
        await discoverUntrackedFiles()
    }

    /// Find rollout files not yet tracked (FSEvents never saw them) and ingest
    /// their replies since `startedAt`, then mark them tracked so the live stream
    /// and poll continue from there. The filesystem walk + reads run off the main
    /// thread; results are applied back on the main actor.
    private func discoverUntrackedFiles() async {
        guard isLive() else { return }
        let known = Set(offsets.keys)
        let roots = scanner.roots
        let matchesFile = scanner.matchesFile
        let timestamp = scanner.timestamp
        let cutoff = startedAt
        let found = await OffMain.run {
            ProviderActivityBackfill.scanUntracked(
                roots: roots, matchesFile: matchesFile, timestamp: timestamp,
                known: known, cutoff: cutoff)
        }
        // Back on the main actor: skip any path the live stream began tracking
        // while the scan ran, so an append is never counted on both paths.
        for file in found where offsets[file.path] == nil {
            offsets[file.path] = file.endOffset
            for date in file.dates {
                subject.send(ActivityEvent(date: date, provider: .codex, kind: .agentResponse))
            }
            if !file.dates.isEmpty {
                subject.send(ActivityEvent(date: clock(), provider: .codex, kind: .fileWrite))
            }
        }
    }

    /// Parse newly-appended lines at `path`, emitting one `.agentResponse` per
    /// assistant reply. The live stream and the poll backstop share the same
    /// per-file offset via `newLines`, so an append is never counted twice.
    private func emitAgentResponses(at path: String) {
        for line in newLines(at: path) where !line.isEmpty {
            if let date = scanner.timestamp(line) {
                subject.send(ActivityEvent(date: date, provider: .codex, kind: .agentResponse))
            }
        }
    }

    func stop() {
        consumeTask?.cancel(); consumeTask = nil
        pollTask?.cancel(); pollTask = nil
        walPollTask?.cancel(); walPollTask = nil
        walFlushTask?.cancel(); walFlushTask = nil
        // Cancelling the flush task doesn't run its body, so the trust flag
        // would otherwise survive into the next `start()` cycle and authorize
        // the first WAL bump after restart — even if that bump is pure orphan
        // noise with no companion running.
        pendingFlushTrusted = false
        if let wakeObserver { notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// Baseline `logsWALMtimes` from the current `walProbe()` snapshot so the
    /// first real poll fires only on advances. A pre-existing WAL with mtime
    /// older than `startedAt` isn't a turn — it's whatever Codex did before
    /// Kwota launched.
    private func seedWALMtimes() {
        for entry in walProbe() {
            logsWALMtimes[entry.path] = entry.mtime
        }
    }

    /// Stat-only WAL backstop. For each `~/.codex/logs_*.sqlite-wal`, compare
    /// the current mtime to the last seen one; on advance, schedule a WAL
    /// flush (same path FSEvents would take). First sight of a file (no prior
    /// entry, e.g. a generation `logs_3` rolled while running) seeds the
    /// baseline without firing — we can't tell whether the file was just
    /// created for this turn or rolled before we noticed.
    private func pollLogsWAL() {
        guard isLive() else { return }
        for entry in walProbe() {
            let prior = logsWALMtimes[entry.path]
            guard prior != nil else {
                logsWALMtimes[entry.path] = entry.mtime
                continue
            }
            if entry.mtime > prior! {
                logsWALMtimes[entry.path] = entry.mtime
                if isClaudeCodexCompanionRunning() {
                    pendingFlushTrusted = true
                }
                scheduleWALFlush()
            }
        }
    }

    /// True for `~/.codex/logs_*.sqlite-wal`. Excludes `state_*`, `goals_*`,
    /// `memories_*` WALs (they bump on background bookkeeping that doesn't
    /// indicate a model turn), the plain `.sqlite` data file, and the
    /// `.sqlite-shm` shared-memory index. The `logs_` prefix follows codex
    /// 1.x's naming (`logs_2.sqlite`); new generations (`logs_3`, …) are
    /// covered without code change.
    private static func isLogsWAL(_ path: String) -> Bool {
        let last = (path as NSString).lastPathComponent
        return last.hasPrefix("logs_") && last.hasSuffix(".sqlite-wal")
    }

    /// Rolling debounce: each WAL bump cancels the prior pending flush and
    /// schedules a fresh one. After `walDebounce` of silence, emit a single
    /// `.fileWrite` (keep-awake) plus one `.agentResponse` (chart). The flush
    /// re-checks `isLive()` because the window is wide enough for a sign-out
    /// to land between schedule and fire. Gates on `pendingFlushTrusted` —
    /// set at WAL bump OBSERVATION time when the companion was alive, sticky
    /// across debounce cancels within a burst, cleared on EVERY terminal path
    /// (whether the emit fires or not) so a skipped flush can't leave stale
    /// authorization for a later burst. Also gates on elapsed wall-clock to
    /// catch system-sleep staleness: `Task.sleep` tracks wall time, so a
    /// lid-close during the 0.5s debounce makes the timer "expire" mid-sleep
    /// and the body resumes post-wake for an observation that may now be
    /// hours old; emitting it would reset the idle timer at wake for stale
    /// activity. Pure timer — no IO, no allocation beyond the Task itself.
    private func scheduleWALFlush() {
        walFlushTask?.cancel()
        let debounce = walDebounce
        let scheduledAt = clock()
        walFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self else { return }
            // Capture + clear the trust flag BEFORE any other guard. If we
            // returned through `!isLive()` without clearing, a later burst
            // that arrives after the user signs back in (companion gone, only
            // orphan zombies bumping) would inherit this stale `true` and
            // falsely emit — reopening the exact bug the per-burst design
            // exists to prevent.
            let trusted = self.pendingFlushTrusted
            self.pendingFlushTrusted = false
            guard self.isLive() else { return }
            guard trusted else { return }
            let now = self.clock()
            // 5s tolerates any plausible MainActor congestion (normal: ~0.5s);
            // anything beyond is almost certainly system sleep restoring an
            // arbitrarily-old debounce timer.
            guard now.timeIntervalSince(scheduledAt) < 5 else { return }
            self.subject.send(ActivityEvent(date: now, provider: .codex, kind: .fileWrite))
            self.subject.send(ActivityEvent(date: now, provider: .codex, kind: .agentResponse))
        }
    }

    /// Complete lines appended to `path` since we last read it.
    ///
    /// First sight of a file that **existed at launch** snapshots its end-of-file
    /// and returns nothing — the launch backfill already covered that content, so
    /// replaying it would double-count. But a file **created after `start()`**
    /// (e.g. a Codex session the companion spawns mid-run) was never backfilled,
    /// and FSEvents only reports it once it already holds replies; for those we
    /// read from the start so the first replies aren't snapshotted away (which
    /// previously left companion sessions invisible on the chart until relaunch).
    /// A partial trailing line (no newline yet) is left unconsumed.
    private func newLines(at path: String) -> [Data] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let from: UInt64
        if let known = offsets[path] {
            from = known
        } else if fileCreatedAfterStart(path) {
            from = 0                     // post-launch session → read its history
        } else {
            offsets[path] = end          // first sight of a pre-launch file → start at EOF
            return []
        }
        guard end > from else {
            offsets[path] = end          // truncated / rotated / empty → resync
            return []
        }
        try? handle.seek(toOffset: from)
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            offsets[path] = end
            return []
        }
        let bytes = [UInt8](data)
        let newline = UInt8(ascii: "\n")
        var lines: [Data] = []
        var lineStart = 0
        var consumed = 0
        for i in 0..<bytes.count where bytes[i] == newline {
            if i > lineStart { lines.append(Data(bytes[lineStart..<i])) }
            lineStart = i + 1
            consumed = i + 1
        }
        offsets[path] = from + UInt64(consumed)   // leave any partial line for next time
        return lines
    }

    /// True when `path` was created at/after `start()` ran — a session the launch
    /// backfill never scanned, so its existing content must be read on first
    /// sight rather than snapshotted away. Unknown creation time → treat as
    /// pre-launch (safe: no replay, matches the old behavior).
    private func fileCreatedAfterStart(_ path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let created = attrs[.creationDate] as? Date else {
            return false
        }
        return created >= startedAt
    }

    /// Scanner / backfill root: prefers the narrower `~/.codex/sessions`
    /// (only rollout JSONL lives there) so the directory enumeration in
    /// `ProviderActivityBackfill.scan(Untracked)?` doesn't recurse the whole
    /// codex tree (cache, sqlite, vendor_imports, etc.). Falls back to
    /// `~/.codex` only when sessions/ isn't created yet. Returns `[]` when
    /// `~/.codex` is absent — Codex isn't installed.
    nonisolated static func watchRoots(
        home: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String] {
        for rel in [".codex/sessions", ".codex"] {
            let p = home.appendingPathComponent(rel).path
            if fileExists(p) { return [p] }
        }
        return []
    }

    /// FSEvents root: always `~/.codex` when present, broader than the scanner
    /// root because the live stream needs to see both rollout JSONL appends
    /// (sessions/ subtree) AND `logs_*.sqlite-wal` bumps (at the top level).
    /// fseventsd is system-wide and only delivers paths — broadening adds
    /// negligible cost. The consume loop strict-filters what it processes.
    nonisolated static func fsEventsRoots(
        home: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String] {
        let p = home.appendingPathComponent(".codex").path
        return fileExists(p) ? [p] : []
    }

    /// FSEvents stream over `~/.codex`, file-level. Yields each changed path;
    /// the consume loop dispatches to the rollout branch (under `sessions/`) or
    /// the WAL debounce branch (`logs_*.sqlite-wal`). If `~/.codex` doesn't
    /// exist the stream finishes immediately and never emits. Tests inject a
    /// synthetic stream instead.
    nonisolated static func defaultFileEvents() -> AsyncStream<String> {
        AsyncStream { continuation in
            let roots = fsEventsRoots(home: FileManager.default.homeDirectoryForCurrentUser)
            guard !roots.isEmpty else {
                continuation.finish(); return    // no ~/.codex → never emits
            }
            final class Box { let cont: AsyncStream<String>.Continuation
                init(_ c: AsyncStream<String>.Continuation) { cont = c } }
            let box = Box(continuation)
            var ctx = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passRetained(box).toOpaque(),
                retain: nil, release: nil, copyDescription: nil
            )
            // `kFSEventStreamCreateFlagUseCFTypes` makes `eventPaths` a
            // CFArray of CFString, so it bridges cleanly to `[String]`.
            let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
                guard let info else { return }
                let cont = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().cont
                let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
                guard let paths = cfArray as? [String] else { return }
                for p in paths { cont.yield(p) }
            }
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &ctx,
                roots as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.5,   // coalescing latency (s)
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagUseCFTypes)
            ) else {
                Unmanaged<Box>.fromOpaque(ctx.info!).release()
                continuation.finish(); return
            }
            final class StreamHolder: @unchecked Sendable {
                let stream: FSEventStreamRef
                let info: UnsafeMutableRawPointer
                init(_ s: FSEventStreamRef, _ i: UnsafeMutableRawPointer) { stream = s; info = i }
            }
            let holder = StreamHolder(stream, ctx.info!)
            let queue = DispatchQueue(label: "codex-activity-fsevents")
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

    /// Production WAL probe: enumerate `~/.codex` for files matching the
    /// same `logs_*.sqlite-wal` filter the FSEvent branch uses, then `stat`
    /// each for its modification date. Returns `[]` when `~/.codex` is
    /// absent (Codex not installed) — the source then never fires WAL
    /// events, which is correct.
    nonisolated static func defaultWALProbe() -> [(path: String, mtime: Date)] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex").path
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [(path: String, mtime: Date)] = []
        for name in entries where name.hasPrefix("logs_") && name.hasSuffix(".sqlite-wal") {
            let full = (dir as NSString).appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            out.append((path: full, mtime: mtime))
        }
        return out
    }

    deinit {
        consumeTask?.cancel()
        pollTask?.cancel()
        walPollTask?.cancel()
        walFlushTask?.cancel()
        if let wakeObserver { notificationCenter.removeObserver(wakeObserver) }
    }
}
