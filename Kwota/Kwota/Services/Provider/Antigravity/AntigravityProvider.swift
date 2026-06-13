//
//  AntigravityProvider.swift
//  Kwota
//
//  AccountProvider conformance for Antigravity. Bridges the local-process
//  watcher and the localhost API client. The Credential parameter to
//  fetchUsage is ignored — auth is brokered by the running Antigravity.app
//  over loopback and identified per-request by the CSRF token from the
//  watcher's current identity. After a successful fetch, the snapshot's
//  email/name back-fill the profile so the menu bar reads the right user.
//

import SwiftUI
import AppKit

@MainActor
final class AntigravityProvider: AccountProvider {
    let id: ProviderID = .antigravity
    let displayName = "Antigravity"
    let iconAssetName = "AntigravityLogo"
    let supportedProfileDetailFields: Set<ProfileDetailField> = [.email, .plan]

    private let apiClient: AntigravityAPIClient
    private let watcher: any AntigravityProcessWatching
    private let profileStore: ProfileStore
    /// Read once per `fetchUsage`. Returns the modelCredits sentinels
    /// (overage toggle + AI-credit balance) or nil when the read fails —
    /// nil renders downstream as "no caption, no dimming, no fallback
    /// balance". Production callers use the default — which reads the real
    /// state.vscdb — and tests swap in a stub closure.
    private let readModelCredits: @MainActor () -> AntigravityModelCredits?

    /// Per-group usage history for the active Antigravity profile, keyed by
    /// group key. Assigned by MenuBarViewModel after construction; defaults to
    /// empty so unit tests and cold start render the chart skeletons.
    var groupHistoryProvider: @MainActor (UUID) -> [String: [UsageHistoryEntry]] = { _ in [:] }

    init(
        apiClient: AntigravityAPIClient,
        watcher: any AntigravityProcessWatching,
        profileStore: ProfileStore,
        readModelCredits: @MainActor @escaping () -> AntigravityModelCredits? = {
            AntigravityOverageReader().readModelCredits()
        }
    ) {
        self.apiClient = apiClient
        self.watcher = watcher
        self.profileStore = profileStore
        self.readModelCredits = readModelCredits
    }

    var supportedAuthMethods: [any ProviderAuthMethod] {
        [AntigravityAuthMethod(watcher: watcher)]
    }

    /// Thrown when `fetchUsage` runs while the watcher reports no live
    /// language_server. Caller (MenuBarViewModel) logs and falls back to
    /// cached snapshot; the watcher's next tick will archive the profile.
    struct IdentityMismatchError: Error, Equatable {
        let reason: String
    }

    /// Antigravity has no CLI; auth is the running app. The not-running case
    /// is the real "re-auth" prompt.
    var reauthInstruction: String {
        "Antigravity isn't running. Open the Antigravity app to refresh."
    }

    /// Antigravity has no CLI, so the default "<name> CLI session expired"
    /// title is wrong — the actual state is the app not running.
    var reauthTitle: String {
        "Antigravity isn't running"
    }

    /// Antigravity persists profile metadata (email/name/plan) as a
    /// side-effect of `fetchUsage`'s `backfillProfile`. Delegate to it,
    /// snapshotting the displayed fields before/after to report whether the
    /// store changed, and map the not-running case to a clear banner.
    func refreshProfileMetadata(for profile: Profile, credential: Credential) async throws -> Bool {
        let before = profileStore.profiles.first(where: { $0.id == profile.id })
        do {
            _ = try await fetchUsage(credential: credential, profile: profile)
        } catch is IdentityMismatchError {
            throw ProviderMetadataRefreshError.identityMismatch(
                message: "Antigravity isn't running. Open the Antigravity app, then refresh.")
        } catch let urlError as URLError where ProviderMetadataRefreshError.isOfflineCode(urlError.code) {
            throw ProviderMetadataRefreshError.offline
        } catch {
            throw ProviderMetadataRefreshError.other(message: error.localizedDescription)
        }
        let after = profileStore.profiles.first(where: { $0.id == profile.id })
        return before?.email != after?.email
            || before?.name != after?.name
            || before?.subscriptionPlan != after?.subscriptionPlan
    }

