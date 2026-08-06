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

    /// Claude's plan tier lives behind `/api/oauth/profile` (via
    /// `refreshProfileMetadata` → `OAuthProfileFetcher`), an endpoint
    /// distinct from the `/api/oauth/usage` bars `fetchUsage` reads — so a
    /// post-usage manual re-probe costs one extra GET, not a duplicate usage
    /// fetch. See `AccountProvider.hasSeparatePlanMetadataRefresh`.
    let hasSeparatePlanMetadataRefresh = true

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

    /// Whether a CLI token is already past its expiry. Only ever consulted to
    /// decide that a request is pointless — never to decide a token is good,
    /// so clock skew can at worst cost one wasted call, never a false denial.
    private static func isExpired(_ credential: Credential, now: Date = Date()) -> Bool {
        guard case .cliToken(_, _, let expiresAt) = credential else { return false }
        return expiresAt <= now
    }

    /// Fetches a usage summary, branching on credential variant.
    ///
    /// CLI path: `freshen` → `fetchSnapshotViaOAuthUsage`, with one 401-retry
    /// after `forceRefresh` to absorb a CLI-rotated token without bouncing
    /// the user to the re-auth banner. RetryAfter from a usable 429 is
    /// surfaced through the summary so the shell can push the next tick out.
    ///
    /// Errors propagate as `ClaudeAPIClient.APIError` (`.unauthorized`,
    /// `.rateLimited(retryAfter:)`) plus `CLICredentialAccessDenied` — the
    /// shell already pattern-matches these to drive UI state. A generic
    /// `ProviderFetchError` is a follow-up; mapping is straightforward when
    /// a second provider arrives.
    func fetchUsage(credential: Credential, profile: Profile) async throws -> ProviderUsageSummary {
        let snapshot: UsageSnapshot
        var retryAfter: TimeInterval?

        switch credential {
        case .cliToken:
            // `try?` here would be wrong for exactly one of `freshen`'s
            // failures. Every other one leaves `credential` as a reasonable
            // bet — it may well still be valid, and the 401 retry below
            // recovers if it is not. A Keychain ACL denial paired with an
            // ALREADY-EXPIRED stored token is different: Kwota cannot see the
            // token Claude Code rotated to, and the one it still holds is
            // dead, so the request below cannot succeed. Spending it anyway
            // is how this surfaced as "Rate limited by Anthropic" — the
            // doomed calls pile up until the server throttles them, and the
            // 429 arm of `refresh(profile:)` then reports a rate limit and
            // backs off, burying the single thing the user can actually fix.
            // Bail before the request so the Grant banner is what they see.
            let workingCredential: Credential
            do {
                workingCredential = try await cliRefresher.freshen(
                    profileId: profile.id,
                    current: credential
                )
            } catch is CLICredentialAccessDenied where Self.isExpired(credential) {
                AppLog.shared.log(
                    "ClaudeProvider: CLI keychain denied and the stored token has already expired — surfacing access-denied without spending a request",
                    level: .warn
                )
                throw CLICredentialAccessDenied()
            } catch {
                workingCredential = credential
            }
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
                // `try?` would flatten a Keychain ACL denial into the same
                // `nil` as every other re-read failure, and `nil` here means
                // `.unauthorized` — i.e. "your CLI session expired". For a
                // denial that diagnosis is simply wrong: the session is fine
                // and only the Grant banner can fix it, so that one error is
                // let through untouched.
                let retried: Credential?
                do {
                    retried = try await cliRefresher.forceRefresh(
                        profileId: profile.id,
                        previous: workingCredential
                    )
                } catch is CLICredentialAccessDenied {
                    AppLog.shared.log(
                        "ClaudeProvider: CLI keychain denied on the 401 retry — surfacing access-denied so the shell shows Grant, not the re-auth banner",
                        level: .warn
                    )
                    throw CLICredentialAccessDenied()
                } catch {
                    retried = nil
                }
                if let retried {
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
