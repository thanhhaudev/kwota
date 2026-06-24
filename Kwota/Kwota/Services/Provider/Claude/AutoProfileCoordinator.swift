//
//  AutoProfileCoordinator.swift
//  Kwota
//

import Foundation

/// Drives `ProfileStore` from `CLIAccountWatcher` emits and gates the
/// refresh path. This is the bridge that ensures a refresh for profile A
/// never executes while the CLI is signed into account B.
@MainActor
final class AutoProfileCoordinator {
    private let watcher: any CLIAccountWatching
    private let profileStore: ProfileStore
    private let keychain: KeychainCredentialStore
    private let credentialReader: any CLICredentialReading
    private let profileFetcher: any OAuthProfileFetching
    private let clock: () -> Date
    private var lastHandled: CLIIdentity?
    private var hasHandled = false
    /// Test seam: when true, `guardRefresh` always returns `true` without
    /// consulting the watcher. Set via `init(alwaysAllowRefresh:)` to let
    /// unit tests that construct a VM and call `refresh` directly bypass the
    /// CLI-identity check (which would always deny in test mode because the
    /// watcher is never started and `current` is nil).
    private let alwaysAllowRefresh: Bool

    init(
        watcher: any CLIAccountWatching,
        profileStore: ProfileStore,
        keychain: KeychainCredentialStore = KeychainCredentialStore.live(),
        credentialReader: any CLICredentialReading = CLICredentialReader(),
        profileFetcher: any OAuthProfileFetching = OAuthProfileFetcher(),
        clock: @escaping () -> Date = { Date() },
        alwaysAllowRefresh: Bool = false
    ) {
        self.watcher = watcher
        self.profileStore = profileStore
        self.keychain = keychain
        self.credentialReader = credentialReader
        self.profileFetcher = profileFetcher
        self.clock = clock
        self.alwaysAllowRefresh = alwaysAllowRefresh
    }

    func start() {
        watcher.onChange = { [weak self] identity in
            self?.handle(identity)
        }
    }

