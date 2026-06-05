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
    private let reader: CLICredentialReader
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

    init(
        reader: CLICredentialReader = CLICredentialReader(),
        store: KeychainCredentialStore,
        now: @escaping () -> Date = Date.init
    ) {
        self.reader = reader
        self.store = store
        self.now = now
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
    ) throws -> Credential {
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
            result = try reader.read()
        } catch {
            AppLog.shared.log(
                "CLITokenRefresher.freshen reader failed: \(String(describing: error))",
                level: .warn
            )
            throw error
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
        try store.write(result.credential, for: profileId)
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
    ) throws -> Credential? {
        let result: CLICredentialReader.SyncResult
        do {
            result = try reader.read()
        } catch {
            AppLog.shared.log(
                "CLITokenRefresher.forceRefresh reader failed: \(String(describing: error))",
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
        try store.write(result.credential, for: profileId)
        AppLog.shared.log(
            "CLITokenRefresher.forceRefresh: CLI rotated, wrote new token for retry",
            level: .info
        )
        return result.credential
    }
}
