//  AntigravityStatsWatcher.swift
//  Kwota
//
//  Live trigger for Antigravity stats reads. Consumes the Antigravity transcript
//  FSEvents stream (reused from `AntigravityActivitySource`), keeps only
//  `transcript.jsonl` appends — which correlate 1:1 with new `gen_metadata`
//  rows — debounces them, and fires a TARGETED read of just the conversation DB
//  that changed. The transcript path `…/brain/<convId>/…/transcript.jsonl` shares
//  its `<convId>` with the data file `…/conversations/<convId>.db`, so one active
//  conversation no longer drags every historical DB through a stat sweep on each
//  append. A 5-minute poll and the initial `start()` backfill keep firing `nil`
//  (full walk) so newly-appeared / pruned DBs are still reconciled. Mirrors
//  `CodexStatsWatcher`; the transcript file is only a change SIGNAL — the data
//  lives in the conversation `.db` files the reader reads.

import Foundation

@MainActor
final class AntigravityStatsWatcher {
    /// `nil` ⇒ full DB walk (startup + backstop poll). A non-nil set ⇒ read only
    /// those conversation DBs (a live transcript append, mapped to its `.db`).
    var onChangedPaths: ((Set<URL>?) -> Void)?

    private let makeFileEvents: () -> AsyncStream<String>
    private let pollInterval: TimeInterval
    private let debounce: TimeInterval
    private var consumeTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?

    init(makeFileEvents: @escaping () -> AsyncStream<String> = { AntigravityActivitySource.defaultFileEvents() },
         pollInterval: TimeInterval = 300,
         debounce: TimeInterval = 0.5) {
        self.makeFileEvents = makeFileEvents
        self.pollInterval = pollInterval
        self.debounce = debounce
    }

    func start() {
        guard consumeTask == nil else { return }   // idempotent
        onChangedPaths?(nil)                        // initial backfill
        let stream = makeFileEvents()
        consumeTask = Task { [weak self] in
            for await path in stream { self?.handle(path: path) }
        }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                guard let self else { break }
                self.onChangedPaths?(nil)
            }
        }
    }

    func stop() {
        consumeTask?.cancel(); consumeTask = nil
        pollTask?.cancel(); pollTask = nil
        flushTask?.cancel(); flushTask = nil
    }

    private func handle(path: String) {
        let url = URL(fileURLWithPath: path)
        guard url.lastPathComponent == "transcript.jsonl" else { return }
        // Map the append to its conversation DB so the read touches only that DB.
        // An unmappable path falls back to `nil` (full walk) — safe, just slower.
        let changed = Self.conversationDB(forTranscript: path).map { Set([$0]) }
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.debounce))
            if Task.isCancelled { return }
            self.onChangedPaths?(changed)
        }
    }

    /// Map a transcript path `<root>/brain/<convId>/…/transcript.jsonl` to its
    /// conversation DB `<root>/conversations/<convId>.db`. The shared `<convId>`
    /// is the IDE and CLI layout (verified against real `~/.gemini` trees).
    /// Returns nil when the path isn't a brain transcript, so the caller can
    /// fall back to a full walk.
    static func conversationDB(forTranscript path: String) -> URL? {
        guard let brain = path.range(of: "/brain/") else { return nil }
        let afterBrain = path[brain.upperBound...]
        guard let slash = afterBrain.firstIndex(of: "/") else { return nil }
        let convId = String(afterBrain[afterBrain.startIndex..<slash])
        guard !convId.isEmpty else { return nil }
        let root = String(path[path.startIndex..<brain.lowerBound])
        return URL(fileURLWithPath: root)
            .appendingPathComponent("conversations")
            .appendingPathComponent("\(convId).db")
    }

    deinit { consumeTask?.cancel(); pollTask?.cancel(); flushTask?.cancel() }
}
