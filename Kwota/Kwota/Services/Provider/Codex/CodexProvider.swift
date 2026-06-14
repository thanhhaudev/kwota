//
//  CodexProvider.swift
//  Kwota
//

import SwiftUI
import AppKit

@MainActor
final class CodexProvider: AccountProvider {
    let id: ProviderID = .codex
    let displayName = "Codex"
    let iconAssetName = "CodexLogo"
    let supportedProfileDetailFields: Set<ProfileDetailField> = [.email, .orgUUID]

    var reauthInstruction: String {
        "Run `codex login` in your terminal to refresh tokens. Kwota will pick up the new session automatically."
    }

    private let apiClient: CodexAPIClient
    private let authReader: any CodexAuthReaderProviding
    private let tokenRefresher: CodexTokenRefresher
    private let profileStore: ProfileStore

    init(
        apiClient: CodexAPIClient,
        authReader: any CodexAuthReaderProviding,
        tokenRefresher: CodexTokenRefresher,
        profileStore: ProfileStore
    ) {
        self.apiClient = apiClient
        self.authReader = authReader
        self.tokenRefresher = tokenRefresher
        self.profileStore = profileStore
    }

    var supportedAuthMethods: [any ProviderAuthMethod] {
        // The reader cast is safe at runtime — authReader is the live
        // `CodexAuthReader` in production. Tests don't render the wizard.
        guard let concrete = authReader as? CodexAuthReader else { return [] }
        return [CodexAuthMethod(reader: concrete)]
    }

    /// Thrown by `fetchUsage` when the on-disk Codex CLI identity disagrees
    /// with the profile we were asked to refresh — most commonly the user
    /// has signed the CLI in as a different ChatGPT account, and the
    /// CodexAccountWatcher hasn't yet re-pointed `activeProfileId`. Falls
    /// through to MenuBarViewModel's generic catch so it's logged but
    /// doesn't surface a scary banner; the coordinator's next debounce
    /// tick re-orients the active profile.
    struct IdentityMismatchError: Error, Equatable {
        let profileEmail: String?
        let onDiskEmail: String?
    }

    /// Refresh the profile fields the Codex detail sheet shows (email,
    /// org UUID) plus name/renewal. Codex metadata is normally synced by
    /// `CodexAutoProfileCoordinator` from the on-disk `~/.codex/auth.json`
    /// identity; a manual Refresh re-reads that identity and reconciles the
    /// same fields on demand, then re-runs `fetchUsage` to validate auth and
    /// surface expiry. Unlike the coordinator it never repoints/creates a
    /// profile — an account mismatch is reported, not silently re-bound.
    func refreshProfileMetadata(for profile: Profile, credential: Credential) async throws -> Bool {
        guard let auth = authReader.read() else {
            // No on-disk identity → the Codex CLI is signed out.
            throw ProviderMetadataRefreshError.unauthorized
        }
        if let onDisk = auth.email, let target = profile.email,
           onDisk.caseInsensitiveCompare(target) != .orderedSame {
            throw ProviderMetadataRefreshError.identityMismatch(
                message: "The Codex CLI is signed in as a different account. Switch the Codex CLI back to this account, or remove and re-add this entry.")
        }
        let changed = reconcileProfile(profile, with: auth)

        do {
            _ = try await fetchUsage(credential: credential, profile: profile)
        } catch ClaudeAPIClient.APIError.unauthorized {
            throw ProviderMetadataRefreshError.unauthorized
        } catch let ClaudeAPIClient.APIError.rateLimited(retry) {
            throw ProviderMetadataRefreshError.rateLimited(retryAfter: retry)
        } catch is CodexProvider.IdentityMismatchError {
            throw ProviderMetadataRefreshError.identityMismatch(
                message: "The Codex CLI is signed in as a different account. Switch the Codex CLI back to this account, or remove and re-add this entry.")
        } catch let urlError as URLError where ProviderMetadataRefreshError.isOfflineCode(urlError.code) {
            throw ProviderMetadataRefreshError.offline
        } catch {
            throw ProviderMetadataRefreshError.other(message: error.localizedDescription)
        }
        return changed
    }

