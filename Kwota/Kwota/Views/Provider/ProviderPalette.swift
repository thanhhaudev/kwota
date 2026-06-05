//
//  ProviderPalette.swift
//  Kwota
//

import SwiftUI

/// Brand-leaning color per provider for the Awake activity chart (and any
/// future per-provider UI). System-adaptive via asset-catalog color sets.
enum ProviderPalette {
    static func color(for provider: ProviderID) -> Color {
        switch provider {
        case .claude:      return Color("ProviderClaude")
        case .codex:       return Color("ProviderCodex")
        case .antigravity: return Color("ProviderAntigravity")
        }
    }
}
