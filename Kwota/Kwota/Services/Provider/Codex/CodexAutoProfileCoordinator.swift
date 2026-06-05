//
//  CodexAutoProfileCoordinator.swift
//  Kwota
//
//  Drives ProfileStore from CodexAccountWatcher emits. Mirrors Claude's
//  AutoProfileCoordinator: match-or-create on login, smart clearActive on
//  sign-out (only when no other-provider auto profile is live).
//

import Foundation

@MainActor
final class CodexAutoProfileCoordinator {
    private let watcher: any CodexAccountWatching
    private let profileStore: ProfileStore
    private let keychain: KeychainCredentialStore
    private let authReader: any CodexAuthReaderProviding
    private let clock: () -> Date
    private var lastHandled: CodexIdentity?
    private var hasHandled = false

    init(
        watcher: any CodexAccountWatching,
        profileStore: ProfileStore,
        keychain: KeychainCredentialStore = KeychainCredentialStore.live(),
        authReader: any CodexAuthReaderProviding = CodexAuthReader(),
        clock: @escaping () -> Date = { Date() }
    ) {
        self.watcher = watcher
        self.profileStore = profileStore
        self.keychain = keychain
        self.authReader = authReader
        self.clock = clock
    }

    func start() {
        watcher.onChange = { [weak self] identity in
            self?.handle(identity)
        }
    }

    private func handle(_ identity: CodexIdentity?) {
        if hasHandled && identity == lastHandled { return }
        hasHandled = true
        lastHandled = identity

        guard let identity else {
            // Truly signed out: auth.json missing or no access_token.
            // Demote the active Codex .auto profile only.
            if let currentId = profileStore.activeProfileId,
               let active = profileStore.profiles.first(where: { $0.id == currentId }),
               active.providerID == .codex,
               active.kind == .auto {
                var demoted = active
                demoted.kind = .archived
                try? profileStore.updateProfile(demoted)
            }
            // Clear active only when no other-provider .auto profile is
            // around to take focus.
            let hasOtherProviderAuto = profileStore.profiles.contains {
                $0.providerID != .codex && $0.kind == .auto
            }
            if hasOtherProviderAuto,
               let other = profileStore.profiles.first(where: {
                   $0.providerID != .codex && $0.kind == .auto
               }) {
                try? profileStore.setActive(id: other.id)
            } else {
                try? profileStore.clearActive()
            }
            return
        }

        guard let email = identity.email else {
            // Authenticated but unidentified: access_token is present in
            // auth.json but the id_token is missing or its email claim is
            // unparseable. Treating this as sign-out would archive an
            // already-active Codex profile that's still authenticated —
            // a regression caught in the Codex adversarial review. Instead
            // we no-op: the user IS logged in (token is valid), we just
            // can't safely match or create a profile without an identity.
            // A future watcher emit with a parseable JWT will succeed.
            AppLog.shared.log(
                "CodexAutoProfileCoordinator: token present but identity.email nil "
                + "(unparseable id_token?); keeping current state, no profile mutation",
                level: .warn
            )
            return
        }

        // Match cascade — same shape as Claude's, just scoped to .codex.
        // Codex's accountId is OpenAI's account UUID; it goes into the
        // existing orgId slot of the ProfileStore lookup APIs.
        let match = profileStore.findMatching(providerID: .codex, email: email, orgId: identity.accountId)
            ?? (identity.accountId == nil ? profileStore.findAutoByEmail(providerID: .codex, email) : nil)
            ?? (identity.accountId == nil ? profileStore.findArchivedByEmail(providerID: .codex, email) : nil)
            ?? (identity.accountId != nil ? profileStore.findByEmailAwaitingOrg(providerID: .codex, email) : nil)

        if let match {
            if match.kind == .archived {
                var updated = match
                updated.kind = .auto
                try? profileStore.updateProfile(updated)
            }
            // Sync accountId if newly learned.
            if let newAccountId = identity.accountId,
               match.organizationId != newAccountId {
                var updated = profileStore.profiles.first(where: { $0.id == match.id }) ?? match
                updated.organizationId = newAccountId
                try? profileStore.updateProfile(updated)
            }
            // Sync display name if the JWT carries one and it differs.
            // The JWT-sourced name is authoritative — auto profiles don't
            // have a user-rename UI today, so silent overwrite is safe.
            if let newName = identity.name, newName != match.name {
                var updated = profileStore.profiles.first(where: { $0.id == match.id }) ?? match
                if updated.name != newName {
                    updated.name = newName
                    try? profileStore.updateProfile(updated)
                }
            }
            // Sync renewal date when the JWT-sourced value differs. Normalize
            // to whole-second precision so the equality check matches
            // `Profile.normalize` storage shape; without this we'd thrash
            // the store on every poll tick.
            if let newRenewsAt = identity.subscriptionActiveUntil {
                var updated = profileStore.profiles.first(where: { $0.id == match.id }) ?? match
                let normalized = Date(timeIntervalSince1970: floor(newRenewsAt.timeIntervalSince1970))
                if updated.subscriptionRenewsAt != normalized {
                    updated.subscriptionRenewsAt = normalized
                    try? profileStore.updateProfile(updated)
                }
            }
            profileStore.activateOnAppearance(id: match.id, provider: .codex)
            seedKeychain(for: match.id)
            demoteOtherCodexAutoProfiles(except: match.id)
            return
        }

        let new = Profile(
            name: identity.name ?? email,
            authMethod: .cliSync,
            providerID: .codex,
            organizationId: identity.accountId,
            subscriptionRenewsAt: identity.subscriptionActiveUntil,
            email: email,
            kind: .auto,
            ownershipBoundary: clock()
        )
        try? profileStore.add(new)
        profileStore.activateOnAppearance(id: new.id, provider: .codex)
        seedKeychain(for: new.id)
        demoteOtherCodexAutoProfiles(except: new.id)
    }

    /// Seeds (or refreshes) the Keychain credential for a Codex profile from
    /// the current `auth.json`. Skips the write when the stored access token
    /// is already up-to-date so we don't thrash the Keychain on every watcher
    /// emit.
    private func seedKeychain(for profileId: UUID) {
        guard let auth = authReader.read() else { return }
        let credential = Credential.cliToken(
            accessToken: auth.accessToken,
            refreshToken: auth.refreshToken ?? "",
            expiresAt: clock().addingTimeInterval(3600)
        )
        // Only overwrite if the access token differs — avoids Keychain thrash.
        if let existing = try? keychain.read(for: profileId),
           case .cliToken(let oldAccess, _, _) = existing,
           oldAccess == auth.accessToken {
            return
        }
        try? keychain.write(credential, for: profileId)
    }

    private func demoteOtherCodexAutoProfiles(except activeId: UUID) {
        for p in profileStore.profiles
        where p.id != activeId && p.providerID == .codex && p.kind == .auto {
            var updated = p
            updated.kind = .archived
            try? profileStore.updateProfile(updated)
        }
    }
}
