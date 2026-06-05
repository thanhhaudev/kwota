//
//  AntigravityProcessWatcher.swift
//  Kwota
//
//  Polls AntigravityProcessDetector to detect when the Antigravity
//  language_server starts, stops, or restarts (CSRF token rotation).
//  Emits AntigravityIdentity { csrfToken, port, fingerprint } so the
//  coordinator can promote/archive profiles automatically.
//
//  Pattern: same baseline-emit-then-debounce shape as CodexAccountWatcher,
//  but the signal source is process polling, not FSEvents.
//

import Foundation
import AppKit
import CryptoKit

struct AntigravityIdentity: Equatable {
    /// CSRF token from the language_server's argv. Fingerprinted so
    /// the coordinator can detect a server restart even when the rest
    /// of the visible state is identical.
    let csrfToken: String
    /// Live TCP port on 127.0.0.1 that the RPC client should target.
    let port: Int
    /// SHA-256(csrfToken)[:8] — used by coordinator for change detection.
    let credentialFingerprint: String
}

@MainActor
protocol AntigravityProcessWatching: AnyObject {
    var onChange: ((AntigravityIdentity?) -> Void)? { get set }
    var current: AntigravityIdentity? { get }
    func start()
    func stop()
    /// Out-of-band detect now, ignoring the regular poll cadence.
    /// Used by `MenuBarViewModel.popoverDidOpen` so a refresh fired by the
    /// SWR gate doesn't race against the watcher still holding a stale
    /// (or nil) identity from the previous tick.
    func pokeNow()
    /// Switch the poll loop to the fast (open) cadence — the popover is
    /// visible, so the user may be actively switching Antigravity sessions.
    func popoverDidOpen()
    /// Back the poll loop off to the slow (closed) cadence. Nothing consumes
    /// a fresh identity while the popover is closed (the refresh coordinator
    /// is at its closed interval too, and `pokeNow()` re-detects on open), so
    /// spawning pgrep/ps/lsof every few seconds while idle is wasted energy.
    func popoverDidClose()
}

@MainActor
final class AntigravityProcessWatcher: AntigravityProcessWatching {
    /// Probe used to choose which of the candidate ports actually
    /// serves the Connect-RPC endpoint. The default heuristic returns
    /// `ports.first`; AntigravityAPIClient supplies a real probe at
    /// the wiring layer. If the probe returns nil the watcher falls
    /// back to `info.listeningPorts.first`, and emits nil only when
    /// the process exposes no listening ports at all.
    ///
    /// Marked `@Sendable` so the closure doesn't carry MainActor isolation
    /// when captured. Without this, `-default-isolation=MainActor` makes
    /// the closure type implicitly @MainActor and `await probeWorkingPort(...)`
    /// from a nonisolated context hops to MainActor — which, when MainActor
    /// is busy with SwiftUI work, hangs.
    typealias ProbeWorkingPort = @Sendable (Int, [Int], String) async -> Int?

    var onChange: ((AntigravityIdentity?) -> Void)?
    private(set) var current: AntigravityIdentity?
    /// PID of the detected language_server, kept fresh independently of the
    /// identity equality gate so activity sources can sample the live process
    /// even when the identity itself is unchanged.
    private(set) var currentPID: Int32?

    /// Held directly (not as a closure) so calls don't pick up MainActor
    /// isolation from the surrounding @MainActor class. Must be marked
    /// `nonisolated` — otherwise the property storage inherits MainActor
    /// isolation from the class, and reading `self.detector` from the
    /// nonisolated `recompute()` requires a MainActor hop (which deadlocks
    /// when MainActor is busy with SwiftUI work).
    nonisolated private let detector: AntigravityProcessDetector
    nonisolated private let probeWorkingPort: ProbeWorkingPort

    /// Open/closed poll cadence. Defaults to the closed interval (the popover
    /// starts closed at launch); `popoverDidOpen`/`popoverDidClose` flip it and
    /// respawn the loop. Same shared type `UsageRefreshCoordinator` uses.
    private var cadence: PopoverPollingCadence
    /// The interval the poll loop currently sleeps for. Backed by `cadence`.
    var currentInterval: TimeInterval { cadence.currentInterval }

