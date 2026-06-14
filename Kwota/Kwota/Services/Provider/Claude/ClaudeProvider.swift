//
//  ClaudeProvider.swift
//  Kwota
//

import SwiftUI

/// Claude-specific implementation of `AccountProvider`. Wraps the existing
/// `ClaudeAPIClient` / `CLICredentialReader` / `CLITokenRefresher` services
/// without changing their signatures so the rest of the app can keep
/// referencing those types directly while we migrate.
@MainActor
final class ClaudeProvider: AccountProvider {
    let id: ProviderID = .claude
    let displayName = "Claude"
    let iconAssetName = "Mascot"   // existing asset

    var reauthInstruction: String {
        "Run `claude login` in your terminal to refresh tokens. Kwota will pick up the new session automatically."
    }

    private let apiClient: ClaudeAPIClient
    private let cliReader: CLICredentialReader
    private let cliRefresher: CLITokenRefresher
    private let accountReader: OAuthAccountReader
    private let profileFetcher: any OAuthProfileFetching
    private let profileStore: ProfileStore

    init(
        apiClient: ClaudeAPIClient,
        cliReader: CLICredentialReader,
        cliRefresher: CLITokenRefresher,
        accountReader: OAuthAccountReader,
        profileFetcher: any OAuthProfileFetching,
        profileStore: ProfileStore
    ) {
        self.apiClient = apiClient
        self.cliReader = cliReader
        self.cliRefresher = cliRefresher
        self.accountReader = accountReader
        self.profileFetcher = profileFetcher
        self.profileStore = profileStore
    }

    var supportedAuthMethods: [any ProviderAuthMethod] {
        [
            ClaudeCLIAuthMethod(reader: cliReader, accountReader: accountReader),
        ]
    }

    /// Fetches a usage summary, branching on credential variant.
    ///
    /// CLI path: `freshen` → `fetchSnapshotViaOAuthUsage`, with one 401-retry
    /// after `forceRefresh` to absorb a CLI-rotated token without bouncing
    /// the user to the re-auth banner. RetryAfter from a usable 429 is
    /// surfaced through the summary so the shell can push the next tick out.
    ///
    /// Errors propagate as `ClaudeAPIClient.APIError` (`.unauthorized`,
    /// `.rateLimited(retryAfter:)`) — the shell already pattern-matches
    /// these to drive UI state. A generic `ProviderFetchError` is a
    /// follow-up; mapping is straightforward when a second provider arrives.
    func fetchUsage(credential: Credential, profile: Profile) async throws -> ProviderUsageSummary {
        let snapshot: UsageSnapshot
        var retryAfter: TimeInterval?

        switch credential {
        case .cliToken:
            let workingCredential = (try? cliRefresher.freshen(
                profileId: profile.id,
                current: credential
            )) ?? credential
            let result: ClaudeAPIClient.SnapshotFetch
            do {
                result = try await apiClient.fetchSnapshotViaOAuthUsage(
                    credential: workingCredential
                )
            } catch ClaudeAPIClient.APIError.unauthorized {
                // Stored token said it was valid but server disagrees —
                // force a re-read and retry once. Pass the failing
                // credential so forceRefresh can short-circuit when the
                // CLI keychain hasn't actually rotated.
                AppLog.shared.log(
                    "ClaudeProvider: 401 from oauth/usage, attempting forceRefresh and retry",
                    level: .info
                )
                if let retried = try? cliRefresher.forceRefresh(
                    profileId: profile.id,
                    previous: workingCredential
                ) {
                    result = try await apiClient.fetchSnapshotViaOAuthUsage(credential: retried)
                } else {
                    AppLog.shared.log(
                        "ClaudeProvider: forceRefresh returned nil — surfacing .unauthorized",
                        level: .warn
                    )
                    throw ClaudeAPIClient.APIError.unauthorized
                }
            }
            snapshot = result.snapshot
            retryAfter = result.retryAfter

        case .sessionKey:
            // Session-key auth retired; archived profiles never reach this
            // path because guardRefresh blocks them upstream.
            throw ClaudeAPIClient.APIError.unauthorized
        }

        return ProviderUsageSummary(
            providerID: .claude,
            fetchedAt: snapshot.fetchedAt,
            primary: snapshot.fiveHour,
            secondary: snapshot.sevenDay,
            payload: snapshot,
            retryAfter: retryAfter
        )
    }

