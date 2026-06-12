//
//  CacheRowMenu.swift
//  Kwota
//

import SwiftUI

/// Content for a row's ⋯ menu. Lifted into its own struct so `CacheRowView`
/// stays focused on layout. Actions are passed in as closures so the row
/// doesn't need to know about the view model.
struct CacheRowMenu: View {
    /// Why per-row "Clean now" is currently unavailable. Mirrors the
    /// `cacheCleanRow` re-entrancy guard (scan in flight, global clean, or
    /// another row's clean) so the menu item reads as disabled *with a
    /// reason* instead of silently dropping the tap at the VM boundary.
    enum CleanBlock: Equatable {
        case scanning
        case cleaning

        /// Replaces the size suffix in the "Clean now" label while blocked.
        var menuSuffix: String {
            switch self {
            case .scanning: return "waiting for scan…"
            case .cleaning: return "waiting for cleanup…"
            }
        }

        /// Single source of truth for the blocked state — must stay in sync
        /// with the guard in `MenuBarViewModel.cacheCleanRow`. Scan wins the
        /// label when both are true (the scan is what the user sees running).
        static func current(
            isScanning: Bool,
            isCleaningGlobal: Bool,
            hasRowCleans: Bool
        ) -> CleanBlock? {
            if isScanning { return .scanning }
            if isCleaningGlobal || hasRowCleans { return .cleaning }
            return nil
        }
    }

    let row: CachePathRow
    let isReEvaluating: Bool
    /// Non-nil while some scan/clean owns the VM. Disables the Clean-now
    /// menu item and swaps its size suffix for the reason, so a tap during
    /// the operation doesn't read as "nothing happened".
    let cleanBlock: CleanBlock?
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
                Button("Clean now (\(cleanBlock?.menuSuffix ?? formatBytes(row.sizeBytes)))",
                       systemImage: "trash",
                       action: onCleanNow)
                    .disabled(row.sizeBytes == 0 || cleanBlock != nil)
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
