//
//  CLITokenRefresher.swift
//  Kwota
//
//  Owns the freshness contract for `.cliSync` credentials. Wraps the read
//  side of `Claude Code-credentials` keychain (via CLICredentialReader) and
//  the write side of Kwota's own credential keychain (KeychainCredentialStore).
//
//  Strategy: read the live CLI keychain on-demand only — when the locally
//  stored access token is within `minLifetime` of expiry, or when the API
//  has just rejected it (forceRefresh). Cheap path returns the supplied
//  credential without any I/O so timer-driven refreshes don't trigger an
//  OS keychain prompt every tick.
//

import Foundation

@MainActor
final class CLITokenRefresher {
    private let reader: any CLICredentialReading
    private let store: KeychainCredentialStore
    private let now: () -> Date

    /// Cached result của lần freshen() cuối kèm timestamp. Dùng để skip
    /// `reader.read()` nếu lần gọi freshen kế tiếp xảy ra trong cùng window
    /// — tránh prompt Touch ID-protected keychain nhiều lần khi coordinator
    /// tick + popoverDidOpen fire sát nhau.
    private struct FreshenCache {
        let profileId: UUID
        let credential: Credential
        let at: Date
    }
    private var lastFreshen: FreshenCache?
    private let freshenCacheTTL: TimeInterval = 10

    /// Post-read identity gate: "is the CLI still signed into the account this
    /// profile belongs to?", asked *after* a read resolves and *before* the
    /// result is written or used.
    ///
    /// A pre-check cannot answer this. `MenuBarViewModel.refresh` already asks
    /// `guardRefresh` once, synchronously, before the whole fetch chain starts —
    /// but the read below is the shared, unscoped `Claude Code-credentials`
    /// item, and the only bound on it is the reader's own timeout. A `claude
    /// login` into a second account inside that window makes the answer a token
    /// for a different account than the one the pre-check approved, and both
    /// methods here would persist it to `profileId` and immediately fetch with
    /// it — account B's usage recorded under account A's profile.
    ///
    /// A `var` rather than an init-only `let` because the production gate is
    /// `AutoProfileCoordinator.guardRefresh`, and the coordinator is built
    /// *after* the refresher in `MenuBarViewModel.init` (the same two-phase
    /// wiring `liveAccountRecorder` uses there). Defaults to always-allow so
    /// every existing call site — tests, the hosted-test host, any construction
    /// that has no watcher to consult — behaves exactly as before.
    var identityCheck: (UUID) -> Bool

    init(
        reader: any CLICredentialReading = CLICredentialReader(),
        store: KeychainCredentialStore,
        now: @escaping () -> Date = Date.init,
        identityCheck: @escaping (UUID) -> Bool = { _ in true }
    ) {
        self.reader = reader
        self.store = store
        self.now = now
        self.identityCheck = identityCheck
    }

