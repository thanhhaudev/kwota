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
        // Cached, not raw: `probePlanFromProfile` awaits the credential import,
        // and that wait is only bounded because `CachedCLICredentialReader`
        // carries a timeout. A bare `CLICredentialReader()` here would leave any
        // caller that takes the default — a future test, a future call site —
        // awaiting a hung Keychain probe forever while holding `self` alive.
        credentialReader: any CLICredentialReading = CachedCLICredentialReader(),
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
            // Seed or update keychain. `identity` rides along so the import
            // can prove, after its own await, that the CLI is still signed
            // into the account this profile was matched from.
            let seed = seedOrUpdateKeychain(for: match.id, signedInAs: identity)
            profileStore.activateOnAppearance(id: match.id, provider: .claude)
            demoteOtherAutoProfiles(except: match.id)
            probePlanFromProfile(profileId: match.id, after: seed)
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
        let seed = seedOrUpdateKeychain(for: new.id, signedInAs: identity)
        profileStore.activateOnAppearance(id: new.id, provider: .claude)
        demoteOtherAutoProfiles(except: new.id)
        probePlanFromProfile(profileId: new.id, after: seed)
    }

    // MARK: - Private helpers

    /// Writes the current CLI credential into Kwota's Keychain for `id`. If a
    /// credential is already stored, compares the access token against the
    /// CLI's current token and overwrites only when they differ. A failure to
    /// read the CLI is silently skipped — the next emit will retry, and the
    /// API path's 401 forceRefresh recovers if Kwota is left on a stale token.
    ///
    /// Always returns the fire-and-forget task so the `/api/oauth/profile`
    /// probe (`probePlanFromProfile`) can wait for it — even on the
    /// already-covered path, where the task's own first step is the cheap
    /// "nothing to import" check below and it returns almost immediately.
    ///
    /// `handle(_:)` stays synchronous, which is why the import is a detached
    /// `Task` rather than an `await`: `handle` runs from `watcher.onChange`, a
    /// non-async closure with no caller that could await it, and its dedup latch
    /// (`hasHandled` / `lastHandled`) must be set before any suspension or two
    /// rapid identity emits could both pass the latch and both write.
    ///
    /// `signedInAs` is the identity `id` was matched from, and it is what the
    /// post-read re-check compares against so an account switch inside the
    /// suspension is caught rather than written through — see
    /// `stillSignedIn(as:)`, which also documents the window that remains.
    private func seedOrUpdateKeychain(for id: UUID, signedInAs identity: CLIIdentity) -> Task<Void, Never>? {
        // Fire-and-forget on purpose. Every step here already tolerates failure
        // (`try?`, nothing surfaced to the user), and the read below is the
        // cross-app probe that must never run on the main actor.
        return Task { [weak self] in
            guard let self else { return }
            // If Kwota already holds a non-expired CLI token for this profile,
            // there is nothing to import — skip the cross-app Keychain read
            // that would otherwise prompt the user (notably on the startup
            // baseline emit). The near-expiry refresh (CLITokenRefresher) and
            // 401 forceRefresh paths still read Claude Code's Keychain on
            // demand when a token is actually stale.
            //
            // This is Kwota's own Keychain item, which never raises the
            // cross-app consent dialog that F-003 hung on — but the read is
            // still async now that KeychainCredentialStore is, so it runs as
            // the task's first step rather than short-circuiting before the
            // task is created.
            do {
                if let stored = try await self.keychain.read(for: id),
                   case .cliToken(_, _, let expiresAt) = stored,
                   expiresAt.timeIntervalSinceNow > 60 {
                    return
                }
            } catch KeychainCredentialStore.KeychainError.interactionNotAllowed,
                    KeychainCredentialStore.KeychainError.timedOut {
                // Unknown, not absent. Importing on an unknown would risk
                // overwriting a perfectly good credential; the next emit retries.
                return
            } catch {
                // Any other read failure keeps the existing behaviour: fall
                // through and try the import.
            }
            guard let result = try? await self.credentialReader.read() else { return }
            // Re-prove the identity across the await before writing anything.
            // `credentialReader.read()` reads the one shared
            // `Claude Code-credentials` Keychain item: it is scoped to no
            // profile and no account, so what comes back is simply "whatever
            // the CLI is signed into right now", not "the token belonging to
            // `id`". The only thing bounding that read is the reader's own
            // timeout (10s for the default `CachedCLICredentialReader`), which
            // is an entirely plausible window for a `claude login` into a
            // second account to land in. Writing unconditionally would then
            // bind account B's access and refresh tokens to profile A, and
            // Kwota would go on to show B's usage under A's name — a silent
            // misattribution between two of the user's real accounts, and a
            // strictly worse outcome than the stale token this import exists
            // to replace. Skipping is safe by the same reasoning the doc
            // comment above already relies on for a failed read: the next
            // emit retries, and the 401 forceRefresh path recovers.
            guard self.stillSignedIn(as: identity) else {
                AppLog.shared.log(
                    "AutoProfileCoordinator: CLI account changed during the credential read for \(id.uuidString.prefix(8)); skipping the keychain write",
                    level: .warn
                )
                return
            }
            // Deliberately still `try?`, unlike the first read above: a denied
            // read here just skips the redundant-write check, and the value
            // written below (`result.credential`) was already read fresh from
            // the CLI and re-proven via `stillSignedIn(as:)` a few lines up —
            // so the worst case is one extra write of an already-verified,
            // already-correct token, never a wrong-account overwrite.
            if let stored = try? await self.keychain.read(for: id),
               self.accessTokensMatch(stored, result.credential) {
                return
            }
            try? await self.keychain.write(result.credential, for: id)
        }
    }

    /// True iff the CLI is still signed into the account `identity` described.
    ///
    /// Deliberately the same rule `guardRefresh` applies, just expressed
    /// between two identities rather than between an identity and a stored
    /// profile: email must match case-insensitively, and orgId must match only
    /// when the CLI supplies one. The nil-tolerance is not laxness — see
    /// `guardRefresh` for why `readCurrentIdentity` reports `orgId: nil` today
    /// — and requiring strict equality here would make every write fail rather
    /// than only the ones that should.
    ///
    /// No current identity at all (signed out mid-read) is a mismatch: there is
    /// no account to attribute the token to.
    ///
    /// **What this does and does not guarantee.** The comparison is made
    /// against `watcher.readCurrentIdentity()` — a fresh read of
    /// `~/.claude.json` at check time — and deliberately *not* against
    /// `watcher.current`, which is only refreshed through FSEvents behind a
    /// 0.3s debounce. Reading `current` would leave a switch that the CLI has
    /// already committed to disk invisible here for as long as the debounce
    /// takes to catch up, and the resulting mis-write does not self-heal: the
    /// `expiresAt` short-circuit at the top of `seedOrUpdateKeychain` would
    /// then skip every re-import until the wrongly-stored token nears expiry.
    ///
    /// What remains is bounded by the CLI's own writes, not by anything Kwota
    /// controls: `claude login` updates the Keychain item and `~/.claude.json`
    /// as two separate, unordered writes. If the credential read resolves with
    /// the new account's token in the gap *before* `~/.claude.json` is
    /// rewritten, this check still sees the old account and allows the write.
    /// That window is the CLI's inter-write gap rather than the reader's 10s
    /// timeout or the watcher's debounce, and it cannot be narrowed further
    /// from here: the credential the reader hands back carries only tokens and
    /// an expiry — no account identity to compare against.
    private func stillSignedIn(as identity: CLIIdentity) -> Bool {
        guard let current = watcher.readCurrentIdentity(),
              let currentEmail = current.email,
              let seededEmail = identity.email else { return false }
        let emailMatches = seededEmail.caseInsensitiveCompare(currentEmail) == .orderedSame
        let orgMatches = current.orgId == nil || identity.orgId == current.orgId
        return emailMatches && orgMatches
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
    private func probePlanFromProfile(profileId: UUID, after seed: Task<Void, Never>?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // The credential import is asynchronous now that the CLI Keychain
            // read is off the main actor, so a first-launch profile has nothing
            // stored yet at this point. Waiting for the import keeps the probe
            // from skipping exactly the profile that most needs enriching.
            //
            // This wait is bounded only by the injected reader's own timeout —
            // there is no deadline here. Every construction path must therefore
            // supply a timeout-bounded reader; the init default is
            // `CachedCLICredentialReader` for exactly this reason.
            await seed?.value
            guard let stored = try? await self.keychain.read(for: profileId) else {
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
    /// The CLI's identity is re-read at check time rather than taken from
    /// `watcher.current`. Every caller of this gate is about to start (or has
    /// just finished) an `await` — the fetch chain in `MenuBarViewModel.refresh`,
    /// the post-Keychain-read gate in `CLITokenRefresher` — so the answer has to
    /// reflect the account the CLI is signed into *now*, not the one the
    /// watcher's 0.3s-debounced pipeline last got around to publishing. The
    /// read is the same `~/.claude.json` parse the watcher performs on every
    /// file event, and it only happens for live Claude profiles: the archived,
    /// non-Claude and `alwaysAllowRefresh` short-circuits above all return
    /// first. Residual window: the CLI's Keychain write and its
    /// `~/.claude.json` write are unordered, so a refresh can still be allowed
    /// in the gap between them — see `stillSignedIn(as:)`.
    ///
    /// Email match is required. orgId match is required only when the CLI
    /// supplies one. `CLIAccountWatcher.readCurrentIdentity` currently always
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
        guard let current = watcher.readCurrentIdentity(),
              let email = current.email else { return false }
        let emailMatches = profile.email?.caseInsensitiveCompare(email) == .orderedSame
        let orgMatches = current.orgId == nil || profile.organizationId == current.orgId
        return emailMatches && orgMatches
    }
}
