//
//  SettingsSectionIcon.swift
//  Kwota
//

import SwiftUI

/// The rounded icon tile shown beside a settings section — in the sidebar list,
/// the suggestions popover, and search results. A uniform dark container with a
/// white glyph (native "Dark" icon look), legible in both light and dark mode.
struct SettingsSectionIcon: View {
    let section: SettingsSection
    var size: CGFloat = 20
    @Environment(\.colorScheme) private var colorScheme

    /// Uniform dark container (≈ #2C2C2E).
    private static let containerColor = Color(red: 0.17, green: 0.17, blue: 0.18)

    private static let glossGradient = LinearGradient(
        colors: [Color.white.opacity(0.22), Color.white.opacity(0.03), Color.black.opacity(0.12)],
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        shape
            .fill(Self.containerColor)
            // Convex sheen + top edge highlight fake some depth so SF Symbol
            // tiles don't read as totally flat next to native 3D icon artwork.
            .overlay(shape.fill(Self.glossGradient))
            .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: section.icon)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.08), radius: 0.8, y: 0.5)
            .accessibilityHidden(true)
    }
}
