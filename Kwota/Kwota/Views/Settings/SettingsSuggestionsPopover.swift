//
//  SettingsSuggestionsPopover.swift
//  Kwota
//

import SwiftUI

/// A floating dropdown of curated inner settings, shown below the sidebar search
/// field when it is focused but empty — matching native System Settings, where
/// the sidebar list stays visible behind the popover. Each row deep-links to a
/// specific card via its anchor.
struct SettingsSuggestionsPopover: View {
    let onSelect: (SettingsSearchEntry) -> Void
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Suggestions")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)

            ForEach(Array(SettingsSearchIndex.suggestions.enumerated()), id: \.offset) { _, entry in
                row(for: entry)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .background(panelBackground)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }

    private func row(for entry: SettingsSearchEntry) -> some View {
        Button {
            onSelect(entry)
        } label: {
            HStack(spacing: 8) {
                SettingsSectionIcon(section: entry.destination)

                Text(entry.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(isHovered: hovered == entry.title))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? entry.title : nil }
    }

    private func rowBackground(isHovered: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(isHovered ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
    }
}