    func fetchUsage(credential: Credential, profile: Profile) async throws -> ProviderUsageSummary {
        // The Credential parameter is intentionally ignored — see file header.
        // Antigravity auth is brokered by the local language_server over
        // loopback, identified per-request by the CSRF token the watcher
        // surfaces. If the watcher has no current identity, the process is
        // gone (or hasn't been baselined yet) — surface IdentityMismatchError
        // so the shell logs and lets the coordinator's next tick archive
        // the profile naturally.
        guard let identity = watcher.current else {
            throw IdentityMismatchError(reason: "Antigravity language_server not detected")
        }

        var snapshot: AntigravityUsageSnapshot
        do {
            snapshot = try await apiClient.fetchSnapshot(
                port: identity.port,
                csrfToken: identity.csrfToken
            )
        } catch {
            throw error
        }

        // Backfill profile metadata from the snapshot. The watcher carries
        // no email/name at create-time — this is the moment they enter the
        // profile row.
        backfillProfile(profile, from: snapshot)

        // Authoritative quota (the Model Quota page). A miss degrades to nil —
        // identity/plan still render; the switcher + tab show "unavailable".
        var quota: AntigravityQuotaSummary?
        do {
            quota = try await apiClient.fetchQuotaSummary(
                port: identity.port, csrfToken: identity.csrfToken)
        } catch {
            AppLog.shared.log("AntigravityProvider: quota fetch failed: \(error)", level: .warn)
            quota = nil
        }

        let credits = readModelCredits()
        snapshot.overagesEnabled = credits?.overagesEnabled
        snapshot.aiCreditsFallback = credits?.availableCredits

        // primary = worst-group 5-hour window; secondary = worst-group weekly.
        // Reads like Claude/Codex (5h bar + weekly bar). Reset times carried.
        let primary = quota?.worstFiveHour.map {
            UsageBucket(utilization: $0.bucket.utilization, resetsAt: $0.bucket.resetTime)
        }
        let secondary = quota?.worstWeekly.map {
            UsageBucket(utilization: $0.bucket.utilization, resetsAt: $0.bucket.resetTime)
        }

        return ProviderUsageSummary(
            providerID: .antigravity,
            fetchedAt: snapshot.fetchedAt,
            primary: primary,
            secondary: secondary,
            payload: AntigravityUsagePayload(snapshot: snapshot, quota: quota),
            retryAfter: nil
        )
    }

    private func backfillProfile(_ profile: Profile, from snapshot: AntigravityUsageSnapshot) {
        // Re-read from the store so we don't clobber concurrent edits made
        // between the caller capturing `profile` and our successful fetch.
        guard let live = profileStore.profiles.first(where: { $0.id == profile.id }) else { return }
        var updated = live
        var changed = false
        if let email = snapshot.email, !email.isEmpty, live.email != email {
            updated.email = email
            changed = true
        }
        if let name = snapshot.name, !name.isEmpty, live.name != name {
            updated.name = name
            changed = true
        }
        // Prefer the canonical tier display name ("AI Pro" / "AI Free" /
        // "AI Ultra 5x" / "AI Ultra 20x") from AntigravityTier so the
        // switcher and badge stay in sync with the Usage tab. Fall back
        // to the raw wire `planName` only for unknown tiers, so we never
        // strip away a label we don't have a canonical form for.
        let canonical = snapshot.tier.displayName
        let plan = canonical ?? snapshot.planInfo?.planName
        if let plan, !plan.isEmpty, live.subscriptionPlan != plan {
            updated.subscriptionPlan = plan
            changed = true
        }
        guard changed else { return }
        do {
            try profileStore.updateProfile(updated)
        } catch {
            AppLog.shared.log(
                "AntigravityProvider: backfill updateProfile failed: \(error)",
                level: .warn
            )
        }
    }

    func usageDetailView(summary: ProviderUsageSummary,
                        history: [UsageHistoryEntry],
                        profile: Profile) -> AnyView {
        guard let payload = summary.payload as? AntigravityUsagePayload else {
            return AnyView(EmptyView())
        }
        return AnyView(AntigravityUsageDetailView(
            snapshot: payload.snapshot,
            history: history))
    }

    func planBadgeView(profile: Profile) -> AnyView {
        AnyView(AntigravityPlanBadgeView(profile: profile))
    }

