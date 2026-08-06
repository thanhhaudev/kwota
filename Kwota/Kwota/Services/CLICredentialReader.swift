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
import OSLog

/// Seam that lets tests and higher-level services inject a CLI credential
/// source without touching `CLICredentialReader`'s real Keychain and
/// filesystem paths.
///
/// Both methods are `async`. The Keychain read goes through `KeychainGateway`,
/// which already leaves the main thread and bounds the wait — a consent
/// dialog for another app's Keychain item blocks whatever thread asks, and on
/// the main thread that freezes every keep-awake release path at once.
protocol CLICredentialReading: Sendable {
    func read() async throws -> CLICredentialReader.SyncResult
    func readFresh() async throws -> CLICredentialReader.SyncResult
    /// Interaction-aware fresh read, for the one caller that needs to drive
    /// a real `.allow` probe against the CLI's own Keychain item (the Grant
    /// flow — see `MenuBarViewModel.grantKeychainAccess()`). Defaulted so
    /// every existing conformer (test doubles included) keeps compiling
    /// without change; only `CLICredentialReader` and
    /// `CachedCLICredentialReader` give this a real, interaction-sensitive
    /// implementation.
    func readFresh(interaction: KeychainInteraction) async throws -> CLICredentialReader.SyncResult
}

extension CLICredentialReading {
    func readFresh() async throws -> CLICredentialReader.SyncResult {
        try await read()
    }

    func readFresh(interaction: KeychainInteraction) async throws -> CLICredentialReader.SyncResult {
        try await readFresh()
    }
}

/// Thrown when a credential read did not answer inside its deadline. In
/// practice that means an unanswered cross-app Keychain consent dialog: the
/// caller is released, the thread parked inside `SecItemCopyMatching` is not.
nonisolated struct CLICredentialTimeout: Error {}

/// Thrown when Claude Code's Keychain item refused the read because Kwota is
/// not on that item's ACL, and the legacy file could not stand in for it.
///
/// Deliberately distinct from every other read failure, because it is the one
/// that is recoverable by a single user action — the Grant banner's `.allow`
/// probe, answered with **Always Allow** — and because the alternative was
/// worse than useless: a denial that reaches the shell as
/// `APIError.unauthorized` renders as "Claude CLI session expired — run
/// claude login to refresh", which sends the user to fix an account that was
/// never broken. Nothing about the CLI session is wrong in this state; Kwota
/// simply cannot see the token.
nonisolated struct CLICredentialAccessDenied: Error {}

