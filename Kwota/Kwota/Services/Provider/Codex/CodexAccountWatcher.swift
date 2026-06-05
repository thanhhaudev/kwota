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

struct CodexIdentity: Equatable {
    let email: String?
    let accountId: String?
    let credentialFingerprint: String
    let name: String?
    let subscriptionActiveUntil: Date?

    init(
        email: String?,
        accountId: String?,
        credentialFingerprint: String,
        name: String? = nil,
        subscriptionActiveUntil: Date? = nil
    ) {
        self.email = email
        self.accountId = accountId
        self.credentialFingerprint = credentialFingerprint
        self.name = name
        self.subscriptionActiveUntil = subscriptionActiveUntil
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
final class CodexAccountWatcher {
    typealias AuthRead = () -> CodexAuthReader.Auth?

    var onChange: ((CodexIdentity?) -> Void)?
    private(set) var current: CodexIdentity?

    private let authRead: AuthRead
    private let fileEvents: AsyncStream<Void>
    private let pollInterval: TimeInterval
    private let debounce: TimeInterval

    private var listenTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var pendingTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var hasEmittedBaseline = false

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
            subscriptionActiveUntil: auth.subscriptionActiveUntil
        )
    }

    private static func fingerprint(of token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8)).lowercased()
    }

    /// Production FSEvents stream from `~/.codex/auth.json`. Tests inject a
    /// synthetic stream instead.
    nonisolated static func defaultFileEvents() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let url = CodexAuthReader.defaultPath
            let fd = open(url.path, O_EVTONLY)
            guard fd != -1 else { continuation.finish(); return }
            let queue = DispatchQueue(label: "codex-account-watcher")
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete],
                queue: queue
            )
            source.setEventHandler { continuation.yield(()) }
            source.setCancelHandler { close(fd) }
            source.resume()
            continuation.onTermination = { _ in source.cancel() }
        }
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
