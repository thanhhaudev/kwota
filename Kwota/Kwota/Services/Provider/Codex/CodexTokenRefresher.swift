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
    ///
    /// `expectedEmail`, when non-nil, is compared against the on-disk
    /// identity AFTER the `auth.json` read resolves and BEFORE the result is
    /// written or used — closing the same race `CLITokenRefresher.freshen`
    /// closes via its `identityCheck` gate. `CodexProvider.fetchUsage`
    /// already checks the on-disk identity against `profile.email` before
    /// calling this method, but that check and this method's own read of
    /// `auth.json` are two separate reads: if the user runs `codex login` as
    /// a different account in the window between them, the pre-check's
    /// answer is stale by the time this method's read resolves, and without
    /// this second check the new account's token would be written under the
    /// old profile's id. `CodexAuthReader.Auth` (unlike Claude's
    /// `CLICredentialReader.SyncResult`) already carries `email` alongside
    /// the token, so no watcher indirection is needed — the check is simply
    /// "does the email on the read I just did match the profile I'm about
    /// to write to." `nil` means "no check possible" (either no expectation
    /// was supplied, or the JWT carried no email claim) — proceed exactly as
    /// before this fix so already-working profiles don't start failing.
    func freshen(
        profileId: UUID,
        current: Credential,
        minLifetime: TimeInterval = 60,
        expectedEmail: String? = nil
    ) async throws -> Credential {
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
        // Blocking-IO audit (F-006): auth.json read used to run inline on
        // the main actor. `freshen` is already async, so this is a
        // same-shape wrap — no behavior change, only where it runs.
        let reader = self.reader
        guard let auth = await OffMain.run({ reader.read() }) else {
            AppLog.shared.log(
                "CodexTokenRefresher.freshen: auth.json unreadable; keeping supplied credential",
                level: .warn
            )
            return current
        }
        // The account may have changed while the read above was outstanding.
        // Treated like the unreadable-auth.json arm above: `current` is still
        // the best token we have for *this* profile, and writing the other
        // account's token here would be the cross-account misattribution
        // this gate exists to prevent.
        if let expectedEmail, let onDisk = auth.email,
           onDisk.caseInsensitiveCompare(expectedEmail) != .orderedSame {
            AppLog.shared.log(
                "CodexTokenRefresher.freshen: CLI account (\(onDisk)) no longer matches profile \(profileId.uuidString.prefix(8)) after the auth.json read; keeping current token",
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
        try await store.write(rotated, for: profileId)
        lastFreshen = FreshenCache(profileId: profileId, credential: rotated, at: now())
        AppLog.shared.log("CodexTokenRefresher.freshen: rotated token written to store", level: .debug)
        return rotated
    }

    /// Re-reads auth.json after a 401. Returns nil when the token on disk
    /// matches the failing one (retrying would just 401 again).
    ///
    /// `expectedEmail` is the same post-read identity gate as `freshen`
    /// above — see its doc comment. `nil` result here means "skip the retry,
    /// surface .unauthorized," exactly like the existing same-token arm
    /// below, since retrying with (or persisting) a token that isn't
    /// provably this profile's account would be worse than surfacing the
    /// original 401.
    func forceRefresh(
        profileId: UUID,
        previous: Credential? = nil,
        expectedEmail: String? = nil
    ) async throws -> Credential? {
        let reader = self.reader
        guard let auth = await OffMain.run({ reader.read() }) else {
            AppLog.shared.log("CodexTokenRefresher.forceRefresh: auth.json unreadable", level: .warn)
            return nil
        }
        if let expectedEmail, let onDisk = auth.email,
           onDisk.caseInsensitiveCompare(expectedEmail) != .orderedSame {
            AppLog.shared.log(
                "CodexTokenRefresher.forceRefresh: CLI account (\(onDisk)) no longer matches profile \(profileId.uuidString.prefix(8)) after the auth.json read; skipping the retry",
                level: .warn
            )
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
        try await store.write(rotated, for: profileId)
        AppLog.shared.log("CodexTokenRefresher.forceRefresh: rotated token written to store", level: .info)
        return rotated
    }
}
