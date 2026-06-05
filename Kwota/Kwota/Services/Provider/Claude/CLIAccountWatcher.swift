//
//  CLIAccountWatcher.swift
//  Kwota
//

import Foundation
import AppKit
import CryptoKit

/// Identity inferred from the Claude CLI's local state. `orgId` starts nil
/// because oauthAccount in ~/.claude.json doesn't carry it; AutoProfileCoordinator
/// resolves it later via /me. `credentialFingerprint` is a short SHA256 of the
/// stable account identity from ~/.claude.json (accountUuid/organizationUuid/
/// seatTier) so account switches and plan changes register as a change without
/// reading the Keychain.
struct CLIIdentity: Equatable {
    let email: String?
    let orgId: String?
    let credentialFingerprint: String
    // Plan + metadata from ~/.claude.json `oauthAccount`.
    let seatTier: String?
    let organizationType: String?
    let organizationRateLimitTier: String?
    let displayName: String?
    let organizationName: String?
    let subscriptionCreatedAt: Date?

    /// Convenience init for tests and simple construction: new metadata fields
    /// default to nil so existing call sites (tests, stubs) compile unchanged.
    init(
        email: String?,
        orgId: String?,
        credentialFingerprint: String,
        seatTier: String? = nil,
        organizationType: String? = nil,
        organizationRateLimitTier: String? = nil,
        displayName: String? = nil,
        organizationName: String? = nil,
        subscriptionCreatedAt: Date? = nil
    ) {
        self.email = email
        self.orgId = orgId
        self.credentialFingerprint = credentialFingerprint
        self.seatTier = seatTier
        self.organizationType = organizationType
        self.organizationRateLimitTier = organizationRateLimitTier
        self.displayName = displayName
        self.organizationName = organizationName
        self.subscriptionCreatedAt = subscriptionCreatedAt
    }
}

/// Protocol so tests can stub the watcher without subclassing.
/// Production code uses `CLIAccountWatcher` directly; tests pass a fake.
@MainActor
protocol CLIAccountWatching: AnyObject {
    var onChange: ((CLIIdentity?) -> Void)? { get set }
    var current: CLIIdentity? { get }
    func start()
    func stop()
}

@MainActor
final class CLIAccountWatcher {
    typealias OAuthRead = () -> OAuthAccountReader.Account?

    var onChange: ((CLIIdentity?) -> Void)?
    private(set) var current: CLIIdentity?

    private let oauthRead: OAuthRead
    private let fileEvents: AsyncStream<Void>
    private let keychainPollInterval: TimeInterval
    private let debounce: TimeInterval

    private var listenTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var pendingTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var hasEmittedBaseline = false

    init(
        oauthRead: @escaping OAuthRead = { OAuthAccountReader().read() },
        fileEvents: AsyncStream<Void> = CLIAccountWatcher.defaultFileEvents(),
        // 60s backstop: the watcher no longer reads the Keychain — this poll
        // catches any edge-case ~/.claude.json changes that FSEvents missed
        // (e.g. atomic rename on a different volume). The file read never
        // triggers a macOS Keychain consent prompt, so the interval trades
        // imperceptible detection lag for ~12× fewer idle wakeups.
        keychainPollInterval: TimeInterval = 60,
        debounce: TimeInterval = 0.3
    ) {
        self.oauthRead = oauthRead
        self.fileEvents = fileEvents
        self.keychainPollInterval = keychainPollInterval
        self.debounce = debounce
    }

    func start() {
        stop()
        // Baseline emit is synchronous on start() so `current` is populated
        // before any caller can race against it. The MenuBarViewModel kicks
        // off its first refresh tick immediately after wiring the watcher,
        // and guardRefresh would deny it (treating the missing identity as
        // "signed out") if we deferred the baseline through the debounce
        // window — leaving the popover stuck on the loading spinner for one
        // full polling interval. File and keychain change events still go
        // through `schedule()` to coalesce bursts.
        recompute()
        listenTask = Task { @MainActor [weak self, fileEvents] in
            for await _ in fileEvents {
                self?.schedule()
            }
        }
        pollTask = Task { @MainActor [weak self, keychainPollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(keychainPollInterval * 1_000_000_000))
                if Task.isCancelled { return }
                self?.schedule()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
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

    private func computeCurrent() -> CLIIdentity? {
        guard let account = oauthRead() else { return nil }
        return CLIIdentity(
            email: account.emailAddress,
            orgId: nil,
            credentialFingerprint: Self.fingerprint(of: account),
            seatTier: account.seatTier,
            organizationType: account.organizationType,
            organizationRateLimitTier: account.organizationRateLimitTier,
            displayName: account.displayName,
            organizationName: account.organizationName,
            subscriptionCreatedAt: account.subscriptionCreatedAt
        )
    }

    /// Short, stable signature of the *non-secret* account identity from
    /// `~/.claude.json`. Replaces the old SHA256-of-access-token: the watcher
    /// no longer reads the Keychain, so it can't (and shouldn't) hash a secret.
    /// Keyed on the stable accountUuid/organizationUuid (with email/org-name
    /// fallback) plus seatTier, so it flips on account switch and on plan
    /// change within an account.
    private static func fingerprint(of account: OAuthAccountReader.Account) -> String {
        let raw = [
            account.accountUuid ?? account.emailAddress ?? "",
            account.organizationUuid ?? account.organizationName ?? "",
            account.seatTier ?? ""
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return String(digest.compactMap { String(format: "%02x", $0) }.joined().prefix(8)).lowercased()
    }

    /// Production FSEvents stream from `~/.claude.json`. Tests inject a
    /// synthetic stream instead.
    nonisolated static func defaultFileEvents() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let url = OAuthAccountReader.defaultPath
            let fd = open(url.path, O_EVTONLY)
            guard fd != -1 else { continuation.finish(); return }
            let queue = DispatchQueue(label: "cli-account-watcher")
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

extension CLIAccountWatcher: CLIAccountWatching {}
