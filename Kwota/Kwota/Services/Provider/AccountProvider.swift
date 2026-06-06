//
//  AccountProvider.swift
//  Kwota
//

import SwiftUI

/// Provider-supplied renewal/reset estimate for the switcher subtitle and
/// Usage-tab header. `absolute == true` renders an abbreviated date (plus a
/// relative hint in the header); `absolute == false` renders the relative
/// phrase only (e.g. a rate-limit cooldown "Resets in 2h").
struct RenewalEstimate: Equatable {
    let date: Date
    /// Leading label: "Est." (subscription), "Est. resets" (observed
    /// credit cycle), or "Resets" (rate-limit fallback).
    let prefix: String
    let absolute: Bool
}

/// Outcome of a per-fetch credit-cycle evaluation. The shell persists
/// `lastWallet`/`lastCeiling` onto the profile for the next comparison, and
/// — when `resetDetectedAt` is non-nil — advances the observed reset anchor.
/// A nil evaluation (or nil fields) means "leave the persisted state alone"
/// (e.g. this fetch carried no trustworthy real-API reading).
struct CreditCycleEvaluation: Equatable {
    /// Set when a monthly reset was observed on this fetch (typically `now`).
    let resetDetectedAt: Date?
    /// Latest real-API reading to persist; nil leaves the stored value as-is.
    let lastWallet: Int64?
    let lastCeiling: Int64?
}

/// Banner-worthy failure states for the detail-sheet Refresh button.
/// Each provider classifies its own thrown errors into these cases; the
/// shell maps them to `MenuBarViewModel.RefreshResult` without knowing
/// which provider raised them. The auth banner *wording* comes from the
/// provider's `reauthInstruction`, not from this enum.
enum ProviderMetadataRefreshError: Error {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case offline
    /// A user-readable sentence rendered verbatim in the banner (e.g. the
    /// CLI is signed into a different account, or the app isn't running).
    case identityMismatch(message: String)
    case other(message: String)

    /// Connectivity `URLError` codes that should surface as `.offline`.
    /// Shared so every provider classifies network failures identically.
    static func isOfflineCode(_ code: URLError.Code) -> Bool {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }
}

/// One source of usage / quota / billing for an LLM service. Implementations
/// are registered with `ProviderRegistry` at app launch. The shell never
/// references concrete providers; it only walks the registry.
@MainActor
protocol AccountProvider: AnyObject {
    var id: ProviderID { get }
    var displayName: String { get }
    /// Asset name OR SF Symbol — chrome views render this in the profile card.
    var iconAssetName: String { get }

    /// Which detail rows/sections apply to this provider's profiles in the
    /// Settings ▸ Profiles sheet. Default: all fields (the Claude shape).
    var supportedProfileDetailFields: Set<ProfileDetailField> { get }

    /// Auth methods this provider supports, in display order.
    var supportedAuthMethods: [any ProviderAuthMethod] { get }

    /// Fetch a fresh usage summary for a given credential. Throws on
    /// network/auth errors; the shell surfaces them through `lastError`.
    func fetchUsage(credential: Credential, profile: Profile) async throws -> ProviderUsageSummary

    /// Re-fetch / re-read this provider's profile metadata for the
    /// Settings ▸ Profiles detail-sheet Refresh button, persisting any diff
    /// to the store. Returns `true` when something changed. Throws
    /// `ProviderMetadataRefreshError` for banner-worthy failures. Default
    /// delegates to `fetchUsage` (correct for providers whose displayed
    /// metadata is a side-effect of the usage fetch) and reports no diff.
    func refreshProfileMetadata(for profile: Profile, credential: Credential) async throws -> Bool

    /// Sentence shown in the re-auth banner when a refresh fails with
    /// `.unauthorized`. Default names this provider's CLI; providers whose
    /// auth is brokered differently (e.g. a running app) override it.
    var reauthInstruction: String { get }

    /// Title shown in the re-auth banner. Default names this provider's CLI;
    /// providers without a CLI (e.g. a running app) override it.
    var reauthTitle: String { get }

    /// Provider-specific detail view rendered inside the Usage tab. The shell
    /// only renders header / expiry banner / refresh; everything below is the
    /// provider's chart layout.
    func usageDetailView(summary: ProviderUsageSummary,
                        history: [UsageHistoryEntry],
                        profile: Profile) -> AnyView

