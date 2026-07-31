//
//  CLICredentialReader.swift
//  Kwota
//
//  Reads Claude Code's saved OAuth credentials and converts them into a
//  Credential.cliToken. Newer Claude Code versions store credentials in the
//  macOS Keychain (service "Claude Code-credentials"); older versions wrote
//  to ~/.claude/.credentials.json. We try Keychain first, then fall back to
//  the legacy file. We never refresh these tokens — Claude Code is the
//  source of truth.
//

import Foundation
import Security

/// Seam that lets tests and higher-level services inject a CLI credential
/// source without touching `CLICredentialReader`'s real Keychain and
/// filesystem paths.
///
/// Both methods are `async` and run their blocking `SecItemCopyMatching` off
/// the main thread. Keeping a synchronous variant would leave the trap armed
/// for the next call site: a consent dialog for another app's Keychain item
/// blocks whatever thread asks, and on the main thread that freezes every
/// keep-awake release path at once.
protocol CLICredentialReading: Sendable {
    func read() async throws -> CLICredentialReader.SyncResult
    func readFresh() async throws -> CLICredentialReader.SyncResult
}

extension CLICredentialReading {
    func readFresh() async throws -> CLICredentialReader.SyncResult {
        try await read()
    }
}

/// Thrown when a credential read did not answer inside its deadline. In
/// practice that means an unanswered cross-app Keychain consent dialog: the
/// caller is released, the thread parked inside `SecItemCopyMatching` is not.
nonisolated struct CLICredentialTimeout: Error {}

nonisolated struct CLICredentialReader {
    typealias KeychainProbe = () -> Data?

    let credentialsFile: URL
    // `nonisolated(unsafe)`: the reader is `Sendable` (it crosses onto a global
    // queue in `read()`) but `KeychainProbe` deliberately is not — the test
    // seams inject closures over captured state, and a `@Sendable` probe type
    // would outlaw them.
    //
    // What makes the escape hatch sound is the *production* probe, not the
    // `let`: `defaultKeychainProbe` closes over nothing mutable — it builds a
    // fresh query dictionary and calls `SecItemCopyMatching`, so there is no
    // shared state to race when it is invoked from the GCD worker. Injected
    // test probes that do capture mutable state own their own synchronisation.
    private nonisolated(unsafe) let keychainProbe: KeychainProbe

    init(
        credentialsFile: URL = CLICredentialReader.defaultPath,
        keychainProbe: @escaping KeychainProbe = CLICredentialReader.defaultKeychainProbe
    ) {
        self.credentialsFile = credentialsFile
        self.keychainProbe = keychainProbe
    }

    static var defaultPath: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/.credentials.json")
    }

    static let keychainService = "Claude Code-credentials"

    static let defaultKeychainProbe: KeychainProbe = {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    /// True when Claude Code's legacy credentials file exists. Intentionally
    /// does NOT probe the Keychain — a probe would trigger the cross-app
    /// consent prompt for a mere availability check. The real read path
    /// (`read()`) still tries the Keychain first when a credential is needed.
    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: credentialsFile.path)
    }

    struct SyncResult: Equatable {
        let credential: Credential
        let subscriptionPlan: String?
    }

    private struct Payload: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        let subscriptionType: String?
    }

    private struct KeychainEnvelope: Decodable {
        let claudeAiOauth: Payload
        enum CodingKeys: String, CodingKey { case claudeAiOauth }
    }

    /// Runs the whole read — Keychain probe, legacy-file fallback, decode — on a
    /// GCD global queue via `OffMain.run`. `Task.detached` would not do: this
    /// target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a
    /// detached closure body is still `@MainActor` and would leave the blocking
    /// `SecItemCopyMatching` exactly where F-003 found it.
    func read() async throws -> SyncResult {
        // Snapshot the two stored properties into locals so the `@Sendable`
        // closure captures values instead of `self`.
        let probe = keychainProbe
        let file = credentialsFile
        return try await OffMain.run {
            if let data = probe(), let result = Self.decodeKeychainPayload(data) {
                return result
            }
            let data = try Data(contentsOf: file)
            let payload = try Self.decoder().decode(Payload.self, from: data)
            return SyncResult(
                credential: .cliToken(
                    accessToken: payload.accessToken,
                    refreshToken: payload.refreshToken,
                    expiresAt: payload.expiresAt
                ),
                subscriptionPlan: payload.subscriptionType
            )
        }
    }

    // `static` on purpose: these run inside the `@Sendable` closure above, and
    // an instance method would capture `self` across the isolation boundary.
    private static func decodeKeychainPayload(_ data: Data) -> SyncResult? {
        let decoder = Self.decoder()
        if let envelope = try? decoder.decode(KeychainEnvelope.self, from: data) {
            return makeResult(envelope.claudeAiOauth)
        }
        if let p = try? decoder.decode(Payload.self, from: data) {
            return makeResult(p)
        }
        return nil
    }

    private static func makeResult(_ p: Payload) -> SyncResult {
        SyncResult(
            credential: .cliToken(
                accessToken: p.accessToken,
                refreshToken: p.refreshToken,
                expiresAt: p.expiresAt
            ),
            subscriptionPlan: p.subscriptionType
        )
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            // Try ISO8601 string first, then numeric epoch (sec or ms).
            if let s = try? c.decode(String.self) {
                // TODO(post-usage): cache static ISO8601DateFormatter; per-line allocation is wasteful if reused on larger files.
                if let d = ISO8601DateFormatter().date(from: s) { return d }
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad ISO8601: \(s)")
            }
            let n = try c.decode(Double.self)
            // Heuristic: anything > 10^12 is milliseconds.
            return n > 1_000_000_000_000 ? Date(timeIntervalSince1970: n / 1000) : Date(timeIntervalSince1970: n)
        }
        return d
    }
}

