//  AntigravityStatsWatcher.swift
//  Kwota
//
//  Live trigger for Antigravity stats reads. Consumes the Antigravity transcript
//  FSEvents stream (reused from `AntigravityActivitySource`), keeps only
//  `transcript.jsonl` appends — which correlate 1:1 with new `gen_metadata`
//  rows — debounces them, and fires `onChangedPaths(nil)` (a full DB walk; cheap
//  because the reader only pulls rows past each DB's high-water). A 5-minute poll
//  backstops any coalesced/dropped events, and `start()` fires one initial nil
//  backfill so existing history is ingested. Mirrors `CodexStatsWatcher`; the
//  transcript file is only a change SIGNAL — the data lives in the conversation
//  `.db` files the reader walks.

import Foundation

@MainActor
final class AntigravityStatsWatcher {
    /// Always called with `nil` (full DB walk). The signal file (`transcript.jsonl`)
    /// is not itself a data file, so there are no per-path incremental reads here.
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
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.debounce))
            if Task.isCancelled { return }
            self.onChangedPaths?(nil)
        }
    }

    deinit { consumeTask?.cancel(); pollTask?.cancel(); flushTask?.cancel() }
}
