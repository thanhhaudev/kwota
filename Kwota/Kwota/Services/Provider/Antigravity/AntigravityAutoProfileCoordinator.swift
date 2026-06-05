//
//  AntigravityAutoProfileCoordinator.swift
//  Kwota
//
//  Drives ProfileStore from AntigravityProcessWatcher emits. Simplified
//  vs CodexAutoProfileCoordinator:
//    - Identity carries NO email — comes from API response later via the
//      provider's fetchUsage; coordinator creates with `name: "Antigravity"`
//      placeholder, email: nil.
//    - No keychain credential to seed (Antigravity's auth lives in the
//      external Antigravity.app — Kwota stores nothing).
//    - CSRF rotates per app launch, so re-promote-on-reappear uses a
//      "single archived Antigravity profile" heuristic (MVP single-account).
//

import Foundation

@MainActor
final class AntigravityAutoProfileCoordinator {
    private let watcher: any AntigravityProcessWatching
    private let profileStore: ProfileStore
    private let keychain: KeychainCredentialStore?
    private let clock: () -> Date
    private var lastHandled: AntigravityIdentity?
    private var hasHandled = false

    init(
        watcher: any AntigravityProcessWatching,
        profileStore: ProfileStore,
        keychain: KeychainCredentialStore? = nil,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.watcher = watcher
        self.profileStore = profileStore
        self.keychain = keychain
        self.clock = clock
    }

    /// Seeds a placeholder credential into the Keychain for an Antigravity
    /// profile. The shell's MenuBarViewModel.refresh aborts when no
    /// credential exists for a profile (line 1308) — Antigravity doesn't
    /// have OAuth-bearing credentials, but the gate still needs something
    /// to read. We write a marker `.cliToken` whose access/refresh tokens
    /// are empty strings; AntigravityProvider.fetchUsage ignores the
    /// credential anyway and pulls CSRF + port from the live watcher.
    private func seedPlaceholderCredential(for profileId: UUID) {
        guard let keychain else { return }
        let placeholder = Credential.cliToken(
            accessToken: "antigravity-marker",
            refreshToken: "",
            expiresAt: .distantFuture
        )
        try? keychain.write(placeholder, for: profileId)
    }

    func start() {
        watcher.onChange = { [weak self] identity in
            self?.handle(identity)
        }
    }

    private func handle(_ identity: AntigravityIdentity?) {
        if hasHandled && identity == lastHandled { return }
        hasHandled = true
        lastHandled = identity

        guard identity != nil else {
            // Process gone — archive the active Antigravity .auto profile (handing
            // focus to another live provider) AND any non-active Antigravity .auto
            // profile, so the store never carries a live-looking profile for a dead
            // process. The non-active case arises now that an appearing Antigravity
            // profile no longer steals focus from another provider.
            archiveActiveAntigravityProfile()
            archiveInactiveAntigravityAutoProfiles()
            return
        }

        // Process present. If there's already an active .auto Antigravity
        // profile, no-op (its csrfToken/port get refreshed downstream by
        // the provider reading the watcher's `current` at fetch time).
        if let activeId = profileStore.activeProfileId,
           let active = profileStore.profiles.first(where: { $0.id == activeId }),
           active.providerID == .antigravity, active.kind == .auto {
            return
        }

        // Re-promote-or-create heuristic.
        // Antigravity is single-account-per-machine in MVP — at most one
        // archived Antigravity profile can exist. If found, promote it
        // back to .auto rather than creating a duplicate. Scoping to
        // `.antigravity` ensures we never promote a different-provider
        // profile by accident.
        if let archived = profileStore.profiles.first(where: {
            $0.providerID == .antigravity && $0.kind == .archived
        }) {
            var promoted = archived
            promoted.kind = .auto
            try? profileStore.updateProfile(promoted)
            profileStore.activateOnAppearance(id: promoted.id, provider: .antigravity)
            seedPlaceholderCredential(for: promoted.id)
            demoteOtherAntigravityAutoProfiles(except: promoted.id)
            return
        }

        // No archived Antigravity profile and none currently active —
        // create a fresh one. Email + organization_id stay nil until the
        // provider's fetchUsage learns them from the API response.
        let new = Profile(
            name: "Antigravity",
            authMethod: .cliSync,
            providerID: .antigravity,
            organizationId: nil,
            subscriptionRenewsAt: nil,
            email: nil,
            kind: .auto,
            ownershipBoundary: clock()
        )
        try? profileStore.add(new)
        profileStore.activateOnAppearance(id: new.id, provider: .antigravity)
        seedPlaceholderCredential(for: new.id)
        demoteOtherAntigravityAutoProfiles(except: new.id)
    }

    /// Archives every Antigravity `.auto` profile that is not the active one.
    /// Active-profile re-home (when the gone profile WAS active) is handled by
    /// `archiveActiveAntigravityProfile`; this leaves `activeProfileId` alone.
    private func archiveInactiveAntigravityAutoProfiles() {
        for p in profileStore.profiles
        where p.providerID == .antigravity
            && p.kind == .auto
            && p.id != profileStore.activeProfileId {
            var demoted = p
            demoted.kind = .archived
            try? profileStore.updateProfile(demoted)
        }
    }

    private func demoteOtherAntigravityAutoProfiles(except activeId: UUID) {
        for p in profileStore.profiles
        where p.id != activeId
            && p.providerID == .antigravity
            && p.kind == .auto {
            var updated = p
            updated.kind = .archived
            try? profileStore.updateProfile(updated)
        }
    }

    /// Demotes the currently-active Antigravity `.auto` profile to `.archived`.
    /// Public for Task 9 use — the provider's terminal-auth-failure hook
    /// (rare for Antigravity since there's no OAuth, but kept for parity
    /// with the Codex / Claude shape) calls this on a hard fetch failure.
    /// Idempotent: when no active Antigravity .auto profile is around, no-op.
    func archiveActiveAntigravityProfile() {
        guard let activeId = profileStore.activeProfileId,
              let active = profileStore.profiles.first(where: { $0.id == activeId }),
              active.providerID == .antigravity,
              active.kind == .auto
        else {
            // Nothing to archive. Don't trample activeProfileId — another
            // provider may legitimately own it.
            return
        }
        var demoted = active
        demoted.kind = .archived
        try? profileStore.updateProfile(demoted)
        // Promote a different-provider .auto profile to active if one exists;
        // otherwise clear active.
        if let other = profileStore.profiles.first(where: {
            $0.providerID != .antigravity && $0.kind == .auto
        }) {
            try? profileStore.setActive(id: other.id)
        } else {
            try? profileStore.clearActive()
        }
    }
}