    private func handle(_ identity: CLIIdentity?) {
        if hasHandled && identity == lastHandled { return }
        hasHandled = true
        lastHandled = identity

        guard let identity, let email = identity.email else {
            // Sign-out path: demote the active .auto profile only when it belongs to
            // this coordinator's provider (.claude). A Codex profile that happens to
            // be active must not be archived just because Claude logged out.
            let activeWasClaudeAuto: Bool
            if let currentId = profileStore.activeProfileId,
               let active = profileStore.profiles.first(where: { $0.id == currentId }),
               active.providerID == .claude,
               active.kind == .auto {
                var demoted = active
                demoted.kind = .archived
                try? profileStore.updateProfile(demoted)
                activeWasClaudeAuto = true
            } else {
                activeWasClaudeAuto = false
            }
            // Re-home active focus. When the signed-out account owned the active
            // profile, hand off to a live other-provider auto so the popover lands
            // on a usable account — another provider's appearance no longer steals
            // focus, so this is the only path that hands it off. Otherwise clear.
            // When the active profile belongs to another provider, leave it
            // untouched (only clear if no live auto exists anywhere, preserving
            // prior cleanup).
            let otherProviderAuto = profileStore.profiles.first {
                $0.providerID != .claude && $0.kind == .auto
            }
            if activeWasClaudeAuto {
                if let otherProviderAuto {
                    try? profileStore.setActive(id: otherProviderAuto.id)
                } else {
                    try? profileStore.clearActive()
                }
            } else if otherProviderAuto == nil {
                try? profileStore.clearActive()
            }
            return
        }

        // Email-only fallbacks (auto and archived) only fire when the
        // watcher cannot supply an orgId. Once /me-based resolution lands
        // and the watcher emits a real orgId, the strict composite match
        // is the only path that can reuse a stored profile — an unrelated
        // archived profile from a different organization with the same
        // email must not be resurrected just because emails happen to
        // collide.
        //
        // The final cascade step (findByEmailAwaitingOrg) handles the
        // migration window: profiles created during the nil-orgId era
        // have organizationId stored as nil. When the watcher starts
        // emitting non-nil orgIds, those legacy profiles would otherwise
        // be unmatchable. This step picks them up by email + nil-stored-
        // org and the orgId-sync block below writes the freshly-learned
        // orgId onto the profile so subsequent emits land on the strict
        // composite path.
        let match = profileStore.findMatching(providerID: .claude, email: email, orgId: identity.orgId)
            ?? (identity.orgId == nil ? profileStore.findAutoByEmail(providerID: .claude, email) : nil)
            ?? (identity.orgId == nil ? profileStore.findArchivedByEmail(providerID: .claude, email) : nil)
            ?? (identity.orgId != nil ? profileStore.findByEmailAwaitingOrg(providerID: .claude, email) : nil)
        if let match {
            if match.kind == .archived {
                var updated = match
                updated.kind = .auto
                try? profileStore.updateProfile(updated)
            }
            // Sync metadata from the current oauth identity when it differs.
            // expectedPlan is derived from identity-only fields here. When the
            // CLI's oauthAccount no longer carries seatTier/organizationType
            // (the current state for paid Max users), expectedPlan is nil —
            // and a nil value must NEVER overwrite a stored non-nil plan, or
            // the badge regresses to "Free" on app restart. Same rule applies
            // to subscriptionCreatedAt. The richer source (/api/oauth/profile)
            // is queried opportunistically in `probePlanFromProfile`; this
            // block is just the defensive baseline.
            let expectedPlan = PlanFormatter.format(
                seatTier: identity.seatTier,
                organizationType: identity.organizationType
            )
            let identityHasNewerOrgId = identity.orgId != nil
                && match.organizationId != identity.orgId
            let planMismatch = expectedPlan != nil
                && match.subscriptionPlan != expectedPlan
            let createdAtMismatch = identity.subscriptionCreatedAt != nil
                && match.subscriptionCreatedAt != identity.subscriptionCreatedAt
            let nameMismatch = identity.displayName != nil
                && match.name != identity.displayName
            let needsMetadataUpdate =
                planMismatch || createdAtMismatch || nameMismatch || identityHasNewerOrgId
            if needsMetadataUpdate {
                var updated = profileStore.profiles.first(where: { $0.id == match.id }) ?? match
                if let expectedPlan { updated.subscriptionPlan = expectedPlan }
                if let createdAt = identity.subscriptionCreatedAt {
                    updated.subscriptionCreatedAt = createdAt
                }
                if nameMismatch, let name = identity.displayName { updated.name = name }
                // Adopt the freshly-learned orgId. Only fires when the
                // stored value is nil OR identity-side has a newer value;
                // the strict composite path above prevents cross-org
                // overwrites because it would only have matched on equal
                // orgIds in the first place.
                if let newOrgId = identity.orgId, match.organizationId != newOrgId {
                    updated.organizationId = newOrgId
                }
                try? profileStore.updateProfile(updated)
            }
            // Seed or update keychain.
            seedOrUpdateKeychain(for: match.id)
            profileStore.activateOnAppearance(id: match.id, provider: .claude)
            demoteOtherAutoProfiles(except: match.id)
            probePlanFromProfile(profileId: match.id)
            return
        }

        let planLabel = PlanFormatter.format(
            seatTier: identity.seatTier,
            organizationType: identity.organizationType
        )
        let new = Profile(
            name: identity.displayName ?? email,
            authMethod: .cliSync,
            providerID: .claude,
            organizationId: identity.orgId,
            subscriptionPlan: planLabel,
            subscriptionCreatedAt: identity.subscriptionCreatedAt,
            email: email,
            kind: .auto,
            ownershipBoundary: clock()
        )
        try? profileStore.add(new)
        // Seed keychain for the freshly-created profile.
        seedOrUpdateKeychain(for: new.id)
        profileStore.activateOnAppearance(id: new.id, provider: .claude)
        demoteOtherAutoProfiles(except: new.id)
        probePlanFromProfile(profileId: new.id)
    }

    // MARK: - Private helpers

    /// Writes the current CLI credential into Kwota's Keychain for `id`. If a
    /// credential is already stored, compares the access token against the
    /// CLI's current token and overwrites only when they differ. A failure to
    /// read the CLI is silently skipped — the next emit will retry, and the
    /// API path's 401 forceRefresh recovers if Kwota is left on a stale token.
    private func seedOrUpdateKeychain(for id: UUID) {
        // If Kwota already holds a non-expired CLI token for this profile,
        // there is nothing to import — skip the cross-app Keychain read that
        // would otherwise prompt the user (notably on the startup baseline
        // emit). The near-expiry refresh (CLITokenRefresher) and 401
        // forceRefresh paths still read Claude Code's Keychain on demand when
        // a token is actually stale.
        if let stored = try? keychain.read(for: id),
           case .cliToken(_, _, let expiresAt) = stored,
           expiresAt.timeIntervalSinceNow > 60 {
            return
        }
        guard let result = try? credentialReader.read() else { return }
        if let stored = try? keychain.read(for: id),
           accessTokensMatch(stored, result.credential) {
            return
        }
        try? keychain.write(result.credential, for: id)
    }