    /// Sync `organizationId` / `name` / `subscriptionRenewsAt` from the
    /// on-disk identity, mirroring `CodexAutoProfileCoordinator`'s per-emit
    /// sync (including whole-second renewal normalization so we don't thrash
    /// against the coordinator). Email is deliberately left alone — an email
    /// change is the mismatch path, not a silent reconcile. Returns whether
    /// the store changed.
    private func reconcileProfile(_ profile: Profile, with auth: CodexAuthReader.Auth) -> Bool {
        guard let live = profileStore.profiles.first(where: { $0.id == profile.id }) else { return false }
        var updated = live
        var changed = false
        if let accountId = auth.accountId, live.organizationId != accountId {
            updated.organizationId = accountId
            changed = true
        }
        if let name = auth.name, !name.isEmpty, live.name != name {
            updated.name = name
            changed = true
        }
        if let plan = PlanFormatter.format(auth.planType), live.subscriptionPlan != plan {
            updated.subscriptionPlan = plan
            changed = true
        }
        if let renewsAt = auth.subscriptionActiveUntil {
            let normalized = Date(timeIntervalSince1970: floor(renewsAt.timeIntervalSince1970))
            if live.subscriptionRenewsAt != normalized {
                updated.subscriptionRenewsAt = normalized
                changed = true
            }
        }
        guard changed else { return false }
        try? profileStore.updateProfile(updated)
        return true
    }

    func fetchUsage(credential: Credential, profile: Profile) async throws -> ProviderUsageSummary {
        // Identity guard. Compare the live `~/.codex/auth.json` identity to
        // the profile we're refreshing BEFORE we touch the token refresher
        // or the network. Without this, a CLI-switched-account race window
        // (between sign-in on disk and the watcher's debounce committing
        // the new activeProfileId) would let us fetch the new account's
        // usage and attribute it to the old profile.
        let onDiskEmail = authReader.read()?.email
        let targetEmail = profile.email
        let identityMatches: Bool
        if let onDiskEmail, let targetEmail {
            identityMatches = onDiskEmail.caseInsensitiveCompare(targetEmail) == .orderedSame
        } else {
            identityMatches = false
        }
        guard identityMatches else {
            throw IdentityMismatchError(profileEmail: targetEmail, onDiskEmail: onDiskEmail)
        }

        let workingCredential = (try? tokenRefresher.freshen(
            profileId: profile.id,
            current: credential
        )) ?? credential

        let snapshot: CodexUsageSnapshot
        do {
            snapshot = try await apiClient.fetchSnapshot(credential: workingCredential)
        } catch ClaudeAPIClient.APIError.unauthorized {
            AppLog.shared.log(
                "CodexProvider: 401 from wham/usage, attempting forceRefresh and retry",
                level: .info
            )
            if let retried = try? tokenRefresher.forceRefresh(
                profileId: profile.id,
                previous: workingCredential
            ) {
                snapshot = try await apiClient.fetchSnapshot(credential: retried)
            } else {
                AppLog.shared.log(
                    "CodexProvider: forceRefresh returned nil — surfacing .unauthorized",
                    level: .warn
                )
                throw ClaudeAPIClient.APIError.unauthorized
            }
        }

        // UsageBucket.utilization is in 0-100 range across the app — the
        // chart's footnote formatter does `Int(u)` and the threshold compare
        // `u < UsageLevel.warningThreshold` both assume 0-100. Codex's
        // `used_percent` is already in that range, so pass it through verbatim.
        let primary = snapshot.rateLimit?.primaryWindow.map { window in
            UsageBucket(
                utilization: window.usedPercent,
                resetsAt: window.resetAt
            )
        }
        let secondary = snapshot.rateLimit?.secondaryWindow.map { window in
            UsageBucket(
                utilization: window.usedPercent,
                resetsAt: window.resetAt
            )
        }

        // Debug-level shape probe so future schema drift surfaces in
        // Console.app with full field shapes, without spamming .info on
        // every poll tick. Pair with the fall-through error log in
        // MenuBarViewModel.refresh, which captures decode failures at
        // .error level regardless of this setting.
        let primaryPct = snapshot.rateLimit?.primaryWindow?.usedPercent
        let secondaryPct = snapshot.rateLimit?.secondaryWindow?.usedPercent
        let creditsBal = snapshot.credits?.balance
        let primaryStr = primaryPct.map { String($0) } ?? "nil"
        let secondaryStr = secondaryPct.map { String($0) } ?? "nil"
        let creditsStr = creditsBal.map { String($0) } ?? "nil"
        AppLog.shared.log(
            "CodexProvider: parsed snapshot — planType=\(snapshot.planType ?? "nil"), primaryUsedPct=\(primaryStr), secondaryUsedPct=\(secondaryStr), creditsBalance=\(creditsStr), codeReview=\(snapshot.codeReviewRateLimit != nil)",
            level: .debug
        )

        return ProviderUsageSummary(
            providerID: .codex,
            fetchedAt: snapshot.fetchedAt,
            primary: primary,
            secondary: secondary,
            payload: snapshot,
            retryAfter: nil
        )
    }