    /// Returns a credential whose CLI access token is valid for at least
    /// `minLifetime` seconds. Reads `Claude Code-credentials` and writes
    /// the fresh token back to Kwota's keychain only when needed; the cheap
    /// path (token still has headroom) returns `current` unchanged with no
    /// keychain I/O. Non-CLI credentials are returned as-is.
    func freshen(
        profileId: UUID,
        current: Credential,
        minLifetime: TimeInterval = 60
    ) async throws -> Credential {
        guard case .cliToken(_, _, let expiresAt) = current else {
            return current
        }
        if expiresAt.timeIntervalSince(now()) > minLifetime {
            return current
        }
        // Memoization: nếu vừa freshen profile này trong freshenCacheTTL
        // giây, return credential đã rotate ở lần trước. Tránh đụng keychain
        // (có thể prompt Touch ID) cho mỗi tick refresh xảy ra sát nhau.
        if let cached = lastFreshen,
           cached.profileId == profileId,
           now().timeIntervalSince(cached.at) < freshenCacheTTL,
           case .cliToken(_, _, let cachedExpiry) = cached.credential,
           cachedExpiry.timeIntervalSince(now()) > minLifetime {
            return cached.credential
        }
        let result: CLICredentialReader.SyncResult
        do {
            result = try await reader.read()
        } catch is CLICredentialTimeout {
            // A consent dialog nobody answered must not stall the refresh tick.
            // `current` is still the best token we have — the API path's 401
            // forceRefresh recovers if it turns out to be stale.
            AppLog.shared.log(
                "CLITokenRefresher.freshen timed out reading the CLI keychain; keeping current token",
                level: .warn
            )
            return current
        } catch {
            AppLog.shared.log(
                "CLITokenRefresher.freshen reader failed: \(String(describing: error))",
                level: .warn
            )
            throw error
        }
        // The account may have changed while the read above was outstanding.
        // Treated exactly like the timeout arm: `current` is still the best
        // token we have for *this* profile, and the 401 forceRefresh path
        // recovers if it turns out to be stale. Writing the other account's
        // token here would be the failure this gate exists to prevent, and
        // caching it in `lastFreshen` would keep serving it for the rest of
        // the TTL — so this returns before both.
        guard identityCheck(profileId) else {
            AppLog.shared.log(
                "CLITokenRefresher.freshen: CLI account no longer matches profile \(profileId.uuidString.prefix(8)) after the keychain read; keeping current token",
                level: .warn
            )
            return current
        }
        guard case .cliToken(let newAccess, _, _) = result.credential,
              case .cliToken(let oldAccess, _, _) = current,
              newAccess != oldAccess
        else {
            // Reader returned identical access token — CLI hasn't rotated yet.
            // Keep the supplied credential, do not rewrite the store.
            AppLog.shared.log(
                "CLITokenRefresher.freshen: CLI returned identical token (no rotation), no write",
                level: .debug
            )
            lastFreshen = FreshenCache(profileId: profileId, credential: current, at: now())
            return current
        }
        try await store.write(result.credential, for: profileId)
        AppLog.shared.log(
            "CLITokenRefresher.freshen: CLI rotated, wrote new token to store",
            level: .debug
        )
        lastFreshen = FreshenCache(profileId: profileId, credential: result.credential, at: now())
        return result.credential
    }

    /// Re-reads `Claude Code-credentials` after an API 401 to recover from
    /// server-side revocation or clock skew that `freshen` couldn't detect
    /// locally. Returns nil if (a) the read fails, or (b) the read produced
    /// the same access token as `previous` — in case (b) retrying the API
    /// call would just 401 again, so we report failure and skip the write.
    func forceRefresh(
        profileId: UUID,
        previous: Credential? = nil
    ) async throws -> Credential? {
        let result: CLICredentialReader.SyncResult
        do {
            result = try await reader.readFresh()
        } catch is CLICredentialAccessDenied {
            // The one read failure that must NOT collapse into `nil`. `nil`
            // makes the caller surface `.unauthorized`, which the shell
            // renders as an expired session — the wrong diagnosis for a
            // Keychain ACL denial, and one that points the user at
            // `claude login` instead of at the Grant banner that actually
            // fixes it. Rethrown so the reason survives all the way up.
            AppLog.shared.log(
                "CLITokenRefresher.forceRefresh: CLI keychain denied access — surfacing as access-denied, not as an expired session",
                level: .warn
            )
            throw CLICredentialAccessDenied()
        } catch {
            // Deliberately no separate `CLICredentialTimeout` arm: a timeout is
            // just another read failure here, and returning nil is already the
            // right answer — the caller surfaces `.unauthorized` rather than
            // retrying the API with a token it could not re-read.
            AppLog.shared.log(
                "CLITokenRefresher.forceRefresh reader failed: \(String(describing: error))",
                level: .warn
            )
            return nil
        }
        // Same post-read gate as `freshen`, with this method's own failure
        // shape: nil, so the caller surfaces `.unauthorized` instead of
        // retrying the API with a bearer that belongs to another account —
        // and, worse, persisting it under this profile first.
        guard identityCheck(profileId) else {
            AppLog.shared.log(
                "CLITokenRefresher.forceRefresh: CLI account no longer matches profile \(profileId.uuidString.prefix(8)) after the keychain read; skipping the retry",
                level: .warn
            )
            return nil
        }
        if case .cliToken(let newAccess, _, _) = result.credential,
           case .cliToken(let oldAccess, _, _) = previous,
           newAccess == oldAccess {
            // CLI hasn't rotated since the call that just 401'd. Retrying
            // with the same token would burn another API call to no effect,
            // and rewriting the store would be redundant.
            AppLog.shared.log(
                "CLITokenRefresher.forceRefresh: CLI returned identical token after 401, skipping retry",
                level: .warn
            )
            return nil
        }
        try await store.write(result.credential, for: profileId)
        AppLog.shared.log(
            "CLITokenRefresher.forceRefresh: CLI rotated, wrote new token for retry",
            level: .info
        )
        return result.credential
    }
}
