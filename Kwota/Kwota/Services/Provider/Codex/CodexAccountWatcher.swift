//
//  CodexAccountWatcher.swift
//  Kwota
//
//  File watcher for `~/.codex/auth.json`. Emits a CodexIdentity when the
//  user logs in / out / rotates accounts. Modelled exactly on
//  CLIAccountWatcher — same baseline-emit-then-debounce shape, same wake
//  observer, same poll fallback.
//

import Foundation
import AppKit
import CryptoKit
import Observation

struct CodexIdentity: Equatable {
    let email: String?
    let accountId: String?
    let credentialFingerprint: String
    let name: String?
    let subscriptionActiveUntil: Date?
    let planType: String?

    init(
        email: String?,
        accountId: String?,
        credentialFingerprint: String,
        name: String? = nil,
        subscriptionActiveUntil: Date? = nil,
        planType: String? = nil
    ) {
        self.email = email
        self.accountId = accountId
        self.credentialFingerprint = credentialFingerprint
        self.name = name
        self.subscriptionActiveUntil = subscriptionActiveUntil
        self.planType = planType
    }
}

@MainActor
protocol CodexAccountWatching: AnyObject {
    var onChange: ((CodexIdentity?) -> Void)? { get set }
    var current: CodexIdentity? { get }
    func start()
    func stop()
}

@MainActor
@Observable
final class CodexAccountWatcher {
    typealias AuthRead = () -> CodexAuthReader.Auth?

    @ObservationIgnored var onChange: ((CodexIdentity?) -> Void)?
    private(set) var current: CodexIdentity?

    @ObservationIgnored private let authRead: AuthRead
    @ObservationIgnored private let fileEvents: AsyncStream<Void>
    @ObservationIgnored private let pollInterval: TimeInterval
    @ObservationIgnored private let debounce: TimeInterval

    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var hasEmittedBaseline = false

    init(
        authRead: @escaping AuthRead = { CodexAuthReader().read() },
        fileEvents: AsyncStream<Void> = CodexAccountWatcher.defaultFileEvents(),
        // 60s, not 5s: the ~/.codex/auth.json FSEvents stream catches account
        // switches promptly; this poll only backstops missed events, so a
        // slower cadence trades imperceptible lag for ~12× fewer idle wakeups.
        pollInterval: TimeInterval = 60,
        debounce: TimeInterval = 0.3
    ) {
        self.authRead = authRead
        self.fileEvents = fileEvents
        self.pollInterval = pollInterval
        self.debounce = debounce
    }

    func start() {
        stop()
        // Synchronous baseline — same rationale as CLIAccountWatcher: populates
        // `current` before any caller can race against it so the coordinator
        // never sees a spurious signed-out state on first tick.
        recompute()
        listenTask = Task { @MainActor [weak self, fileEvents] in
            for await _ in fileEvents { self?.schedule() }
        }
        pollTask = Task { @MainActor [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                if Task.isCancelled { return }
                self?.schedule()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.schedule() }
        }
    }

    func stop() {
        listenTask?.cancel(); listenTask = nil
        pollTask?.cancel(); pollTask = nil
        pendingTask?.cancel(); pendingTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
    }

    private func schedule() {
        pendingTask?.cancel()
        pendingTask = Task { @MainActor [weak self, debounce] in
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.recompute()
        }
    }

    private func recompute() {
        let next = computeCurrent()
        if hasEmittedBaseline && next == current { return }
        hasEmittedBaseline = true
        current = next
        onChange?(next)
    }

    private func computeCurrent() -> CodexIdentity? {
        guard let auth = authRead() else { return nil }
        return CodexIdentity(
            email: auth.email,
            accountId: auth.accountId,
            credentialFingerprint: Self.fingerprint(of: auth.accessToken),
            name: auth.name,
            subscriptionActiveUntil: auth.subscriptionActiveUntil,
            planType: auth.planType
        )
    }

    private static func fingerprint(of token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8)).lowercased()
    }

    /// Production FSEvents stream from `~/.codex/auth.json`. Tests inject a
    /// synthetic stream instead. Delegates to `FileSystemEventStream` so the
    /// re-arm-after-rename logic is shared with the Claude watcher; Codex
    /// CLI rewrites this file atomically on every token rotation, which
    /// would otherwise leave the kqueue fd pointing at a stale inode.
    nonisolated static func defaultFileEvents() -> AsyncStream<Void> {
        FileSystemEventStream.observe(
            path: CodexAuthReader.defaultPath.path,
            queueLabel: "codex-account-watcher"
        )
    }

    deinit {
        listenTask?.cancel()
        pollTask?.cancel()
        pendingTask?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }
}

extension CodexAccountWatcher: CodexAccountWatching {}