    /// True iff both credentials are `.cliToken` with the same access token.
    /// Used to skip a redundant Keychain write when nothing has rotated.
    private func accessTokensMatch(_ a: Credential, _ b: Credential) -> Bool {
        if case .cliToken(let aT, _, _) = a,
           case .cliToken(let bT, _, _) = b {
            return aT == bT
        }
        return false
    }

    /// Demotes every `.auto` profile whose id is not `activeId` to `.archived`,
    /// enforcing the invariant that at most one auto profile exists at a time.
    private func demoteOtherAutoProfiles(except activeId: UUID) {
        for p in profileStore.profiles
        where p.id != activeId && p.providerID == .claude && p.kind == .auto {
            var updated = p
            updated.kind = .archived
            try? profileStore.updateProfile(updated)
        }
    }

    /// Fire-and-forget probe of `/api/oauth/profile` to enrich the stored
    /// plan label and metadata. Runs on the MainActor and captures
    /// `profileId` explicitly so a fast A→B→A account switch lands each
    /// response on the correct profile rather than the one that happens
    /// to be active when the network call returns.
    ///
    /// Failure modes (401, 429, network, decode) log a warning and abort —
    /// the stored fields are never overwritten with a nil value, so the
    /// worst case is a stale-but-correct badge, never a Max→Free downgrade.
    /// Delegates the write path to `ProfileStore.apply(oauthProfile:for:)`
    /// so the user-initiated refresh action shares one diff rule.
    private func probePlanFromProfile(profileId: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let stored = try? self.keychain.read(for: profileId) else {
                AppLog.shared.log(
                    "OAuthProfile: no keychain credential for \(profileId.uuidString.prefix(8)); skipping probe",
                    level: .info
                )
                return
            }
            let response: OAuthProfileFetcher.Response
            do {
                response = try await self.profileFetcher.fetch(credential: stored)
            } catch {
                AppLog.shared.log(
                    "OAuthProfile: probe failed for \(profileId.uuidString.prefix(8)): \(error)",
                    level: .warn
                )
                return
            }
            let changed: Bool
            do {
                changed = try self.profileStore.apply(oauthProfile: response, for: profileId)
            } catch ProfileStore.StoreError.identityMismatch(let stored, let response) {
                AppLog.shared.log(
                    "OAuthProfile: identity mismatch for \(profileId.uuidString.prefix(8)) — stored \(stored), response \(response); refusing merge",
                    level: .warn
                )
                return
            } catch {
                AppLog.shared.log(
                    "OAuthProfile: persist failed for \(profileId.uuidString.prefix(8)): \(error)",
                    level: .warn
                )
                return
            }
            if changed {
                AppLog.shared.log(
                    "OAuthProfile: applied changes for \(profileId.uuidString.prefix(8))",
                    level: .info
                )
            }
        }
    }

    /// Returns true iff refreshing `profile` is safe right now: the profile
    /// must be auto AND its identity must match the CLI's current identity.
    /// This is the loop-close for the chart-contamination bug — a refresh of
    /// profile A while the CLI is signed into account B is denied.
    ///
    /// Email match is required. orgId match is required only when the watcher
    /// supplies one. `CLIAccountWatcher.computeCurrent` currently always
    /// reports `orgId: nil` because `~/.claude.json`'s `oauthAccount` block
    /// does not carry organizationUuid — so a strict equality check would
    /// reject every migrated profile whose `organizationId` was populated by
    /// the wizard era. The mirror of this nil-tolerance lives in
    /// `ProfileStore.findAutoByEmail`, which the coordinator falls back to
    /// when the same watcher emits a nil-orgId identity. When `/me`-based
    /// resolution lands and the watcher starts emitting real orgIds, this
    /// check tightens automatically.
    ///
    /// When `alwaysAllowRefresh` is set (test seam), this always returns true
    /// so unit tests that call refresh directly are not blocked by the watcher
    /// being idle.
    func guardRefresh(profile: Profile) -> Bool {
        if alwaysAllowRefresh { return true }
        if profile.kind == .archived { return false }
        // Non-Claude profiles are not gated by Claude's CLI watcher.
        if profile.providerID != .claude { return true }
        guard let current = watcher.current, let email = current.email else { return false }
        let emailMatches = profile.email?.caseInsensitiveCompare(email) == .orderedSame
        let orgMatches = current.orgId == nil || profile.organizationId == current.orgId
        return emailMatches && orgMatches
    }
}