nonisolated struct CLICredentialReader {
    let credentialsFile: URL
    private let gateway: any KeychainGateways

    init(
        credentialsFile: URL = CLICredentialReader.defaultPath,
        gateway: any KeychainGateways = KeychainGateway.shared
    ) {
        self.credentialsFile = credentialsFile
        self.gateway = gateway
    }

    static var defaultPath: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/.credentials.json")
    }

    static let keychainService = "Claude Code-credentials"

    /// Observability for the one code path in this file that is designed to
    /// swallow failures.
    ///
    /// The `.deny` arm of `read(interaction:)` intentionally absorbs every
    /// gateway outcome and falls through to the file — a denial is the
    /// everyday background case, not something to surface as noise. The cost
    /// is that a denial, an absent item, and a payload whose shape drifted all
    /// used to look identical from outside: whatever error the *file* path
    /// happened to throw. That is precisely how a Keychain ACL denial spent
    /// hours masquerading as `keyNotFound: accessToken` while the Claude
    /// popover quietly served stale figures. These lines are what make the
    /// three distinguishable without a debugger attached.
    ///
    /// Deliberately NOT `AppLog`: this type is `nonisolated` and `AppLog` is
    /// `@MainActor` under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so
    /// routing through it would mean hopping to the main actor from the exact
    /// code path this whole branch exists to keep off it. A dedicated
    /// `Logger` category also means `log show --predicate 'category ==
    /// "credential-diag"'` can read these without the private-data profile
    /// `AppLog`'s blanket `.private` interpolation would otherwise require.
    ///
    /// Every interpolation below is `.public` on purpose and every one is a
    /// non-secret: a byte count, an enum case name, a file path. No token,
    /// refresh token, or payload body is ever passed in here.
    private static let diag = Logger(
        subsystem: "com.thanhhaudev.kwota",
        category: "credential-diag"
    )

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

    /// The gateway already leaves the main thread and bounds the wait, so this
    /// no longer wraps anything in `OffMain.run`. The legacy-file fallback is
    /// small and local, so it stays on the caller's executor.
    ///
    /// `.deny` (the routine background path — token refresh ticks, the
    /// auto-detect coordinator's seed) swallows every gateway error and
    /// falls through to the file exactly as before: a denial is the
    /// everyday, expected outcome here, not something to surface as new
    /// noise on every tick.
    ///
    /// `.allow` (the Grant flow — the one caller that needs to know whether
    /// the user actually granted access) is different: a denial/timeout on
    /// this attempt is the answer the caller is waiting for, so it
    /// propagates instead of being silently swapped for a generic "no such
    /// file" from the fallback. A genuinely absent Keychain item
    /// (`errSecItemNotFound`, surfaced by the gateway as `nil`, not an
    /// error) still falls through to the file on `.allow` too — that case
    /// was never a denial.
    func read(interaction: KeychainInteraction = .deny) async throws -> SyncResult {
        let mode = String(describing: interaction)
        // Set when the gateway refused the read outright — Kwota is not on
        // the CLI item's ACL. Decides which error this throws if the file
        // fallback also comes up empty: `CLICredentialAccessDenied` (one user
        // action away from fixed) rather than whatever unrelated error the
        // file path happened to produce.
        var deniedByKeychain = false
        do {
            // Split out of the original single `if let ... , let ... ` so the
            // three distinguishable keychain outcomes (threw / nil / returned
            // data that would not decode) can be told apart in the log.
            // Behaviour is unchanged: any outcome other than a decoded result
            // still falls through to the file.
            let data = try await gateway.read(
                service: Self.keychainService,
                account: nil,
                interaction: interaction
            )
            if let data {
                if let result = Self.decodeKeychainPayload(data) {
                    // `.info`, not `.debug`: os_log keeps `.debug` in memory
                    // only, so `log show` cannot see it after the fact. That
                    // makes success indistinguishable from "never ran" when
                    // checking whether a grant actually took — which is
                    // exactly the question asked right after granting. Volume
                    // is negligible (one line per profile per refresh tick).
                    Self.diag.info(
                        "read(\(mode, privacy: .public)): keychain HIT, \(data.count, privacy: .public) bytes decoded"
                    )
                    return result
                }
                Self.diag.error(
                    "read(\(mode, privacy: .public)): keychain returned \(data.count, privacy: .public) bytes but NEITHER envelope nor flat payload decoded (shape drift) — falling through to file"
                )
            } else {
                Self.diag.error(
                    "read(\(mode, privacy: .public)): keychain returned nil (errSecItemNotFound) — falling through to file"
                )
            }
        } catch let error as KeychainGatewayError {
            Self.diag.error(
                "read(\(mode, privacy: .public)): gateway threw \(String(describing: error), privacy: .public)"
            )
            if error == .interactionNotAllowed || error == .timedOut {
                if interaction == .allow { throw error }
                deniedByKeychain = true
            }
            // .deny, or an .allow attempt that hit some other unexpected
            // status: fall through to the file, matching prior behavior.
        }
        let file = credentialsFile
        let data = try await OffMain.run { try? Data(contentsOf: file) }
        guard let data else {
            Self.diag.error(
                "read(\(mode, privacy: .public)): file fallback — unreadable/absent at \(file.path, privacy: .public)"
            )
            if deniedByKeychain { throw CLICredentialAccessDenied() }
            throw CocoaError(.fileNoSuchFile)
        }
        let payload: Payload
        do {
            payload = try Self.decodePayload(data)
        } catch {
            Self.diag.error(
                "read(\(mode, privacy: .public)): file fallback decode FAILED on \(data.count, privacy: .public) bytes at \(file.path, privacy: .public) — \(String(describing: error), privacy: .public)"
            )
            if deniedByKeychain { throw CLICredentialAccessDenied() }
            throw error
        }
        // An already-expired legacy file cannot stand in for a denied
        // Keychain read. Kwota never refreshes CLI tokens — Claude Code is
        // the source of truth — so handing this one back can only produce a
        // 401, which the shell renders as "session expired" and which sends
        // the user to `claude login` for an account that is perfectly fine.
        // Reporting the denial instead routes them to the Grant banner, the
        // one action that actually fixes it. Deliberately gated on
        // `deniedByKeychain`: when the Keychain simply had no item, an
        // expired file is still the most truthful thing we know, and the
        // pre-existing behaviour of returning it is left alone.
        if deniedByKeychain, payload.expiresAt <= Date() {
            Self.diag.error(
                "read(\(mode, privacy: .public)): keychain denied and file token expired at \(payload.expiresAt.timeIntervalSince1970, privacy: .public) — surfacing CLICredentialAccessDenied"
            )
            throw CLICredentialAccessDenied()
        }
        Self.diag.debug(
            "read(\(mode, privacy: .public)): file fallback decoded OK, expiresAt=\(payload.expiresAt.timeIntervalSince1970, privacy: .public)"
        )
        return Self.makeResult(payload)
    }

    // `static` on purpose: these run inside the `@Sendable` closure above, and
    // an instance method would capture `self` across the isolation boundary.

    /// Decodes either shape Claude Code has ever written: the current
    /// `{"claudeAiOauth": {...}}` envelope, and the older flat payload.
    ///
    /// Shared by the Keychain path and the legacy-file path on purpose. The
    /// file path used to decode `Payload` directly, so it could only ever
    /// succeed on the flat shape — while the file on disk has carried the
    /// envelope for a long time. That made the fallback which exists
    /// precisely to cover a Keychain failure structurally incapable of ever
    /// covering one, and it reported every such failure as a baffling
    /// `keyNotFound: accessToken` sourced from the file rather than from the
    /// Keychain read that actually failed.
    private static func decodePayload(_ data: Data) throws -> Payload {
        let decoder = Self.decoder()
        do {
            return try decoder.decode(KeychainEnvelope.self, from: data).claudeAiOauth
        } catch {
            // Surface the envelope attempt's error when neither shape fits —
            // the envelope is the shape current Claude Code actually writes,
            // so its error is the more useful diagnostic of the two.
            guard let flat = try? decoder.decode(Payload.self, from: data) else { throw error }
            return flat
        }
    }

    private static func decodeKeychainPayload(_ data: Data) -> SyncResult? {
        guard let payload = try? decodePayload(data) else { return nil }
        return makeResult(payload)
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
    /// Spelled out explicitly (rather than relying on the default-parameter
    /// overload to satisfy the protocol requirement) so witness matching is
    /// unambiguous.
    func read() async throws -> SyncResult { try await read(interaction: .deny) }

    /// `CLICredentialReader.read()` is always a live Keychain probe, so a fresh
    /// read is just another read. Spelled out explicitly (rather than inheriting
    /// the protocol default) so the "always live" contract stays local: if a
    /// caching layer is ever added to `read()`, this must stay uncached to keep
    /// 401 recovery working.
    func readFresh() async throws -> SyncResult { try await read(interaction: .deny) }

    /// The Grant flow's entry point: a live, interaction-aware probe against
    /// Claude Code's own Keychain item. Spelled out explicitly for the same
    /// reason as `readFresh()` above.
    func readFresh(interaction: KeychainInteraction) async throws -> SyncResult {
        try await read(interaction: interaction)
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

    /// The Grant flow's entry point (`MenuBarViewModel.grantKeychainAccess()`):
    /// a rare, user-initiated `.allow` read that must reflect the TRUE live
    /// outcome of asking Claude Code's Keychain item right now — never a
    /// cached result, and never piggybacked onto an unrelated in-flight
    /// background probe.
    ///
    /// Deliberately bypasses every mechanism above (`entry`, `inFlight`,
    /// `withTimeout`) rather than threading `.allow` through them. That
    /// machinery exists to collapse the high-frequency background case
    /// (many callers, one shared probe, a short ceiling); reusing it here
    /// would mean either a background `.deny` probe's stale cache answering
    /// a "did the user just grant access" question, or an `.allow` read
    /// waiting behind — or being waited on by — a `.deny` probe it has
    /// nothing to do with. Going straight to the wrapped reader also means
    /// this call gets the gateway's own long `.allow` deadline
    /// (`KeychainGateway.allowTimeout`) instead of this wrapper's much
    /// shorter background `timeout`.
    func readFresh(interaction: KeychainInteraction) async throws -> CLICredentialReader.SyncResult {
        try await reader.readFresh(interaction: interaction)
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
