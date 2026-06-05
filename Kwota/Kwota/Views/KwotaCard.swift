//
//  KwotaCard.swift
//  Kwota
//
//  Card chrome modifiers. Two variants:
//   • kwotaCard() — material background, used in the menu-bar popup
//     where the card sits over the popover's vibrant background.
//   • settingsCard() — opaque controlBackgroundColor, used in the
//     Settings detail pane where material reads as low-contrast in
//     light mode against the system window background.

import SwiftUI
import AppKit

private struct KwotaCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 1)
    }
}

private struct SettingsCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            }
    }
}

extension View {
    /// Popup card — material background, subtle stroke, soft shadow.
    func kwotaCard() -> some View {
        modifier(KwotaCardModifier())
    }

    /// Settings-window card — opaque controlBackgroundColor, no stroke.
    /// Matches macOS System Settings grouped-section convention and the
    /// borderless `SettingsGroupedSection` used elsewhere in the window.
    func settingsCard() -> some View {
        modifier(SettingsCardModifier())
    }
}
