//
//  CodexTokenRefresher.swift
//  Kwota
//
//  Owns freshness for Codex's bearer access token. Kwota does not refresh
//  the token itself — Codex CLI already does that and writes the rotated
//  value back to ~/.codex/auth.json. This refresher just re-reads from disk
//  when (a) the locally stored token is within `minLifetime` of expiry, or
//  (b) the API just rejected it with 401 (forceRefresh).
//

import Foundation

@MainActor
final class CodexTokenRefresher {
    private let reader: any CodexAuthReaderProviding
    private let store: KeychainCredentialStore
    private let now: () -> Date

    /// Memoization for freshen — avoids re-reading auth.json on burst ticks
    /// (popoverDidOpen + coord tick fire within milliseconds of each other).
    private struct FreshenCache {
        let profileId: UUID
        let credential: Credential
        let at: Date
    }
    private var lastFreshen: FreshenCache?
    private let freshenCacheTTL: TimeInterval = 10

    init(
        reader: any CodexAuthReaderProviding = CodexAuthReader(),
        store: KeychainCredentialStore,
        now: @escaping () -> Date = Date.init
    ) {
        self.reader = reader
        self.store = store
        self.now = now
    }

    /// Returns a credential whose access token is valid for at least
    /// `minLifetime` seconds. Cheap path returns `current` unchanged.
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
        // TTL cache to avoid stampedes during burst ticks.
        if let cached = lastFreshen,
           cached.profileId == profileId,
           now().timeIntervalSince(cached.at) < freshenCacheTTL,
           case .cliToken(_, _, let cachedExpiry) = cached.credential,
           cachedExpiry.timeIntervalSince(now()) > minLifetime {
            return cached.credential
        }
        guard let auth = reader.read() else {
            AppLog.shared.log(
                "CodexTokenRefresher.freshen: auth.json unreadable; keeping supplied credential",
                level: .warn
            )
            return current
        }
        guard case .cliToken(let oldAccess, _, _) = current,
              auth.accessToken != oldAccess
        else {
            // Same token — no rotation yet. Cache the no-op so we don't
            // touch disk again within TTL.
            lastFreshen = FreshenCache(profileId: profileId, credential: current, at: now())
            return current
        }
        let rotated = Credential.cliToken(
            accessToken: auth.accessToken,
            refreshToken: auth.refreshToken ?? "",
            // auth.json doesn't carry an expiresAt — assume a comfortable
            // window. Codex CLI re-rotates well before the actual token
            // lifetime expires, so anything > minLifetime works.
            expiresAt: now().addingTimeInterval(3600)
        )
        try store.write(rotated, for: profileId)
        lastFreshen = FreshenCache(profileId: profileId, credential: rotated, at: now())
        AppLog.shared.log("CodexTokenRefresher.freshen: rotated token written to store", level: .debug)
        return rotated
    }

    /// Re-reads auth.json after a 401. Returns nil when the token on disk
    /// matches the failing one (retrying would just 401 again).
    func forceRefresh(profileId: UUID, previous: Credential? = nil) throws -> Credential? {
        guard let auth = reader.read() else {
            AppLog.shared.log("CodexTokenRefresher.forceRefresh: auth.json unreadable", level: .warn)
            return nil
        }
        if case .cliToken(let oldAccess, _, _) = previous,
           auth.accessToken == oldAccess {
            AppLog.shared.log(
                "CodexTokenRefresher.forceRefresh: identical token on disk after 401, skipping retry",
                level: .warn
            )
            return nil
        }
        let rotated = Credential.cliToken(
            accessToken: auth.accessToken,
            refreshToken: auth.refreshToken ?? "",
            expiresAt: now().addingTimeInterval(3600)
        )
        try store.write(rotated, for: profileId)
        AppLog.shared.log("CodexTokenRefresher.forceRefresh: rotated token written to store", level: .info)
        return rotated
    }
}
