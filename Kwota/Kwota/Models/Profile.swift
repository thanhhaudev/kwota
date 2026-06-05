//
//  Profile.swift
//  Kwota
//

import Foundation

enum ProfileKind: String, Codable, Equatable {
    case auto
    case archived
}

struct Profile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    /// Which `AccountProvider` this profile is backed by. Defaults to
    /// `.claude` when missing on disk so legacy profiles.json files load
    /// without migration.
    var providerID: ProviderID = .claude
    var authMethod: AuthMethodKind
    var organizationId: String?
    var createdAt: Date
    var lastFetchedAt: Date?
    var lastSnapshot: UsageSnapshot?
    var lastSessionPercentage: Double?
    var subscriptionPlan: String?
    var subscriptionCreatedAt: Date?
    /// Next billing period end, when known directly from a provider's auth
    /// payload (Codex's `id_token` JWT exposes this verbatim under
    /// `chatgpt_subscription_active_until`). Preferred by the VM over the
    /// monthly extrapolation from `subscriptionCreatedAt`. Optional so
    /// profiles persisted before this feature decode with nil, and so
    /// Claude profiles (which don't expose a comparable claim) stay on
    /// the extrapolation pathway.
    var subscriptionRenewsAt: Date?
    var email: String?
    var sessionKeyExpiresAt: Date?
    var notifications: NotificationConfig?
    var kind: ProfileKind = .auto
    var ownershipBoundary: Date?

    // MARK: - Populated by OAuthProfileFetcher probe
    //
    // These fields surface in the Settings ▸ Profiles detail sheet. All
    // optional so legacy profiles.json files (which lack them) load
    // without migration via decodeIfPresent below.

    /// Server-side account UUID from `/api/oauth/profile` `account.uuid`.
    /// Distinct from `Profile.id` which is Kwota's local identifier.
    var accountUuid: String?
    /// User-set display name from `account.full_name` (preferred) or
    /// `account.display_name`. Separate from `Profile.name` (which is the
    /// row label and falls back to email).
    var displayName: String?

    /// Name shown in chrome (switcher row, Accounts-list fallback, detail
    /// header): the account's API-sourced `displayName` when present, else
    /// the row `name`. Centralizes the precedence so every view stays in
    /// sync when a refresh updates either field. Not a stored property, so
    /// it is excluded from Codable automatically.
    var resolvedDisplayName: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return name
    }
    /// When the Anthropic account was created — `account.created_at`.
    var accountCreatedAt: Date?
    /// `organization.name` from the same payload.
    var organizationName: String?
    /// Raw subscription status string ("active" / "trial" / "canceled" /
    /// "incomplete"). View-layer formatter handles display.
    var subscriptionStatus: String?
    /// Raw billing type ("stripe_subscription" or nil).
    var billingType: String?
    /// `organization.has_extra_usage_enabled` — tri-state via Optional<Bool>
    /// so a never-probed profile renders "—" rather than "Disabled".
    var hasExtraUsageEnabled: Bool?

    /// Observed AI-credit cycle boundary for Antigravity (the timestamp at
    /// which the credit balance was seen to jump back to the ceiling).
    /// Projected +1 month for the "Est. resets" display. nil until Kwota
    /// has witnessed one reset. Other providers leave this nil.
    var observedCreditResetAt: Date?
    /// Last REAL-API AI-credit reading (raw wallet + tier ceiling) seen for
    /// this Antigravity profile. The next fetch compares against this to
    /// detect a monthly reset (wallet jumps back to full with an unchanged
    /// ceiling) — raw values, so a ceiling change or a stale state.vscdb
    /// fallback balance can't fake a reset. nil until the first real-API
    /// reading; other providers leave these nil.
    var lastCreditWallet: Int64?
    var lastCreditCeiling: Int64?

    init(
        id: UUID = UUID(),
        name: String,
        authMethod: AuthMethodKind,
        providerID: ProviderID = .claude,
        organizationId: String? = nil,
        createdAt: Date = Date(),
        lastFetchedAt: Date? = nil,
        lastSnapshot: UsageSnapshot? = nil,
        lastSessionPercentage: Double? = nil,
        subscriptionPlan: String? = nil,
        subscriptionCreatedAt: Date? = nil,
        subscriptionRenewsAt: Date? = nil,
        email: String? = nil,
        sessionKeyExpiresAt: Date? = nil,
        notifications: NotificationConfig? = nil,
        kind: ProfileKind = .auto,
        ownershipBoundary: Date? = nil,
        accountUuid: String? = nil,
        displayName: String? = nil,
        accountCreatedAt: Date? = nil,
        organizationName: String? = nil,
        subscriptionStatus: String? = nil,
        billingType: String? = nil,
        hasExtraUsageEnabled: Bool? = nil,
        observedCreditResetAt: Date? = nil,
        lastCreditWallet: Int64? = nil,
        lastCreditCeiling: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.providerID = providerID
        self.authMethod = authMethod
        self.organizationId = organizationId
        self.createdAt = Profile.normalize(createdAt)
        self.lastFetchedAt = lastFetchedAt.map(Profile.normalize)
        self.lastSnapshot = lastSnapshot
        self.lastSessionPercentage = lastSessionPercentage
        self.subscriptionPlan = subscriptionPlan
        self.subscriptionCreatedAt = subscriptionCreatedAt.map(Profile.normalize)
        self.subscriptionRenewsAt = subscriptionRenewsAt.map(Profile.normalize)
        self.email = email
        self.sessionKeyExpiresAt = sessionKeyExpiresAt.map(Profile.normalize)
        self.notifications = notifications
        self.kind = kind
        self.ownershipBoundary = ownershipBoundary.map(Profile.normalize)
        self.accountUuid = accountUuid
        self.displayName = displayName
        self.accountCreatedAt = accountCreatedAt.map(Profile.normalize)
        self.organizationName = organizationName
        self.subscriptionStatus = subscriptionStatus
        self.billingType = billingType
        self.hasExtraUsageEnabled = hasExtraUsageEnabled
        self.observedCreditResetAt = observedCreditResetAt.map(Profile.normalize)
        self.lastCreditWallet = lastCreditWallet
        self.lastCreditCeiling = lastCreditCeiling
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, providerID, authMethod, organizationId, createdAt,
             lastFetchedAt, lastSnapshot, lastSessionPercentage,
             subscriptionPlan, subscriptionCreatedAt, subscriptionRenewsAt,
             email, sessionKeyExpiresAt, notifications,
             kind, ownershipBoundary,
             accountUuid, displayName, accountCreatedAt,
             organizationName, subscriptionStatus, billingType,
             hasExtraUsageEnabled, observedCreditResetAt,
             lastCreditWallet, lastCreditCeiling
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            authMethod: try c.decode(AuthMethodKind.self, forKey: .authMethod),
            providerID: try c.decodeIfPresent(ProviderID.self, forKey: .providerID) ?? .claude,
            organizationId: try c.decodeIfPresent(String.self, forKey: .organizationId),
            createdAt: try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(),
            lastFetchedAt: try c.decodeIfPresent(Date.self, forKey: .lastFetchedAt),
            lastSnapshot: try c.decodeIfPresent(UsageSnapshot.self, forKey: .lastSnapshot),
            lastSessionPercentage: try c.decodeIfPresent(Double.self, forKey: .lastSessionPercentage),
            subscriptionPlan: try c.decodeIfPresent(String.self, forKey: .subscriptionPlan),
            subscriptionCreatedAt: try c.decodeIfPresent(Date.self, forKey: .subscriptionCreatedAt),
            subscriptionRenewsAt: try c.decodeIfPresent(Date.self, forKey: .subscriptionRenewsAt),
            email: try c.decodeIfPresent(String.self, forKey: .email),
            sessionKeyExpiresAt: try c.decodeIfPresent(Date.self, forKey: .sessionKeyExpiresAt),
            notifications: try c.decodeIfPresent(NotificationConfig.self, forKey: .notifications),
            kind: try c.decodeIfPresent(ProfileKind.self, forKey: .kind) ?? .auto,
            ownershipBoundary: try c.decodeIfPresent(Date.self, forKey: .ownershipBoundary)
                .map(Profile.normalize),
            accountUuid: try c.decodeIfPresent(String.self, forKey: .accountUuid),
            displayName: try c.decodeIfPresent(String.self, forKey: .displayName),
            accountCreatedAt: try c.decodeIfPresent(Date.self, forKey: .accountCreatedAt),
            organizationName: try c.decodeIfPresent(String.self, forKey: .organizationName),
            subscriptionStatus: try c.decodeIfPresent(String.self, forKey: .subscriptionStatus),
            billingType: try c.decodeIfPresent(String.self, forKey: .billingType),
            hasExtraUsageEnabled: try c.decodeIfPresent(Bool.self, forKey: .hasExtraUsageEnabled),
            observedCreditResetAt: try c.decodeIfPresent(Date.self, forKey: .observedCreditResetAt),
            lastCreditWallet: try c.decodeIfPresent(Int64.self, forKey: .lastCreditWallet),
            lastCreditCeiling: try c.decodeIfPresent(Int64.self, forKey: .lastCreditCeiling)
        )
    }

    /// Normalize dates to whole-second precision so JSON round-trip via
    /// `.secondsSince1970` preserves equality.
    private static func normalize(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }
}

extension Profile {
    var maskedEmail: String? {
        guard let email = email, let atIndex = email.firstIndex(of: "@") else { return email }
        let prefix = email[..<atIndex]
        let suffix = email[atIndex...]
        guard let first = prefix.first else { return email }
        return "\(first)••••\(suffix)"
    }

    var maskedPlan: String? {
        guard subscriptionPlan != nil else { return nil }
        return "•••• Plan"
    }
}