    /// Optional: provider-specific badge surfaced in the profile row
    /// (e.g. Claude's "Pro" / "Team" pill). Empty view = no badge.
    func planBadgeView(profile: Profile) -> AnyView

    /// Surfaces every installable piece of this provider Kwota can detect on
    /// disk (CLI binary, desktop app bundle, …) so the About card lists one
    /// row per component. Return `[]` when nothing relevant is installed; the
    /// shell skips empty providers entirely.
    func installedComponents() async -> [InstalledComponent]

    /// Plain-text tooltips for the two switcher bars rendered on this
    /// provider's rows. Default impl returns `(nil, nil)` — the switcher
    /// falls back to its built-in `"<label> · <pct>%"` format.
    func switcherBarTooltips(
        summary: ProviderUsageSummary
    ) -> (primary: String?, secondary: String?)

    /// Whether each switcher bar should render with a dim grey gradient
    /// regardless of utilization color. Used for "data is fine but inactive"
    /// states (e.g. Antigravity AI Credits when overages are toggled off).
    /// Default returns `(false, false)`.
    func switcherBarDimming(
        summary: ProviderUsageSummary
    ) -> (primary: Bool, secondary: Bool)

    /// Renewal/reset estimate for this provider's profile, or nil when none
    /// can be shown. `summary` (when available) lets a provider read live
    /// reset data for a fallback. Default: subscription estimate.
    ///
    /// This is the *account-level* estimate, surfaced in the main popover
    /// header where it stands alone. Providers should favour the stablest
    /// signal (a billing/credit cycle) here over transient cooldowns.
    func renewalEstimate(profile: Profile,
                         summary: ProviderUsageSummary?,
                         now: Date) -> RenewalEstimate?

    /// Reset estimate for the *switcher row*, where the text sits beside the
    /// provider's worst-model bar and must describe the same model. Default:
    /// the account-level `renewalEstimate`. A provider whose switcher bar
    /// tracks a per-model reset (e.g. Antigravity) overrides this to favour
    /// that model's reset, so the row text never contradicts its bar.
    func switcherRenewalEstimate(profile: Profile,
                                 summary: ProviderUsageSummary?,
                                 now: Date) -> RenewalEstimate?

    /// Evaluate this provider's credit cycle for the just-fetched `summary`,
    /// comparing against the profile's persisted last reading. The shell
    /// persists the returned `lastWallet`/`lastCeiling` for next time and, on
    /// `resetDetectedAt`, advances `Profile.observedCreditResetAt`. Default:
    /// nil (the provider doesn't track a credit cycle).
    func evaluateCreditCycle(summary: ProviderUsageSummary,
                             profile: Profile,
                             now: Date) -> CreditCycleEvaluation?
}

extension AccountProvider {
    var supportedProfileDetailFields: Set<ProfileDetailField> {
        Set(ProfileDetailField.allCases)
    }

    func refreshProfileMetadata(for profile: Profile, credential: Credential) async throws -> Bool {
        _ = try await fetchUsage(credential: credential, profile: profile)
        return false
    }

    var reauthInstruction: String {
        "Authorization expired. Sign in to the \(displayName) CLI again."
    }

    var reauthTitle: String {
        "\(displayName) CLI session expired"
    }

    func installedComponents() async -> [InstalledComponent] { [] }

    func switcherBarTooltips(
        summary: ProviderUsageSummary
    ) -> (primary: String?, secondary: String?) {
        (nil, nil)
    }

    func switcherBarDimming(
        summary: ProviderUsageSummary
    ) -> (primary: Bool, secondary: Bool) {
        (false, false)
    }

    func renewalEstimate(profile: Profile,
                         summary: ProviderUsageSummary?,
                         now: Date) -> RenewalEstimate? {
        guard let date = RenewalEstimator.subscription(for: profile, now: now) else { return nil }
        return RenewalEstimate(date: date, prefix: "Est.", absolute: true)
    }

    func switcherRenewalEstimate(profile: Profile,
                                 summary: ProviderUsageSummary?,
                                 now: Date) -> RenewalEstimate? {
        renewalEstimate(profile: profile, summary: summary, now: now)
    }

    func evaluateCreditCycle(summary: ProviderUsageSummary,
                             profile: Profile,
                             now: Date) -> CreditCycleEvaluation? { nil }
}
