//
//  ProfileRowPresentation.swift
//  Kwota
//

import SwiftUI

/// Liveness inputs for a profile row, pulled from `MenuBarViewModel`
/// watchers at the call site. Keeping these as a value type (rather than a
/// `vm` reference) lets `ProfileRowPresentation` stay pure and unit-testable.
struct ProfileLivenessContext: Equatable {
    let claudeCLIEmail: String?
    let codexCLIEmail: String?
    let antigravityProcessAlive: Bool
}

/// Shared presentation rules for a profile row inside a `SettingsRow`.
/// Used by `ProfileHistoryCard` (Data & Storage) and `ShortcutsAccountsCard`
/// (Shortcuts) so the same account reads identically across Settings.
///
/// The `isLive` predicate delegates to `ProfileSwitcherCard.isLive(...)` —
/// the popup switcher's source of truth — so a row labelled `Offline` here
/// matches the set of accounts the switcher dims and Notifications hides.
enum ProfileRowPresentation {
    /// Email as the row title (masked when privacy is on), falling back to
    /// the auto-derived display name when the profile has no email yet.
    static func displayName(_ profile: Profile, privacyMasked: Bool) -> String {
        if let email = profile.email, !email.isEmpty {
            return privacyMasked ? (profile.maskedEmail ?? email) : email
        }
        return profile.resolvedDisplayName
    }

    /// Subscription plan (masked when privacy is on), or `nil` when no plan
    /// is known. Callers may concatenate additional context (e.g. an entry
    /// count in Storage) before rendering as the row subtitle.
    static func planSubtitle(_ profile: Profile, privacyMasked: Bool) -> String? {
        let plan = privacyMasked ? (profile.maskedPlan ?? "") : (profile.subscriptionPlan ?? "")
        return plan.isEmpty ? nil : plan
    }

    @MainActor
    static func isLive(_ profile: Profile, liveness: ProfileLivenessContext) -> Bool {
        ProfileSwitcherCard.isLive(
            profile: profile,
            claudeCLIEmail: liveness.claudeCLIEmail,
            codexCLIEmail: liveness.codexCLIEmail,
            antigravityProcessAlive: liveness.antigravityProcessAlive
        )
    }

    /// Provider pill, plus an `Offline` pill when the row is not live and
    /// the caller opts in. Caller supplies the provider's display name so
    /// this helper stays decoupled from `ProviderRegistry`.
    static func badges(
        for profile: Profile,
        providerName: String,
        isLive: Bool,
        includeOfflinePill: Bool = true
    ) -> [SettingsRowBadge] {
        var out: [SettingsRowBadge] = [
            ProviderBadgeStyle.badge(for: profile.providerID, name: providerName)
        ]
        if includeOfflinePill && !isLive {
            out.append(SettingsRowBadge(
                text: "Offline",
                foreground: .secondary,
                background: Color.secondary.opacity(0.15)
            ))
        }
        return out
    }

    /// Live profiles first, offline grouped at the bottom. Stable within
    /// each group so the on-disk profile order is preserved.
    ///
    /// Archived profiles are always excluded — they're a Provider-managed
    /// implementation detail (Antigravity in particular routinely archives
    /// stale auto profiles to avoid duplicates on process restart) and
    /// surfacing them in per-account UI is misleading. The rest of the
    /// codebase uses `kind == .auto && isLive` as the universal
    /// "displayable" predicate (see ProfileSwitcherCard.switcherSections,
    /// NotificationsMuteListCard, ManageProfilesView); we honour that here.
    @MainActor
    static func ordered(_ profiles: [Profile], liveness: ProfileLivenessContext) -> [Profile] {
        let autos = profiles.filter { $0.kind == .auto }
        return autos.filter { isLive($0, liveness: liveness) } +
               autos.filter { !isLive($0, liveness: liveness) }
    }
}
