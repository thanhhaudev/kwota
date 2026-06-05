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
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.isLive = isLive
        self.makeFileEvents = makeFileEvents
        self.clock = clock
        self.scanner = scanner
        self.pollInterval = pollInterval
        self.notificationCenter = notificationCenter
    }

    func start() {
        stop()
        startedAt = clock()
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
                // The FSEvents watch may be rooted at `~/.codex` (so a watcher
                // started before the first session still sees one appear), so
                // keep only writes under a `sessions/` tree.
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
        if let wakeObserver { notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
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

    /// The directory to hand to FSEvents: `~/.codex/sessions` if it exists,
    /// else `~/.codex` (created on install, before the first session) so a
    /// watcher started before any session still sees one appear later. Returns
    /// `[]` only when `~/.codex` is absent — Codex isn't installed.
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

    /// FSEvents stream over `~/.codex/sessions` (or `~/.codex` — see
    /// `watchRoots`), file-level. Yields each changed path (the consume loop
    /// filters to `sessions/`). If `~/.codex` doesn't exist the stream finishes
    /// immediately and never emits. Tests inject a synthetic stream instead.
    nonisolated static func defaultFileEvents() -> AsyncStream<String> {
        AsyncStream { continuation in
            let roots = watchRoots(home: FileManager.default.homeDirectoryForCurrentUser)
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

    deinit {
        consumeTask?.cancel()
        pollTask?.cancel()
        if let wakeObserver { notificationCenter.removeObserver(wakeObserver) }
    }
}