    /// Re-runs `/api/oauth/profile` and applies the diff to the store —
    /// the same path the auto-profile coordinator's background probe uses,
    /// so a manual Refresh and the background refresh cannot diverge.
    /// Maps Anthropic API / network errors into the provider-agnostic
    /// `ProviderMetadataRefreshError` the shell renders as a banner.
    func refreshProfileMetadata(for profile: Profile, credential: Credential) async throws -> Bool {
        let response: OAuthProfileFetcher.Response
        do {
            response = try await profileFetcher.fetch(credential: credential)
        } catch ClaudeAPIClient.APIError.unauthorized {
            throw ProviderMetadataRefreshError.unauthorized
        } catch let ClaudeAPIClient.APIError.rateLimited(retry) {
            throw ProviderMetadataRefreshError.rateLimited(retryAfter: retry)
        } catch let urlError as URLError where ProviderMetadataRefreshError.isOfflineCode(urlError.code) {
            throw ProviderMetadataRefreshError.offline
        } catch {
            throw ProviderMetadataRefreshError.other(message: error.localizedDescription)
        }
        do {
            return try profileStore.apply(oauthProfile: response, for: profile.id)
        } catch ProfileStore.StoreError.identityMismatch {
            throw ProviderMetadataRefreshError.identityMismatch(
                message: "This account is bound to a different Claude login. Sign back into the matching Claude CLI account, or remove and re-add this entry.")
        } catch {
            throw ProviderMetadataRefreshError.other(message: "Could not save account: \(error.localizedDescription)")
        }
    }

    func usageDetailView(summary: ProviderUsageSummary,
                        history: [UsageHistoryEntry],
                        profile: Profile) -> AnyView {
        guard let snap = summary.payload as? UsageSnapshot else {
            return AnyView(EmptyView())
        }
        // Plan already comes pre-formatted from PlanFormatter — do not
        // apply `String.capitalized` (it splits "20x" → "20X"; the Free-plan
        // check uses caseInsensitiveCompare so casing is irrelevant here).
        let plan = profile.subscriptionPlan
        let isFree = MenuBarViewModel.computeIsFreePlan(plan: plan, snapshot: snap)
        return AnyView(ClaudeUsageDetailView(
            snapshot: snap,
            history: history,
            isFreePlan: isFree
        ))
    }

    func statsDetailView(store: StatsStore, profile: Profile) -> AnyView {
        AnyView(StatsDetailView(store: store, provider: .claude, profile: profile))
    }

    func planBadgeView(profile: Profile) -> AnyView {
        AnyView(PlanTextBadge(plan: profile.subscriptionPlan))
    }

    func installedComponents() async -> [InstalledComponent] {
        // Only the `claude` CLI ("Claude Code") shares persistence with
        // Kwota. `Claude.app` from Anthropic is a separate chat product
        // and never writes to `~/.claude/projects/*.jsonl`, so it would be
        // misleading to surface its version on the About card.
        do {
            guard let version = try await ClaudeProbe().run().version else { return [] }
            return [InstalledComponent(id: "claude-cli", label: "Claude Code", version: version)]
        } catch {
            AppLog.shared.log("ClaudeProvider.installedComponents probe failed: \(error)", level: .warn)
            return []
        }
    }

    func switcherBarTooltips(
        summary: ProviderUsageSummary
    ) -> (primary: String?, secondary: String?) {
        (
            Self.bucketTooltip(label: "5-hour usage", bucket: summary.primary),
            Self.bucketTooltip(label: "Weekly limit", bucket: summary.secondary)
        )
    }

    /// "5-hour usage: 23% remaining" / "Weekly limit: 80% remaining".
    /// Returns nil when the bucket has no utilization yet, so the
    /// switcher falls through to no tooltip rather than a stale "—%".
    static func bucketTooltip(label: String, bucket: UsageBucket?) -> String? {
        guard let util = bucket?.utilization else { return nil }
        let remaining = Int((100 - util).rounded())
        return "\(label): \(remaining)% remaining"
    }
}
