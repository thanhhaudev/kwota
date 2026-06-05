//
//  ProfileDetailFormatter.swift
//  Kwota
//

import Foundation

/// Pure display helpers used by `ProfileDetailView`. Extracted so the
/// formatting rules can be unit-tested without standing up a SwiftUI host.
/// All methods return a human-readable string; nil / empty inputs return
/// "—" (em dash) so the sheet renders a placeholder rather than blank.
enum ProfileDetailFormatter {
    static let placeholder = "—"

    /// Maps raw `organization.subscription_status` to a capitalized label.
    /// Underscores in unknown values are replaced with spaces.
    static func subscriptionStatus(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return placeholder }
        switch raw {
        case "active":     return "Active"
        case "trial":      return "Trial"
        case "canceled":   return "Canceled"
        case "incomplete": return "Incomplete"
        default:           return capitalizeFirst(replacingUnderscores(raw))
        }
    }

    /// Maps raw `organization.billing_type` to a label. Examples:
    /// `"stripe_subscription"` → `"Stripe subscription"`,
    /// `"invoice_based"` → `"Invoice based"`. Nil → `"—"`.
    static func billingType(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return placeholder }
        return capitalizeFirst(replacingUnderscores(raw))
    }

    /// Tri-state: `true` → `"Enabled"`, `false` → `"Disabled"`, `nil` → `"—"`.
    static func hasExtraUsage(_ value: Bool?) -> String {
        switch value {
        case .some(true):  return "Enabled"
        case .some(false): return "Disabled"
        case .none:        return placeholder
        }
    }

    /// Hides everything but the last 12 characters of a UUID.
    /// `"4970bd29-1771-42c1-8274-cced9e79d94c"` → `"••••cced9e79d94c"`.
    /// Inputs of 12 chars or fewer pass through unchanged so masked output
    /// never grows longer than the original.
    static func uuidMasked(_ raw: String?) -> String {
        guard let raw else { return placeholder }
        if raw.count <= 12 { return raw }
        return "••••" + raw.suffix(12)
    }

    /// If the org name contains an "@" (Anthropic generates names like
    /// `"foo@bar.com's Organization"`), masks the email portion via the
    /// same algorithm `Profile.maskedEmail` uses. Otherwise returns the
    /// name unchanged.
    static func organizationNameMasked(_ raw: String) -> String {
        guard raw.contains("@") else { return raw }
        let tokens = raw.split(separator: " ", omittingEmptySubsequences: false)
        let masked = tokens.map { token -> String in
            let s = String(token)
            guard s.contains("@") else { return s }
            guard let atIdx = s.firstIndex(of: "@") else { return s }
            let local = s[..<atIdx]
            let domain = s[atIdx...]
            guard let first = local.first else { return s }
            return "\(first)••••\(domain)"
        }
        return masked.joined(separator: " ")
    }

    // MARK: - Private helpers

    private static func replacingUnderscores(_ s: String) -> String {
        s.replacingOccurrences(of: "_", with: " ")
    }

    private static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
