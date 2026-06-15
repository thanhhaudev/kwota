//  CodexTraceWatcher.swift
//  Kwota
//
//  Live trigger for Codex trace-DB reads (ephemeral plugin-review usage).
//  Poll-only: fires one initial backfill, then re-emits the discovered
//  `~/.codex/logs_*.sqlite` URLs every `pollInterval`. No FSEvents — review
//  usage isn't latency-critical for stats and the trace DB is large, so a sparse
//  poll is the right cost. Reads are incremental (rowid cursor), so each tick
//  only scans new rows. Mirrors `CodexStatsWatcher` but without the FSEvents
//  stream (the awake source deliberately never opens this DB; this watcher is the
//  only thing that does, and only every `pollInterval`).

import Foundation

@MainActor
final class CodexTraceWatcher {
    /// Non-nil = read only these changed `logs_*.sqlite` files. The composite
    /// reader routes them to the trace reader and ignores them for rollout.
    var onChangedPaths: ((Set<URL>?) -> Void)?

    private let codexHome: URL
    private let fm: FileManager
    private let pollInterval: TimeInterval
    private var pollTask: Task<Void, Never>?

    init(codexHome: URL = CodexTraceReader.defaultHome(),
         fileManager: FileManager = .default,
         pollInterval: TimeInterval = 300) {
        self.codexHome = codexHome
        self.fm = fileManager
        self.pollInterval = pollInterval
    }

    func start() {
        guard pollTask == nil else { return }   // idempotent
        fire()   // initial backfill (cheap; rowid cursor makes it incremental)
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                guard let self else { break }
                self.fire()
            }
        }
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

    private func fire() {
        let dbs = discover()
        guard !dbs.isEmpty else { return }
        onChangedPaths?(dbs)
    }

    private func discover() -> Set<URL> {
        guard let items = try? fm.contentsOfDirectory(
            at: codexHome, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return [] }
        return Set(items.filter { $0.lastPathComponent.hasPrefix("logs_") && $0.pathExtension == "sqlite" })
    }

    deinit { pollTask?.cancel() }
}
