//
//  ProviderBadgeStyle.swift
//  Kwota
//

import SwiftUI

/// Shared badge styling for provider pills inside `SettingsRow.leadingBadges`.
/// Used by `ProfileHistoryCard` (Data & Storage) and `ManageProfilesView`
/// (Profiles tab) so identical accounts read the same across Settings.
/// `ProviderPalette` is for the Awake chart and uses asset-catalog colors;
/// badges intentionally use SwiftUI system colors so they stay readable
/// against the `controlBackgroundColor` row fill at small sizes.
enum ProviderBadgeStyle {
    static func color(for provider: ProviderID) -> Color {
        switch provider {
        case .claude:      return .orange
        case .codex:       return .teal
        case .antigravity: return .purple
        }
    }

    static func badge(for provider: ProviderID, name: String) -> SettingsRowBadge {
        let c = color(for: provider)
        return SettingsRowBadge(text: name, foreground: c, background: c.opacity(0.18))
    }
}
