//
//  CodexStatsWatcher.swift
//  Kwota
//

import Foundation

/// Live trigger for Codex stats reads. Consumes the Codex FSEvents stream
/// (reusing `CodexActivitySource.defaultFileEvents()`), keeps only rollout
/// `.jsonl` appends, debounces them into a batch, and forwards via
/// `onChangedPaths`. A 5-minute poll backstop covers any FSEvents the kernel
/// coalesces or drops, and `start()` fires one initial nil (full-walk) backfill.
/// Mirrors how `UsageMonitor` drives Claude stats, but as its own watcher since
/// the Codex activity source is buried inside the awake `CompositeActivitySource`.
/// The poll is a backstop only — live appends arrive incrementally via FSEvents
/// — so it's deliberately infrequent (a full walk enumerates + stats the whole
/// `~/.codex/sessions` tree, which scales with history).
@MainActor
final class CodexStatsWatcher {
    /// `nil` = read every tracked file incrementally (backfill / poll);
    /// non-nil = read only these changed rollout files.
    var onChangedPaths: ((Set<URL>?) -> Void)?

    private let makeFileEvents: () -> AsyncStream<String>
    private let pollInterval: TimeInterval
    private let debounce: TimeInterval
    private var consumeTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pendingPaths: Set<URL> = []

    init(makeFileEvents: @escaping () -> AsyncStream<String> = { CodexActivitySource.defaultFileEvents() },
         pollInterval: TimeInterval = 300,
         debounce: TimeInterval = 0.5) {
        self.makeFileEvents = makeFileEvents
        self.pollInterval = pollInterval
        self.debounce = debounce
    }

    func start() {
        guard consumeTask == nil else { return }   // idempotent: don't orphan tasks/streams
        onChangedPaths?(nil)   // initial backfill (cheap; offsets make it incremental)
        let stream = makeFileEvents()
        consumeTask = Task { [weak self] in
            for await path in stream {
                self?.handle(path: path)
            }
        }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                guard let self else { break }   // self gone → stop polling
                self.onChangedPaths?(nil)
            }
        }
    }

    func stop() {
        consumeTask?.cancel(); consumeTask = nil
        pollTask?.cancel(); pollTask = nil
        flushTask?.cancel(); flushTask = nil
        pendingPaths.removeAll()
    }

    private func handle(path: String) {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-") else { return }
        pendingPaths.insert(url)
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.debounce))
            if Task.isCancelled { return }
            let batch = self.pendingPaths
            self.pendingPaths.removeAll()
            guard !batch.isEmpty else { return }
            self.onChangedPaths?(batch)
        }
    }

    deinit { consumeTask?.cancel(); pollTask?.cancel(); flushTask?.cancel() }
}
