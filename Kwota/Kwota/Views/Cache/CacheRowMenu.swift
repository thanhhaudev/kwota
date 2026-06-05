//
//  CacheRowMenu.swift
//  Kwota
//

import SwiftUI

/// Content for a row's ⋯ menu. Lifted into its own struct so `CacheRowView`
/// stays focused on layout. Actions are passed in as closures so the row
/// doesn't need to know about the view model.
struct CacheRowMenu: View {
    let row: CachePathRow
    let isReEvaluating: Bool
    /// True while a global Clean now / per-row clean is in flight. Disables
    /// the Clean-now menu item so a second press during the same operation
    /// doesn't read as "nothing happened" (the VM already guards
    /// re-entrancy, but without UI feedback the user has no way to tell).
    let isCleaning: Bool
    let onCleanNow: () -> Void
    let onReEvaluate: () -> Void
    let onToggleAuto: () -> Void
    let onReveal: () -> Void
    let onCopyPath: () -> Void
    let onRemove: () -> Void
    let onShowDetail: () -> Void

    var body: some View {
        Menu {
            if row.isCleanable {
                Button("Clean now (\(formatBytes(row.sizeBytes)))",
                       systemImage: "trash",
                       action: onCleanNow)
                    .disabled(row.sizeBytes == 0 || isCleaning)
            }

            if row.aiEvaluation != nil {
                Button("Why this folder?",
                       systemImage: "sparkles",
                       action: onShowDetail)
            }
            Button(
                row.aiEvaluation == nil ? "Evaluate with AI" : "Re-evaluate with AI",
                systemImage: "wand.and.stars",
                action: onReEvaluate
            )
            .disabled(isReEvaluating)

            if row.isCleanable {
                Button(
                    row.autoCleanEnabled ? "Disable auto-clean" : "Enable auto-clean",
                    systemImage: row.autoCleanEnabled ? "pause.circle" : "play.circle",
                    action: onToggleAuto
                )
            }

            Divider()

            Button("Reveal in Finder", systemImage: "folder", action: onReveal)
            Button("Copy path", systemImage: "doc.on.doc", action: onCopyPath)

            Divider()
            Button("Remove from tracking",
                   systemImage: "minus.circle",
                   role: .destructive,
                   action: onRemove)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .accessibilityLabel("More actions for \(row.displayName)")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func formatBytes(_ n: Int) -> String { n.formattedBytes }
}
