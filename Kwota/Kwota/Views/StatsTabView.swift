//
//  StatsTabView.swift
//  Kwota
//

import SwiftUI

/// Stats tab shell. Resolves the active profile's provider and delegates the
/// body to `provider.statsDetailView(...)`, mirroring `UsageTabView`.
struct StatsTabView: View {
    let vm: MenuBarViewModel

    var body: some View {
        if let profile = vm.profileStore.activeProfile,
           let provider = vm.registry.provider(for: profile.providerID) {
            provider.statsDetailView(store: vm.statsStore, profile: profile)
        } else {
            StatsUnsupportedView(providerName: nil)
        }
    }
}

/// Empty state for providers without token data (and the no-profile case).
struct StatsUnsupportedView: View {
    let providerName: String?
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text(providerName.map { "Token stats aren't available for \($0) yet." }
                 ?? "No active profile.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
