//
//  ClearStatsCard.swift
//  Kwota
//

import SwiftUI

/// Settings → Data & Storage control for clearing recorded token-usage stats
/// for one provider. Lives here (rather than in the Stats popover tab) so the
/// popover stays read-only and destructive actions are grouped with the app's
/// other storage/reset controls.
struct ClearStatsCard: View {
    let vm: MenuBarViewModel
    let provider: ProviderID

    @State private var confirmShown = false

    private var name: String { provider.displayName }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button(role: .destructive) {
                confirmShown = true
            } label: {
                Text("Clear \(name) stats…")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Text("Removes recorded \(name) token usage. The daily chart and per-model totals reset. This can't be undone.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .alert("Clear \(name) token stats?", isPresented: $confirmShown) {
            Button("Clear", role: .destructive) { vm.statsStore.clear(provider: provider) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes recorded \(name) token usage. It can't be undone.")
        }
    }
}