extension CLICredentialReader: CLICredentialReading {
    /// `CLICredentialReader.read()` is always a live Keychain probe, so a fresh
    /// read is just another read. Spelled out explicitly (rather than inheriting
    /// the protocol default) so the "always live" contract stays local: if a
    /// caching layer is ever added to `read()`, this must stay uncached to keep
    /// 401 recovery working.
    func readFresh() async throws -> SyncResult {
        try await read()
    }
}

/// Short-lived shared cache around Claude Code credential reads. The real read
/// path probes another app's Keychain item, which can trigger macOS consent
/// prompts on self-signed/dev builds. Sharing this wrapper between startup
/// import and usage refresh collapses duplicate reads without hiding a forced
/// 401 recovery path.
final class CachedCLICredentialReader: CLICredentialReading {
    private struct Entry {
        let result: Result<CLICredentialReader.SyncResult, Error>
        let at: Date
    }

    /// The marker carries a token so the task that finishes can prove the slot
    /// it is about to clear is still its own — `Task` is a struct, so there is
    /// no `===` to compare against. See the `defer` in `readFresh()`.
    private struct InFlightRead {
        let token: UUID
        let task: Task<CLICredentialReader.SyncResult, Error>
    }

    private let reader: any CLICredentialReading
    /// How long a completed result is reused before a fresh probe is allowed.
    private let ttl: TimeInterval
    /// How long a caller waits on a probe that has not answered yet. Distinct
    /// from `ttl`: `ttl` bounds the age of a *result*, `timeout` bounds the wait
    /// for one that may never arrive.
    private let timeout: TimeInterval
    private let now: () -> Date
    private var entry: Entry?

    /// Timing out the caller does not unblock the thread — `SecItemCopyMatching`
    /// is not cancellable. Without this guard an unanswered dialog would have
    /// every refresh tick park another `DispatchQueue.global` worker: across the
    /// eight hours F-003 lasted, on the order of a hundred threads at 512 KB of
    /// stack each, grown by the fix meant to make the hang harmless.
    private var inFlight: InFlightRead?

    init(
        reader: any CLICredentialReading = CLICredentialReader(),
        ttl: TimeInterval = 10,
        timeout: TimeInterval = 10,
        now: @escaping () -> Date = Date.init
    ) {
        self.reader = reader
        self.ttl = ttl
        self.timeout = timeout
        self.now = now
    }

    func read() async throws -> CLICredentialReader.SyncResult {
        let current = now()
        if let entry, current.timeIntervalSince(entry.at) < ttl {
            return try entry.result.get()
        }
        return try await readFresh()
    }