    func usageDetailView(summary: ProviderUsageSummary,
                        history: [UsageHistoryEntry],
                        profile: Profile) -> AnyView {
        guard let snap = summary.payload as? CodexUsageSnapshot else {
            return AnyView(EmptyView())
        }
        let plan = (snap.planType ?? "").lowercased()
        let isFree = (plan == "free")
        return AnyView(CodexUsageDetailView(
            snapshot: snap,
            history: history,
            isFreePlan: isFree
        ))
    }

    func statsDetailView(store: StatsStore, profile: Profile) -> AnyView {
        AnyView(StatsDetailView(store: store, provider: .codex, profile: profile))
    }

    func planBadgeView(profile: Profile) -> AnyView {
        AnyView(PlanTextBadge(plan: profile.subscriptionPlan))
    }

    func installedComponents() async -> [InstalledComponent] {
        // Codex.app and the `codex` CLI share `~/.codex/sessions/` + auth,
        // so both are valid signals — surface whichever (or both) the user
        // has installed.
        var out: [InstalledComponent] = []

        do {
            if let v = try await CodexProbe().run().version {
                out.append(InstalledComponent(id: "codex-cli", label: "Codex CLI", version: v))
            }
        } catch {
            AppLog.shared.log("CodexProvider codex CLI probe failed: \(error)", level: .warn)
        }

        if let v = Self.bundleVersion(bundleIdentifier: "com.openai.codex") {
            out.append(InstalledComponent(id: "codex-app", label: "Codex.app", version: v))
        }

        return out
    }

    private static func bundleVersion(bundleIdentifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
              let bundle = Bundle(url: url) else {
            return nil
        }
        return bundle.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    func switcherBarTooltips(
        summary: ProviderUsageSummary
    ) -> (primary: String?, secondary: String?) {
        (
            ClaudeProvider.bucketTooltip(label: "5-hour usage", bucket: summary.primary),
            ClaudeProvider.bucketTooltip(label: "Weekly limit", bucket: summary.secondary)
        )
    }

    func switcherBarDimming(
        summary: ProviderUsageSummary
    ) -> (primary: Bool, secondary: Bool) {
        // Free-plan rows still get a live 5-hour primary, so leave that bar
        // colored. The weekly secondary isn't meaningful on free — surface
        // it as "data present but inactive" (grey gradient) to match the
        // popover which hides the Weekly section entirely. Same dimming
        // semantic Antigravity uses for AI Credits with overages off.
        guard let snap = summary.payload as? CodexUsageSnapshot,
              (snap.planType ?? "").lowercased() == "free" else {
            return (false, false)
        }
        return (primary: false, secondary: true)
    }
}
