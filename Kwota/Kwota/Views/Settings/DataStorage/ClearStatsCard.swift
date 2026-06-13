//
//  ClearStatsCard.swift
//  Kwota
//

import SwiftUI

/// Settings → Data & Storage control for clearing recorded token-usage stats.
/// Lives here (rather than in the Stats popover tab) so the popover stays
/// read-only and destructive actions are grouped with the app's other
/// storage/reset controls.
struct ClearStatsCard: View {
    let vm: MenuBarViewModel

    @State private var confirmShown = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button(role: .destructive) {
                confirmShown = true
            } label: {
                Text("Clear Claude stats…")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Text("Removes recorded Claude token usage. The daily chart and per-model totals reset. This can't be undone.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .alert("Clear Claude token stats?", isPresented: $confirmShown) {
            Button("Clear", role: .destructive) { vm.statsStore.clear(provider: .claude) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes recorded Claude token usage. It can't be undone.")
        }
    }
}
