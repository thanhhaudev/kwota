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

        // Attach the modelCredits sentinels to the snapshot so downstream
        // views (popover caption + switcher bar dimming) can read them from
        // `summary.payload`. The available-credit balance becomes the
        // wallet fallback when the API returned none. Reader failures
        // degrade to nil = "unknown".
        let credits = readModelCredits()
        snapshot.overagesEnabled = credits?.overagesEnabled
        snapshot.aiCreditsFallback = credits?.availableCredits

        // primary  = worst-model utilization (the most-constrained model
        //            across all rate-limited models). Surface this on the
        //            switcher row so a single glance shows the model
        //            closest to its cap.
        // secondary = AI Credits utilization. Wallet vs tier ceiling.
        //            Nil when tier has no ceiling (Free / Unknown).
        let primary = snapshot.worstModelUtilization.map { util in
            UsageBucket(utilization: util, resetsAt: nil)
        }
        let secondary = snapshot.aiCreditsUtilization.map { util in
            UsageBucket(utilization: util, resetsAt: nil)
        }

        AppLog.shared.log(
            "AntigravityProvider: parsed snapshot — plan=\(snapshot.planInfo?.planName ?? "nil"), worstModelUtil=\(snapshot.worstModelUtilization.map { String(format: "%.1f", $0) } ?? "nil"), aiCreditsUtil=\(snapshot.aiCreditsUtilization.map { String(format: "%.1f", $0) } ?? "nil"), overagesEnabled=\(snapshot.overagesEnabled.map(String.init(describing:)) ?? "nil"), aiCreditsFallback=\(snapshot.aiCreditsFallback.map(String.init) ?? "nil"), models=\(snapshot.models?.count ?? 0)",
            level: .debug
        )

        return ProviderUsageSummary(
            providerID: .antigravity,
            fetchedAt: snapshot.fetchedAt,
            primary: primary,
            secondary: secondary,
            payload: snapshot,
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
        guard let snap = summary.payload as? AntigravityUsageSnapshot else {
            return AnyView(EmptyView())
        }
        return AnyView(AntigravityUsageDetailView(snapshot: snap, history: history))
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
        guard let snapshot = summary.payload as? AntigravityUsageSnapshot else {
            return (nil, nil)
        }

        // Bar 1 — model rate-limit bar. Four cases:
        //   1. No quota data at all → "No model rate limits reported"
        //   2. Every model fresh (remaining = 100%) → "All models at full quota"
        //   3. Every model exhausted → "All models capped · next reset in <time>"
        //   4. Mixed → "Worst usable: <label> · N% remaining"
        // The all-fresh case is checked BEFORE the worst-usable path so
        // the tooltip says "all" instead of singling out one model whose
        // remaining happens to tie.
        let primaryTip: String
        if snapshot.worstModelUtilization == nil {
            primaryTip = "No model rate limits reported"
        } else if snapshot.allModelsFresh {
            primaryTip = "All models at full quota"
        } else if snapshot.allModelsExhausted {
            if let reset = snapshot.earliestModelReset {
                primaryTip = "All models capped · next reset in \(Self.formattedResetCountdown(until: reset))"
            } else {
                primaryTip = "All models capped"
            }
        } else if let label = snapshot.worstModelLabel,
                  let util = snapshot.worstModelUtilization {
            let remaining = Int((100 - util).rounded())
            primaryTip = "Worst usable: \(label) · \(remaining)% remaining"
        } else {
            // Defensive: worstModelUtilization was non-nil per the first
            // guard, but the label resolver tied or returned nil. Fall
            // back to a generic phrasing rather than crashing the popover.
            primaryTip = "Model quota tracked"
        }

        // Bar 2 — AI Credits
        let secondaryTip: String
        if let wallet = snapshot.aiCreditsWallet,
           let ceiling = snapshot.tier.aiCreditsCeiling, ceiling > 0 {
            let walletStr  = Self.formattedCount(wallet)
            let ceilingStr = Self.formattedCount(ceiling)
            switch snapshot.overagesEnabled {
            case .some(true):  secondaryTip = "AI Credits: \(walletStr)/\(ceilingStr) · Overages on"
            case .some(false): secondaryTip = "AI Credits: \(walletStr)/\(ceilingStr) · Overages off"
            case .none:        secondaryTip = "AI Credits: \(walletStr)/\(ceilingStr)"
            }
        } else {
            secondaryTip = "AI Credits: not tracked on this plan"
        }

        return (primaryTip, secondaryTip)
    }

    func switcherBarDimming(
        summary: ProviderUsageSummary
    ) -> (primary: Bool, secondary: Bool) {
        guard let snapshot = summary.payload as? AntigravityUsageSnapshot else {
            return (false, false)
        }
        return (false, snapshot.overagesEnabled == false)
    }

    // MARK: - Renewal / reset estimate

    func renewalEstimate(profile: Profile,
                         summary: ProviderUsageSummary?,
                         now: Date) -> RenewalEstimate? {
        // Account-level (main header) estimate. The observed credit cycle is
        // the stablest signal, so it wins.
        if let cycle = observedCreditCycleEstimate(profile: profile, now: now) {
            return cycle
        }
        // Fallback before any observation: the soonest per-model rate-limit
        // reset we actually know — honest, but a cooldown, not a cycle. The
        // header stands alone (no bar beside it), so the soonest reset is an
        // acceptable "when does something come back" hint here.
        if let snapshot = summary?.payload as? AntigravityUsageSnapshot,
           let reset = snapshot.earliestModelReset {
            return RenewalEstimate(date: reset, prefix: "Resets", absolute: false)
        }
        return nil
    }

    func switcherRenewalEstimate(profile: Profile,
                                 summary: ProviderUsageSummary?,
                                 now: Date) -> RenewalEstimate? {
        // The switcher row's text sits beside the worst-model bar, so it must
        // describe that exact model — its own reset wins.
        if let snapshot = summary?.payload as? AntigravityUsageSnapshot,
           let reset = snapshot.worstModelReset {
            return RenewalEstimate(date: reset, prefix: "Resets", absolute: false)
        }
        // No worst-model reset (worst model fresh, or constrained without a
        // reset window in a partial response). Defer ONLY to the credit cycle
        // — never to `earliestModelReset`, which can belong to a healthier
        // model and would re-create the bar/text contradiction this hook
        // exists to prevent.
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
        guard let snapshot = summary.payload as? AntigravityUsageSnapshot else { return nil }
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

    /// Comma-grouped integer formatting reused by tooltips.
    private static func formattedCount(_ n: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
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
