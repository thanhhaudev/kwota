//
//  AntigravityTier.swift
//  Kwota
//
//  Canonical plan-tier classifier for Antigravity. Maps the wire fields
//  surfaced by the language_server's GetUserStatus into a small set of
//  cases that drive both the plan-badge label (e.g. "Pro") and the
//  AI Credits overage-pool ceiling used to render the bar in the Usage
//  tab. Sources:
//
//  - https://blog.google/products-and-platforms/products/google-one/google-ai-subscriptions/
//  - https://antigravity.google/docs/plans
//  - discuss.ai.google.dev/t/pro-subscription-ai-credits-capped-at-50-in-antigravity/139364
//    (the "capped at 50" bug — when Pro binding is lost, balance drops to
//    Free tier's 50/day, proving the 1,000 AI credits seen on Pro accounts
//    is the Pro plan's overage entitlement, not a separate Google One bonus.)
//

import Foundation

enum AntigravityTier: String, Equatable, Sendable {
    /// Free Google account — daily 50 AI credits.
    case free
    /// Google AI Pro — $20/mo, 1,000 AI credits/month overage pool.
    case pro
    /// Google AI Ultra $100/mo variant — baseline 5× Pro, 25,000 AI credits.
    case ultra5x
    /// Google AI Ultra $200/mo variant — baseline 20× Pro, 25,000 AI credits.
    case ultra20x
    /// Tier name didn't match any known family. Renders without the
    /// AI-credits bar but still surfaces the raw balance.
    case unknown

    /// Short label rendered in the plan-tier pill next to the profile name
    /// and used as the back-filled `Profile.subscriptionPlan`. Returns nil
    /// for `.unknown` so callers can fall back to the wire's raw plan name.
    var displayName: String? {
        switch self {
        case .free:     return "Free"
        case .pro:      return "Pro"
        case .ultra5x:  return "Ultra 5x"
        case .ultra20x: return "Ultra 20x"
        case .unknown:  return nil
        }
    }

    /// Monthly AI Credits overage-pool ceiling per Google's plan docs.
    /// Returns nil for `.unknown` so the view hides the bar rather than
    /// guessing a misleading max. Both Ultra variants share the same
    /// 25K ceiling — only baseline multiplier differs between them.
    var aiCreditsCeiling: Int64? {
        switch self {
        case .free:                  return 50
        case .pro:                   return 1_000
        case .ultra5x, .ultra20x:    return 25_000
        case .unknown:               return nil
        }
    }

    /// Classifies a tier from the two wire signals that survive the JSON
    /// proto encoding: `userTier.name` (authoritative for family) and
    /// `planInfo.monthlyPromptCredits` (used to disambiguate Ultra 5x vs
    /// 20x — Google reports the same `userTier.name` "Google AI Ultra"
    /// for both, but the baseline window cap differs by a 4× multiplier).
    ///
    /// Disambiguation boundary is 800,000 — a wide buffer around the
    /// expected 250K (5× Pro) and 1M (20× Pro) so small server-side
    /// re-tuning of the baseline doesn't flip the variant. Unknown Ultra
    /// without a baseline signal falls back to `.ultra5x` (conservative —
    /// ceiling is the same anyway).
    static func detect(
        userTierName: String?,
        monthlyPromptCredits: Int64?
    ) -> AntigravityTier {
        let name = (userTierName ?? "").lowercased()
        let monthly = monthlyPromptCredits ?? 0
        if name.contains("ultra") {
            return monthly >= 800_000 ? .ultra20x : .ultra5x
        }
        if name.contains("pro")  { return .pro }
        if name.contains("free") { return .free }
        return .unknown
    }
}
