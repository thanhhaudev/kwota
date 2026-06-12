//
//  AwakeSessionLog.swift
//  Kwota
//

import Foundation
import Combine
import Observation

struct AwakeSession: Identifiable, Equatable, Codable {
    enum Mode: String, Equatable, Codable { case auto, manual }

    let id: UUID
    let mode: Mode
    let start: Date
    var end: Date?

    init(mode: Mode, start: Date, end: Date? = nil, id: UUID = UUID()) {
        self.id = id
        self.mode = mode
        self.start = start
        self.end = end
    }
}

/// Disk format for `AwakeSessionLog`. Pairs the session list with a
/// `lastPersistedAt` so any session still open at quit-time can be closed
/// at that timestamp on the next launch — without it, an in-progress
/// session would stretch from its old start across the entire offline
/// period, painting a huge fake "awake" tint into the activity chart.
/// `lastPersistedAt` only advances while the caffeine assertion is held
/// (see `heartbeatPersist`), which is what makes it safe to trust on load.
private struct AwakeSessionLogPersisted: Codable {
    let lastPersistedAt: Date
    let sessions: [AwakeSession]
}

@MainActor
@Observable
final class AwakeSessionLog {
    private(set) var sessions: [AwakeSession] = []

    @ObservationIgnored private let windowSeconds: TimeInterval
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let persistURL: URL?
    @ObservationIgnored nonisolated(unsafe) private var pruneTask: Task<Void, Never>?
    @ObservationIgnored private weak var caffeine: CaffeinateManager?
    @ObservationIgnored private var bag: Set<AnyCancellable> = []

    init(
        windowSeconds: TimeInterval = 24 * 3600,
        clock: @escaping () -> Date = { Date() },
        autoStart: Bool = true,
        persistURL: URL? = nil,
        caffeine: CaffeinateManager? = nil
    ) {
        self.windowSeconds = windowSeconds
        self.clock = clock
        self.persistURL = persistURL
        self.caffeine = caffeine
        if let url = persistURL {
            self.sessions = Self.loadSessions(from: url)
            self.prune()
        }
        if autoStart {
            startPruneLoop()
        }
        if let caffeine {
            subscribeToCaffeine(caffeine)
        }
    }

    deinit {
        pruneTask?.cancel()
    }