    func readFresh() async throws -> CLICredentialReader.SyncResult {
        // Every exit from this method writes the cache, which is why both
        // branches below funnel through one `do`/`catch` instead of returning
        // directly. A piggybacked success that skipped the write would leave the
        // cache cold and let the very next `read()` open a brand-new cross-app
        // Keychain probe — one more consent-prompt opportunity, which is exactly
        // what this wrapper exists to collapse. That overlap is reachable in
        // production: the auto-detect coordinator's credential import and a
        // `CLITokenRefresher.freshen` tick share one instance and can now run at
        // the same time, because the import became asynchronous.
        do {
            let result: CLICredentialReader.SyncResult
            if let existing = inFlight {
                // Piggyback on an outstanding probe rather than starting a second
                // one — and under the same ceiling. A bare `await existing.value`
                // here would be unbounded and reintroduce exactly the stall the
                // timeout exists for.
                result = try await withTimeout(seconds: timeout) { try await existing.task.value }
            } else {
                // The marker is cleared by the TASK, not by the caller. Clearing
                // it from the caller's `defer` looks right and is not: the
                // timeout path returns at 10 s while `SecItemCopyMatching` is
                // still parked and uncancellable, so the next refresh tick would
                // see a free slot and park another global-queue worker. Over an
                // eight-hour unanswered dialog that is the very thread pile-up
                // this guard exists to prevent.
                //
                // `@MainActor` is spelled out rather than inherited so the
                // `defer` can clear the marker synchronously at task completion.
                // A deferred hop (`Task { @MainActor in ... }`) would leave a
                // window in which the read has already returned but the slot
                // still reads as busy, and a caller landing in that window would
                // piggyback on a finished task and get its stale result back
                // from a method whose whole contract is "fresh".
                //
                // The token check makes "only clear my own slot" a property of
                // this code rather than of whole-program reasoning. Today no
                // `await` sits between the `Task` being created and `inFlight`
                // being assigned, so main-actor serialisation already guarantees
                // no other read can start and finish in that window — but on a
                // guard whose whole job is preventing a thread pile-up, a future
                // refactor that introduces such an await must not be able to
                // silently free the slot out from under a live probe.
                let token = UUID()
                let source = reader
                let task = Task { @MainActor [weak self] () -> CLICredentialReader.SyncResult in
                    defer { if self?.inFlight?.token == token { self?.inFlight = nil } }
                    return try await source.readFresh()
                }
                inFlight = InFlightRead(token: token, task: task)
                result = try await withTimeout(seconds: timeout) { try await task.value }
            }
            entry = Entry(result: .success(result), at: now())
            return result
        } catch {
            entry = Entry(result: .failure(error), at: now())
            throw error
        }
    }

    /// Returns as soon as `work` answers or `seconds` elapse, whichever is
    /// first — and, critically, really does return at the deadline.
    ///
    /// The obvious spelling of this races the work against a sleep inside a
    /// `withThrowingTaskGroup`, and that does not work here. A task group is
    /// structured: throwing the timeout out of the group cancels the children
    /// and then *waits* for them, and a thread parked inside
    /// `SecItemCopyMatching` answers no cancellation. Measured against the
    /// hung-probe test — three reads with a 0.2 s deadline against a 2 s probe
    /// took 6.7 s and started three probes, i.e. a timeout in name only, which
    /// then defeats the in-flight guard because each caller only returns once
    /// its own probe has finished.
    ///
    /// So the two racers are unstructured on purpose. The loser is abandoned
    /// rather than awaited; when the real read finally answers, its `settle` is
    /// dropped on the floor. That abandonment has a cost worth naming: the
    /// losing task and its `TimeoutGate` stay resident until the read actually
    /// answers, so what this really buys is trading a pile of parked 512 KB OS
    /// threads for a much cheaper pile of suspended tasks — bounded in practice
    /// by the in-flight guard, which keeps at most one read outstanding.
    ///
    /// `nonisolated` on purpose. Without it both racers would inherit this
    /// class's implicit `@MainActor` and the deadline's own firing would be
    /// scheduled on the main actor — coupling the insurance to the resource it
    /// insures. It would not deadlock (the blocking probe is inside
    /// `OffMain.run` either way), but under main-actor saturation the timeout
    /// would queue behind whatever is saturating it, delaying precisely the
    /// safety net that matters most when the main actor is in trouble. Neither
    /// racer touches `self`, so there is nothing to keep here.
    private nonisolated func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let gate = TimeoutGate(continuation)
            let deadline = Task {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                gate.settle(.failure(CLICredentialTimeout()))
            }
            Task {
                do {
                    let value = try await work()
                    deadline.cancel()
                    gate.settle(.success(value))
                } catch {
                    deadline.cancel()
                    gate.settle(.failure(error))
                }
            }
        }
    }
}

/// One-shot resume guard for the timeout race above. Both racers finish
/// eventually — the deadline fires, and the abandoned read answers whenever the
/// consent dialog is finally dismissed — but a `CheckedContinuation` traps the
/// process on a second resume, so the loser has to be dropped rather than crash
/// the app hours after the fact.
///
/// Internal rather than `private` so `CLICredentialReaderTests` can assert the
/// one-shot behaviour directly. It is the most dangerous single line in this
/// file — a regression here surfaces as a process trap at an arbitrary later
/// moment, with nothing pointing back at the defect.
nonisolated final class TimeoutGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func settle(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