    private var pollTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var hasEmittedBaseline = false
    /// Only the running watcher schedules poll loops. Set in `start()`, cleared
    /// in `stop()`, so a cadence flip before `start()` just records the interval
    /// without spawning a stray loop.
    private var isStarted = false

    init(
        detector: AntigravityProcessDetector = AntigravityProcessDetector(),
        openInterval: TimeInterval = 5,
        closedInterval: TimeInterval = 60,
        probeWorkingPort: @escaping ProbeWorkingPort = { _, ports, _ in ports.first }
    ) {
        self.detector = detector
        self.cadence = PopoverPollingCadence(openInterval: openInterval, closedInterval: closedInterval)
        self.probeWorkingPort = probeWorkingPort
    }

    /// Test seam: accepts a @Sendable closure for `detect()`. Wraps it in
    /// an AntigravityProcessDetector with `detectOverride` so production
    /// code stays single-path. `@Sendable` strips the implicit MainActor
    /// isolation from the closure type — without it, the watcher would
    /// hang waiting for MainActor when detect() is awaited from
    /// nonisolated recompute().
    convenience init(
        detect: @escaping @Sendable () throws -> AntigravityProcessInfo?,
        pollInterval: TimeInterval = 5,
        probeWorkingPort: @escaping ProbeWorkingPort = { _, ports, _ in ports.first }
    ) {
        let detector = AntigravityProcessDetector(detectOverride: detect)
        self.init(
            detector: detector,
            openInterval: pollInterval,
            closedInterval: pollInterval,
            probeWorkingPort: probeWorkingPort
        )
    }

    /// Test seam for the popover-aware cadence: distinct open/closed intervals.
    convenience init(
        detect: @escaping @Sendable () throws -> AntigravityProcessInfo?,
        openInterval: TimeInterval,
        closedInterval: TimeInterval,
        probeWorkingPort: @escaping ProbeWorkingPort = { _, ports, _ in ports.first }
    ) {
        let detector = AntigravityProcessDetector(detectOverride: detect)
        self.init(
            detector: detector,
            openInterval: openInterval,
            closedInterval: closedInterval,
            probeWorkingPort: probeWorkingPort
        )
    }