    func installedComponents() async -> [InstalledComponent] {
        // Antigravity ships both `agy` (CLI) and `Antigravity.app` (IDE).
        // Both write to `~/.gemini/**/brain/**/transcript.jsonl`, so both
        // are valid chart signals — list whichever the user has installed.
        var out: [InstalledComponent] = []

        do {
            if let v = try await AgyProbe().run().version {
                out.append(InstalledComponent(id: "agy", label: "Antigravity CLI (agy)", version: v))
            }
        } catch {
            AppLog.shared.log("AntigravityProvider agy probe failed: \(error)", level: .warn)
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.antigravity"),
           let bundle = Bundle(url: url),
           let v = bundle.infoDictionary?["CFBundleShortVersionString"] as? String {
            out.append(InstalledComponent(id: "antigravity-app", label: "Antigravity.app", version: v))
        }

        return out
    }

    // MARK: - Switcher tooltip + dimming

    func switcherBarTooltips(
        summary: ProviderUsageSummary
    ) -> (primary: String?, secondary: String?) {
        guard let quota = (summary.payload as? AntigravityUsagePayload)?.quota else {
            return ("Quota unavailable", "Quota unavailable")
        }
        func tip(_ label: String, _ pair: (group: AntigravityQuotaSummary.Group,
                                           bucket: AntigravityQuotaSummary.Bucket)?) -> String? {
            guard let pair, let util = pair.bucket.utilization else { return "\(label): not tracked" }
            let remaining = Int((100 - util).rounded())
            let group = pair.group.displayName ?? "models"
            if let reset = pair.bucket.resetTime {
                return "\(label) · \(group) · \(remaining)% remaining · resets \(Self.formattedResetCountdown(until: reset))"
            }
            return "\(label) · \(group) · \(remaining)% remaining"
        }
        return (tip("5-hour", quota.worstFiveHour), tip("Weekly", quota.worstWeekly))
    }

    func switcherBarDimming(
        summary: ProviderUsageSummary
    ) -> (primary: Bool, secondary: Bool) {
        (false, false)
    }

    // MARK: - Renewal / reset estimate

    func renewalEstimate(profile: Profile,
                         summary: ProviderUsageSummary?,
                         now: Date) -> RenewalEstimate? {
        if let cycle = observedCreditCycleEstimate(profile: profile, now: now) { return cycle }
        if let quota = (summary?.payload as? AntigravityUsagePayload)?.quota {
            let soonest = quota.groups.flatMap { $0.buckets }.compactMap { $0.resetTime }.min()
            if let soonest { return RenewalEstimate(date: soonest, prefix: "Resets", absolute: false) }
        }
        return nil
    }

    func switcherRenewalEstimate(profile: Profile,
                                 summary: ProviderUsageSummary?,
                                 now: Date) -> RenewalEstimate? {
        if let reset = (summary?.payload as? AntigravityUsagePayload)?.quota?.worstFiveHour?.bucket.resetTime {
            return RenewalEstimate(date: reset, prefix: "Resets", absolute: false)
        }
        return observedCreditCycleEstimate(profile: profile, now: now)
    }

    /// Projected next AI-credit reset from the witnessed boundary +1 month,
    /// or nil before any reset has been observed. Shared by both renewal
    /// hooks so the stable cycle is expressed in exactly one place.
    private func observedCreditCycleEstimate(profile: Profile,
                                             now: Date) -> RenewalEstimate? {
        guard let anchor = profile.observedCreditResetAt,
              let next = RenewalEstimator.next(after: anchor, now: now) else {
            return nil
        }
        return RenewalEstimate(date: next, prefix: "Est. resets", absolute: true)
    }

    func evaluateCreditCycle(summary: ProviderUsageSummary,
                             profile: Profile,
                             now: Date) -> CreditCycleEvaluation? {
        guard let snapshot = (summary.payload as? AntigravityUsagePayload)?.snapshot else { return nil }
        // Trust ONLY a real-API wallet (userTier.availableCredits) — never the
        // state.vscdb fallback (aiCreditsFallback), which can be stale and fake
        // a jump — and a known ceiling. Without both we can't reason about a
        // reset, so leave the persisted reading untouched.
        guard let wallet = snapshot.availableCredits.first?.creditAmount,
              let ceiling = snapshot.tier.aiCreditsCeiling, ceiling > 0
        else { return nil }

        let current = CreditCycleReading(wallet: wallet, ceiling: ceiling)
        let previous: CreditCycleReading? = {
            guard let w = profile.lastCreditWallet,
                  let c = profile.lastCreditCeiling else { return nil }
            return CreditCycleReading(wallet: w, ceiling: c)
        }()
        let reset = didCreditCycleReset(previous: previous, current: current) ? now : nil
        return CreditCycleEvaluation(resetDetectedAt: reset,
                                     lastWallet: wallet,
                                     lastCeiling: ceiling)
    }

    /// Short countdown for "next reset in <time>". Matches the format
    /// the popover's per-model reset column uses ("2h 15m", "47m",
    /// "1d 4h"). `<1m` for sub-minute deltas; "now" for past targets.
    /// Kept package-internal for tests.
    static func formattedResetCountdown(until target: Date, now: Date = Date()) -> String {
        let delta = target.timeIntervalSince(now)
        if delta <= 0 { return "now" }
        let seconds = Int(delta)
        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24
        if days >= 1 { return "\(days)d \(hours % 24)h" }
        if hours >= 1 { return "\(hours)h \(minutes % 60)m" }
        if minutes >= 1 { return "\(minutes)m" }
        return "<1m"
    }
}
