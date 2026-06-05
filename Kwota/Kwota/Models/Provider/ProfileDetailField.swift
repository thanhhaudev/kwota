//
//  ProfileDetailField.swift
//  Kwota
//

import Foundation

/// One gateable row/section in the Settings ▸ Profiles detail sheet
/// (`ProfileDetailView`). A provider declares which of these apply to its
/// profiles via `AccountProvider.supportedProfileDetailFields`; the detail
/// view renders a row/section only when its field is in that set.
///
/// `Display name` and `Profile ID` are always shown and are intentionally
/// NOT represented here.
enum ProfileDetailField: CaseIterable {
    // Account section
    case email
    case accountCreated
    // Subscription section
    case plan
    case subscriptionStatus
    case subscriptionStarted
    case billing
    case extraUsage
    // Organization section
    case organizationName
    // Identifiers section
    case accountUUID
    case orgUUID
}

/// Pure visibility decisions derived from a provider's supported fields.
/// Extracted so the gating logic is unit-testable without rendering SwiftUI.
struct ProfileDetailVisibility {
    let fields: Set<ProfileDetailField>

    var showsEmail: Bool               { fields.contains(.email) }
    var showsAccountCreated: Bool      { fields.contains(.accountCreated) }
    var showsPlan: Bool                { fields.contains(.plan) }
    var showsSubscriptionStatus: Bool  { fields.contains(.subscriptionStatus) }
    var showsSubscriptionStarted: Bool { fields.contains(.subscriptionStarted) }
    var showsBilling: Bool             { fields.contains(.billing) }
    var showsExtraUsage: Bool          { fields.contains(.extraUsage) }
    var showsOrganizationName: Bool    { fields.contains(.organizationName) }
    var showsAccountUUID: Bool         { fields.contains(.accountUUID) }
    var showsOrgUUID: Bool             { fields.contains(.orgUUID) }

    /// The Subscription section renders only when at least one of its rows does.
    var showsSubscriptionSection: Bool {
        showsPlan || showsSubscriptionStatus || showsSubscriptionStarted
            || showsBilling || showsExtraUsage
    }

    /// The Organization section has a single row.
    var showsOrganizationSection: Bool { showsOrganizationName }
}
