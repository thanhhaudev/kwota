//
//  AutoProfileMigrator.swift
//  Kwota
//

import Foundation

/// One-shot migration from the manual-add era to auto-detect. Run by
/// `MenuBarViewModel` at app start, gated by a UserDefaults flag so it
/// performs at most once per install.
@MainActor
final class AutoProfileMigrator {
    private let profileStore: ProfileStore
    private let oauthRead: () -> OAuthAccountReader.Account?
    private let clock: () -> Date
    private let defaults: UserDefaults
    private let flagKey = "autoDetectMigrationCompleted"

    init(
        profileStore: ProfileStore,
        oauthRead: @escaping () -> OAuthAccountReader.Account? = { OAuthAccountReader().read() },
        clock: @escaping () -> Date = { Date() },
        defaults: UserDefaults = .standard
    ) {
        self.profileStore = profileStore
        self.oauthRead = oauthRead
        self.clock = clock
        self.defaults = defaults
    }

    func runIfNeeded() {
        guard !defaults.bool(forKey: flagKey) else { return }
        defer { defaults.set(true, forKey: flagKey) }

        let oauth = oauthRead()
        let now = clock()

        var promotedId: UUID?
        for profile in profileStore.profiles where profile.providerID == .claude {
            var updated = profile
            let matches: Bool = {
                guard let oauth, let oauthEmail = oauth.emailAddress, let pEmail = profile.email
                else { return false }
                return pEmail.caseInsensitiveCompare(oauthEmail) == .orderedSame
            }()
            if matches {
                updated.kind = .auto
                if updated.ownershipBoundary == nil {
                    updated.ownershipBoundary = profile.createdAt
                }
                // Sync plan + metadata from current oauth — legacy profiles may
                // have stale data or none at all. Always overwrite on promote.
                if let oauth {
                    let planLabel = PlanFormatter.format(
                        seatTier: oauth.seatTier,
                        organizationType: oauth.organizationType
                    )
                    updated.subscriptionPlan = planLabel
                    updated.subscriptionCreatedAt = oauth.subscriptionCreatedAt
                    if let displayName = oauth.displayName, !displayName.isEmpty {
                        updated.name = displayName
                    }
                }
                promotedId = profile.id
            } else {
                updated.kind = .archived
            }
            try? profileStore.updateProfile(updated)
        }

        if oauth != nil && promotedId == nil {
            let newProfile = Profile(
                name: oauth?.displayName ?? oauth?.emailAddress ?? "Claude account",
                authMethod: .cliSync,
                providerID: .claude,
                organizationId: nil,
                email: oauth?.emailAddress,
                kind: .auto,
                ownershipBoundary: now
            )
            try? profileStore.add(newProfile)
            promotedId = newProfile.id
        }

        if let promotedId {
            try? profileStore.setActive(id: promotedId)
        } else if oauth == nil {
            // No oauth, no promotion → no profile should be the live focus. Without
            // this the popover briefly renders an archived profile's cached snapshot
            // during the coordinator's debounce window on cold start.
            try? profileStore.clearActive()
        }
    }
}