    func start() {
        stop()
        isStarted = true
        AppLog.shared.log(
            "AntigravityProcessWatcher: start() — running synchronous baseline detect then scheduling poll at \(currentInterval)s",
            level: .info
        )
        // Synchronous baseline detect. The prior implementation kicked
        // baseline through Task.detached which silently never ran in
        // production (1h+ observed with zero "identity emitted" log
        // entries despite the agy process being up the whole time —
        // Swift's cooperative thread pool didn't schedule the body).
        // Running detect synchronously on MainActor at start() guarantees
        // `current` is set before the first refresh fires. detect() is
        // <100ms (one ps + one lsof) which is acceptable on the main
        // thread at app launch, where MainActor would otherwise be
        // waiting on the same wall clock anyway.
        do {
            if let info = try detector.detect(),
               let port = info.listeningPorts.first {
                applyRecomputed(AntigravityIdentity(
                    csrfToken: info.csrfToken,
                    port: port,
                    credentialFingerprint: Self.fingerprint(of: info.csrfToken)
                ), pid: info.pid)
            } else {
                applyRecomputed(nil, pid: nil)
            }
        } catch {
            AppLog.shared.log(
                "AntigravityProcessWatcher: baseline detect error \(error)",
                level: .warn
            )
            applyRecomputed(nil, pid: nil)
        }
        restartPollLoop()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.recompute() }
        }
    }

    func stop() {
        isStarted = false
        pollTask?.cancel(); pollTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
    }

    func popoverDidOpen() {
        if cadence.setOpen() { restartPollLoop() }
    }

    func popoverDidClose() {
        if cadence.setClosed() { restartPollLoop() }
    }

    /// (Re)spawns the detached poll loop at the current cadence. Cancels any
    /// in-flight loop first so a cadence flip takes effect on the next tick
    /// rather than after the old interval drains. No-op until `start()` has
    /// run, so a pre-start cadence flip only records `currentInterval`.
    private func restartPollLoop() {
        guard isStarted else { return }
        pollTask?.cancel()
        let interval = currentInterval
        pollTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.recompute()
            }
        }
    }

    /// Fires a detect off the MainActor, off the regular poll cadence,
    /// then hops back to the main thread to apply. Idempotent —
    /// `applyRecomputed`'s equality check collapses duplicate pokes into a
    /// single emit when the identity hasn't changed.
    ///
    /// Asynchronous specifically so popover-open (`MenuBarViewModel.popoverDidOpen`)
    /// never blocks the MainActor on `pgrep`/`ps`/`lsof` — the synchronous
    /// version stalled the main thread (spinning-beachball cursor) on every open.
    ///
    /// Runs on a GCD global queue, NOT `Task.detached`: detached tasks spawned
    /// from a busy MainActor context have been observed not to schedule for >1h
    /// in production. A GCD global queue is not subject to cooperative-pool
    /// starvation.
    func pokeNow() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let next: AntigravityIdentity?
            let nextPID: Int32?
            do {
                let info = try self.detector.detect()
                nextPID = info?.pid
                if let info, let port = info.listeningPorts.first {
                    next = AntigravityIdentity(
                        csrfToken: info.csrfToken,
                        port: port,
                        credentialFingerprint: Self.fingerprint(of: info.csrfToken)
                    )
                } else {
                    next = nil
                }
            } catch {
                AppLog.shared.log(
                    "AntigravityProcessWatcher: pokeNow detect error \(error)",
                    level: .warn
                )
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.applyRecomputed(next, pid: nextPID) }
            }
        }
    }

    /// Non-isolated wrapper: runs detect() + probe off the main actor,
    /// then hops to the main actor for state mutation + onChange.
    /// Using a nonisolated function here is critical — if recompute were
    /// declared `@MainActor` and the surrounding class is `@MainActor`,
    /// the very first `await detect()` would suspend on the main actor
    /// while SwiftUI's runloop is doing other work; observed in production
    /// as a baseline emit that never resolves. By detaching the heavy
    /// work, we let MainActor stay responsive and only hop back to apply
    /// the result.
    nonisolated private func recompute() async {
        let next: AntigravityIdentity?
        let nextPID: Int32?
        do {
            let result = try detector.detect()
            nextPID = result?.pid
            if let info = result {
                // Default port selection: lowest listening port. The async
                // probeWorkingPort closure path consistently hangs in
                // production (typealias inherits actor isolation even with
                // @Sendable). The API client tries HTTP first then HTTPS
                // anyway, so picking the wrong port wastes one round-trip
                // but isn't fatal. Revisit if multi-port disambiguation
                // proves necessary.
                if let resolvedPort = info.listeningPorts.first {
                    next = AntigravityIdentity(
                        csrfToken: info.csrfToken,
                        port: resolvedPort,
                        credentialFingerprint: Self.fingerprint(of: info.csrfToken)
                    )
                } else {
                    next = nil
                }
            } else {
                next = nil
            }
        } catch {
            AppLog.shared.log(
                "AntigravityProcessWatcher: detect error \(error)",
                level: .warn
            )
            next = nil
            nextPID = nil
        }
        await MainActor.run { [next, nextPID] in
            self.applyRecomputed(next, pid: nextPID)
        }
    }

    private func applyRecomputed(_ next: AntigravityIdentity?, pid: Int32?) {
        self.currentPID = pid
        if hasEmittedBaseline && next == current { return }
        hasEmittedBaseline = true
        current = next
        // INFO-level so future diagnostics can see process start / stop /
        // restart events in OSLog without having to enable debug. CSRF
        // is logged via its 8-char fingerprint, not the raw token, so
        // shoulder-surfing console output can't replay requests.
        if let id = next {
            AppLog.shared.log(
                "AntigravityProcessWatcher: identity emitted — port=\(id.port) csrf-fp=\(id.credentialFingerprint)",
                level: .info
            )
        } else {
            AppLog.shared.log(
                "AntigravityProcessWatcher: identity cleared (process gone or undetected)",
                level: .info
            )
        }
        onChange?(next)
    }

    nonisolated private static func fingerprint(of token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8)).lowercased()
    }

    deinit {
        pollTask?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }
}

private extension Int32 {
    var intValue: Int { Int(self) }
}
