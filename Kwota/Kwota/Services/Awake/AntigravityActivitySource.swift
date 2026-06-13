//
//  AntigravityActivitySource.swift
//  Kwota
//

import Foundation
import Combine
import CoreServices
import AppKit

/// Antigravity work activity: emits a `.fileWrite` per transcript append (keep-awake) and an `.agentResponse` per newly-appended `PLANNER_RESPONSE` line (chart), only while Antigravity is live. Watches the
/// per-step agent logs `~/.gemini/antigravity/brain/**/transcript.jsonl` (IDE)
/// and `~/.gemini/antigravity-cli/brain/**/transcript.jsonl` (CLI) via FSEvents.
///
/// An idle-but-open Antigravity writes nothing under these trees (verified:
/// only background *network* telemetry continues), so unlike the previous
/// `nettop` throughput proxy this never reports "working" while the agent sits
/// idle.
@MainActor
final class AntigravityActivitySource: ActivitySource {
    private let subject = PassthroughSubject<ActivityEvent, Never>()
    private let isLive: () -> Bool
    private let makeFileEvents: () -> AsyncStream<String>
    private let clock: () -> Date
    private let scanner: ProviderActivityScanner
    private let pollInterval: TimeInterval
    private let notificationCenter: NotificationCenter
    /// Byte offset already consumed per watched transcript. First sight of a
    /// path snapshots its end-of-file so launch backfill isn't replayed.
    private var offsets: [String: UInt64] = [:]
    /// Per-transcript verdict: is this session one of Kwota's own cache-eval
    /// `agy -p` runs (written into the watched brain tree)? Classified once from
    /// transcript content on first sight, then reused — the answer can't change
    /// for a given session, and re-reading large real-session files per append
    /// would be wasteful.
    private var cacheEvalVerdict: [String: Bool] = [:]
    /// When `start()` ran. Discovery only ingests lines at/after this instant —
    /// the same moment launch backfill scanned — so a re-found transcript can't
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
        makeFileEvents: @escaping () -> AsyncStream<String> = { AntigravityActivitySource.defaultFileEvents() },
        clock: @escaping () -> Date = { Date() },
        scanner: ProviderActivityScanner = ProviderActivityBackfill.antigravity(),
        // 60s, mirroring CodexAccountWatcher: a periodic re-read of transcripts
        // FSEvents has already discovered, so a stalled FSEvents stream (e.g.
        // after a sleep/wake) can't silently freeze the activity chart mid-session.
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
        // app is relaunched. Re-reading already-discovered transcripts on a timer
        // closes that gap. Mirrors CodexAccountWatcher's FSEvents-plus-poll design.
        pollTask = Task { @MainActor [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.pollAndDiscover()
            }
        }
        // On wake, re-arm the FSEvents stream (a fresh stream resumes delivery and
        // discovers transcripts written while asleep) and catch up immediately
        // rather than waiting for the next poll tick.
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
                // The FSEvents watch may be rooted above the `brain` tree (so a
                // watcher started before the first conversation still sees the
                // transcript appear). Keep only per-step transcript appends
                // under a `brain/` tree — the precise agent-activity signal.
                guard path.contains("/brain/"), path.hasSuffix("/transcript.jsonl")
                else { continue }
                guard self.isLive() else { continue }
                // Skip Kwota's own cache-eval runs: the provider CLI writes their
                // transcript into this same brain tree, but they aren't user work.
                guard !self.isCacheEvalTranscript(path) else { continue }
                AppLog.shared.log("ACTIVITY_TRACE AG.consume path=\(path)", level: .info)
                self.subject.send(ActivityEvent(date: self.clock(), provider: .antigravity, kind: .fileWrite))
                self.emitAgentResponses(at: path)
            }
        }
    }

    /// Backstop tick: re-read transcripts FSEvents already discovered, from their
    /// last consumed offset. Catches appends the live stream missed while stalled —
    /// the common case, an active conversation whose transcript keeps growing.
    /// Cheap: it only revisits known paths and reads the unconsumed tail, never
    /// scans the tree. A keep-awake pulse fires only when a transcript actually
    /// grew.
    ///
    /// Brand-new transcripts created during a blackout (not yet a known path)
    /// are picked up separately by `discoverUntrackedFiles`, run each cycle.
    private func pollKnownFiles() {
        guard isLive() else { return }
        for path in Array(offsets.keys) {
            guard !isCacheEvalTranscript(path) else { continue }
            let lines = newLines(at: path)
            guard !lines.isEmpty else { continue }
            AppLog.shared.log("ACTIVITY_TRACE AG.poll path=\(path) lines=\(lines.count)", level: .info)
            subject.send(ActivityEvent(date: clock(), provider: .antigravity, kind: .fileWrite))
            for line in lines where !line.isEmpty {
                if let date = scanner.timestamp(line) {
                    subject.send(ActivityEvent(date: date, provider: .antigravity, kind: .agentResponse))
                }
            }
        }
    }

    /// One backstop cycle: catch up transcripts already known, then discover any
    /// matching transcripts the live stream never reported (created during a
    /// blackout) so they're picked up without waiting for a relaunch.
    private func pollAndDiscover() async {
        pollKnownFiles()
        await discoverUntrackedFiles()
    }

    /// Find transcripts not yet tracked (FSEvents never saw them) and ingest
    /// their `PLANNER_RESPONSE`s since `startedAt`, then mark them tracked so the
    /// live stream and poll continue from there. The filesystem walk + reads run
    /// off the main thread; results are applied back on the main actor.
    private func discoverUntrackedFiles() async {
        guard isLive() else { return }
        let known = Set(offsets.keys)
        let roots = scanner.roots
        let matchesFile = scanner.matchesFile
        let timestamp = scanner.timestamp
        let excludeFile = scanner.excludeFile
        let cutoff = startedAt
        let found = await OffMain.run {
            ProviderActivityBackfill.scanUntracked(
                roots: roots, matchesFile: matchesFile, timestamp: timestamp,
                known: known, cutoff: cutoff, excludeFile: excludeFile)
        }
        // Back on the main actor: skip any path the live stream began tracking
        // while the scan ran, so an append is never counted on both paths.
        for file in found where offsets[file.path] == nil {
            offsets[file.path] = file.endOffset
            if !file.dates.isEmpty {
                AppLog.shared.log("ACTIVITY_TRACE AG.discover path=\(file.path) dates=\(file.dates.count)", level: .info)
            }
            for date in file.dates {
                subject.send(ActivityEvent(date: date, provider: .antigravity, kind: .agentResponse))
            }
            if !file.dates.isEmpty {
                subject.send(ActivityEvent(date: clock(), provider: .antigravity, kind: .fileWrite))
            }
        }
    }

    /// Parse newly-appended lines at `path`, emitting one `.agentResponse` per
    /// `PLANNER_RESPONSE`. The live stream and the poll backstop share the same
    /// per-file offset via `newLines`, so an append is never counted twice.
    private func emitAgentResponses(at path: String) {
        for line in newLines(at: path) where !line.isEmpty {
            if let date = scanner.timestamp(line) {
                subject.send(ActivityEvent(date: date, provider: .antigravity, kind: .agentResponse))
            }
        }
    }

    /// Whether `path` is one of Kwota's own cache-eval transcripts (which the
    /// provider CLI writes into the watched brain tree). Classified once from
    /// content via `AntigravityCacheEvalFilter` and memoized: a session's nature
    /// is fixed, and the signature lives in the first line so the head read on
    /// first sight is enough. An unreadable file is treated as not-an-eval and
    /// not memoized, so a transient read miss can't permanently mute a session.
    private func isCacheEvalTranscript(_ path: String) -> Bool {
        if let verdict = cacheEvalVerdict[path] { return verdict }
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let verdict = AntigravityCacheEvalFilter.isCacheEvalTranscript(path: path)
        cacheEvalVerdict[path] = verdict
        return verdict
    }

    func stop() {
        consumeTask?.cancel(); consumeTask = nil
        pollTask?.cancel(); pollTask = nil
        if let wakeObserver { notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// Complete lines appended to `path` since we last read it.
    ///
    /// First sight of a file that existed at launch snapshots end-of-file and
    /// returns nothing (launch backfill covers that content). A file created
    /// after `start()` — a conversation begun mid-run — was never backfilled and
    /// FSEvents only reports it once it already holds replies, so for those we
    /// read from the start rather than snapshotting the existing replies away. A
    /// partial trailing line is left for the next append.
    private func newLines(at path: String) -> [Data] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let from: UInt64
        if let known = offsets[path] {
            from = known
        } else if fileCreatedAfterStart(path) {
            from = 0                     // post-launch conversation → read its history
        } else {
            offsets[path] = end          // first sight of a pre-launch file → start at EOF
            return []
        }
        guard end > from else {
            offsets[path] = end
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
        offsets[path] = from + UInt64(consumed)
        return lines
    }

    /// True when `path` was created at/after `start()` ran — a conversation the
    /// launch backfill never scanned, so its existing content must be read on
    /// first sight rather than snapshotted away. Unknown creation time → treat as
    /// pre-launch (safe: no replay).
    private func fileCreatedAfterStart(_ path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let created = attrs[.creationDate] as? Date else {
            return false
        }
        return created >= startedAt
    }

    /// The directories to hand to FSEvents. For each Antigravity surface (IDE,
    /// CLI) we watch the deepest directory that already exists: `brain/` is the
    /// ideal root but only appears after the first agent conversation, so we
    /// fall back to the app dir (created on install) or `~/.gemini`. This lets
    /// a watcher started before the first conversation still see the transcript
    /// appear later (FSEvents reports new nested files under a watched root).
    /// Returns `[]` only when `~/.gemini` itself is absent — Antigravity isn't
    /// installed, so there is nothing to watch.
    nonisolated static func watchRoots(
        home: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String] {
        let chains: [[String]] = [
            [".gemini/antigravity/brain", ".gemini/antigravity", ".gemini"],
            [".gemini/antigravity-cli/brain", ".gemini/antigravity-cli", ".gemini"],
        ]
        var roots: [String] = []
        for chain in chains {
            for rel in chain {
                let p = home.appendingPathComponent(rel).path
                if fileExists(p) {
                    if !roots.contains(p) { roots.append(p) }
                    break
                }
            }
        }
        return roots
    }

    /// FSEvents stream over the Antigravity "brain" roots (or their deepest
    /// existing ancestor — see `watchRoots`), file-level. Yields each changed
    /// path (the consume loop filters to transcript appends). If `~/.gemini`
    /// doesn't exist the stream finishes immediately and never emits. Tests
    /// inject a synthetic stream instead.
    nonisolated static func defaultFileEvents() -> AsyncStream<String> {
        AsyncStream { continuation in
            let roots = watchRoots(home: FileManager.default.homeDirectoryForCurrentUser)
            guard !roots.isEmpty else {
                continuation.finish(); return    // no ~/.gemini → never emits
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
            // CFArray of CFString. Bridge through Unmanaged rather than
            // `unsafeBitCast` + `as? [String]` — the latter goes through an
            // NSArray bridge that allocates a transient Swift array on every
            // callback (called from a non-MainActor FSEvents queue), which
            // has been observed to corrupt adjacent Foundation objects in
            // the bridged-NS heap under sustained concurrent CF traffic.
            // CFArrayGetValueAtIndex + CFString→Swift String is the same
            // pattern UsageMonitor uses.
            let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
                guard let info else { return }
                let cont = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().cont
                let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
                for i in 0..<numEvents {
                    guard let raw = CFArrayGetValueAtIndex(cfPaths, i) else { continue }
                    let path = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
                    cont.yield(path)
                }
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
            // Capture the immutable info pointer (not the `var ctx`) and wrap the
            // non-Sendable FSEventStreamRef so the @Sendable onTermination closure
            // is Swift-6 clean — same idiom as CodexActivitySource's StreamHolder.
            final class StreamHolder: @unchecked Sendable {
                let stream: FSEventStreamRef
                let info: UnsafeMutableRawPointer
                init(_ s: FSEventStreamRef, _ i: UnsafeMutableRawPointer) { stream = s; info = i }
            }
            let holder = StreamHolder(stream, ctx.info!)
            let queue = DispatchQueue(label: "antigravity-activity-fsevents")
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
