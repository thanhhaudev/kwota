//
//  AntigravityPlanBadgeView.swift
//  Kwota
//
//  Compact tier pill shown next to the profile name. Reads
//  `Profile.subscriptionPlan` which AntigravityProvider back-fills from
//  the GetUserStatus response — preferring the canonical
//  `AntigravityTier.displayName` ("AI Pro" / "AI Free" / "AI Ultra 5x" /
//  "AI Ultra 20x") over the raw wire `planName`. Falls back to a neutral
//  "Antigravity" pill when the plan name isn't known yet.
//

import SwiftUI

struct AntigravityPlanBadgeView: View {
    let profile: Profile

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.15))
            )
            .foregroundStyle(tint)
    }

    private var label: String {
        if let plan = profile.subscriptionPlan, !plan.isEmpty {
            return plan
        }
        return "Antigravity"
    }

    /// Tint mapped from the canonical tier label set written by
    /// `AntigravityProvider.backfillProfile`. Unknown labels fall through
    /// to the accent color so a future tier still renders sensibly.
    private var tint: Color {
        switch profile.subscriptionPlan?.lowercased() {
        case "ai free", "free", "trial":      return .gray
        case "ai pro", "pro":                  return .accentColor
        case "ai ultra 5x", "ai ultra 20x", "ultra": return .indigo
        case "teams", "team":                  return .blue
        case "enterprise":                     return .indigo
        default:                               return .accentColor
        }
    }
}