    nonisolated static func defaultPersistURL() -> URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("awake-sessions.json")
    }

    /// Returns the most recent session's `end`, or the live clock value for an
    /// in-progress session. Re-reads on each access.
    var mostRecentSessionEnd: Date? {
        guard let last = sessions.last else { return nil }
        return last.end ?? clock()
    }

    func record(state: AwakeState, at now: Date? = nil) {
        let timestamp = now ?? clock()
        let openIndex = sessions.indices.last.flatMap { idx in
            sessions[idx].end == nil ? idx : nil
        }
        let before = sessions

        switch state {
        case .autoActive(let since):
            handleActive(mode: .auto, since: since, openIndex: openIndex, now: timestamp)
        case .manualActive(let since, _):
            handleActive(mode: .manual, since: since, openIndex: openIndex, now: timestamp)
        case .idle, .batteryBlocked:
            if let idx = openIndex {
                sessions[idx].end = timestamp
            }
        }

        prune(now: timestamp)
        if sessions != before {
            persist(at: timestamp)
        }
    }

    func prune(now: Date? = nil) {
        let cutoff = (now ?? clock()).addingTimeInterval(-windowSeconds)
        let before = sessions.count
        sessions.removeAll { session in
            if let end = session.end {
                return end < cutoff
            }
            return false
        }
        if sessions.count != before {
            persist(at: now ?? clock())
        }
    }

    /// Advances `lastPersistedAt` while a session is still open. On crash
    /// recovery, any open session is closed at `lastPersistedAt`; without a
    /// heartbeat that timestamp only moves on state changes, so a long-idle
    /// awake (e.g. overnight auto-caffeinate) would restore with `end` set
    /// hours earlier than reality. Piggybacked on the 30s prune loop —
    /// worst-case crash staleness is one tick.
    func heartbeatPersist(now: Date? = nil) {
        let t = now ?? clock()
        // Ground truth is the IOKit assertion. If caffeine has gone inactive
        // while we still carry an open session, that session is an orphan
        // (e.g. crash-between-state-change). Close it at the current clock
        // instead of bumping `lastPersistedAt` forward — bumping is what
        // produced the 7h43m phantom awake session.
        if let caffeine, !caffeine.isActive {
            closeOpenSessions(at: t)
            return
        }
        guard sessions.contains(where: { $0.end == nil }) else { return }
        persist(at: t)
    }

    /// Closes any session whose `end` is still nil, setting it to `at`. Used
    /// when the Mac enters sleep mid-session — the awake interval ends at the
    /// sleep moment regardless of the supervisor's in-memory state, which
    /// stays `.autoActive`/`.manualActive` because caffeinate survives sleep.
    func closeOpenSessions(at: Date) {
        var changed = false
        for i in sessions.indices where sessions[i].end == nil {
            sessions[i].end = at
            changed = true
        }
        if changed {
            persist(at: at)
        }
    }

    /// Appends a new open session of `mode` starting at `at`. Used on wake to
    /// start a fresh session boundary without disturbing the supervisor's
    /// state, whose `since` preserves the user's intent (e.g., manual-mode
    /// timeout counts from the original button press, not from wake).
    func openSession(mode: AwakeSession.Mode, at: Date) {
        sessions.append(AwakeSession(mode: mode, start: at))
        persist(at: at)
    }

    // MARK: - Persistence

    /// Loads sessions from disk and closes any session still open at the
    /// last persisted moment. Returns empty list on missing file or decode
    /// failure — the caller treats absence as a fresh log.
    private static func loadSessions(from url: URL) -> [AwakeSession] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let payload = try JSONDecoder.iso8601().decode(AwakeSessionLogPersisted.self, from: data)
            var restored = payload.sessions
            // Close any session still open at the last persisted moment.
            // `lastPersistedAt` is trustworthy ground truth: heartbeatPersist
            // only advances it while `caffeine.isActive` (and sweeps orphans
            // closed the moment the assertion drops), so the restored span is
            // real awake time within one 30s heartbeat tick. The previous
            // start+5min cap (e38ac4f belt-and-braces against the phantom-
            // awake bug) truncated genuine multi-hour sessions to 5 minutes
            // on every kill-and-relaunch — the dev-loop truncation bug.
            // Clamp to `start` so a pathological payload can't yield
            // end < start.
            for i in restored.indices where restored[i].end == nil {
                restored[i].end = max(restored[i].start, payload.lastPersistedAt)
            }
            return restored
        } catch {
            AppLog.shared.log("AwakeSessionLog load failed: \(error)", level: .warn)
            return []
        }
    }

    private func persist(at timestamp: Date) {
        guard let url = persistURL else { return }
        let payload = AwakeSessionLogPersisted(
            lastPersistedAt: timestamp,
            sessions: sessions
        )
        // Synchronous atomic write — matches the pattern used by
        // UsageMonitor.persistLedger. Payload is a few KB of JSON; main
        // thread blocks for ~1ms. The alternative (detached write) gave
        // tests no completion signal and made overnight load races
        // observable in CI.
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.iso8601().encode(payload)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.shared.log("AwakeSessionLog persist failed: \(error)", level: .error)
        }
    }

    // MARK: - Internals

    private func handleActive(mode: AwakeSession.Mode, since: Date, openIndex: Int?, now: Date) {
        if let idx = openIndex,
           sessions[idx].mode == mode,
           sessions[idx].start == since {
            return   // idempotent
        }
        if let idx = openIndex {
            sessions[idx].end = now
        }
        sessions.append(AwakeSession(mode: mode, start: since))
    }

    /// Treats `caffeine.isActive` as ground truth for whether the IOKit
    /// PreventUserIdleSystemSleep assertion is held. When it flips false,
    /// every open session is closed at the current clock — fixing the
    /// orphan-amplification bug where `record(.idle)` only inspected the
    /// last session and left earlier orphans open indefinitely.
    ///
    /// Note: `record(.idle)` itself was not changed — it still inspects only
    /// the tail. Safe today because the supervisor flips caffeine on every
    /// state transition, so this caffeine-driven sweep always runs as the
    /// final close path. If a future supervisor keeps caffeine active while
    /// opening a new session over an old one, the old orphan would survive;
    /// add a multi-open sweep to `record()` at that point.
    private func subscribeToCaffeine(_ caffeine: CaffeinateManager) {
        caffeine.$isActive
            // `@Published` delivers the current value synchronously on
            // subscribe; the runloop hop defers that initial emission until
            // after `init` returns. Without it, a `false` snapshot at init
            // time would try to close sessions before `loadSessions` (which
            // capped them) has handed them over to `self.sessions`. Tests
            // also depend on the hop so they can mutate the injected clock
            // between subscribe and first delivery.
            .receive(on: RunLoop.main)
            .sink { [weak self] active in
                guard let self else { return }
                if !active {
                    self.closeOpenSessions(at: self.clock())
                }
            }
            .store(in: &bag)
    }

    private func startPruneLoop() {
        pruneTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                self?.prune()
                self?.heartbeatPersist()
            }
        }
    }
}

private extension JSONEncoder {
    static func iso8601() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

private extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
