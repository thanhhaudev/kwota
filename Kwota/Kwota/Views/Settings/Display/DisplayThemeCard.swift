//
//  DisplayThemeCard.swift
//  Kwota
//

import SwiftUI

struct DisplayThemeCard: View {
    @AppStorage(AppStorageKeys.displayTheme) private var themeRaw: String = DisplayTheme.system.rawValue

    private var theme: DisplayTheme { DisplayTheme.resolve(themeRaw) }

    var body: some View {
        VStack(spacing: 0) {
            row(for: .system, title: "Follow System",
                subtitle: "Match the macOS appearance setting.")
            SettingsSectionDivider()
            row(for: .light, title: "Light", subtitle: nil)
            SettingsSectionDivider()
            row(for: .dark, title: "Dark", subtitle: nil)
        }
    }

    private func row(for option: DisplayTheme, title: String, subtitle: String?) -> some View {
        let isSelected = theme == option
        return Button {
            themeRaw = option.rawValue
        } label: {
            SettingsRow(title: title, subtitle: subtitle) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .font(.system(size: 16))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
