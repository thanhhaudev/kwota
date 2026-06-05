//
//  GeneralDockIconCard.swift
//  Kwota
//

import SwiftUI

struct GeneralDockIconCard: View {
    @AppStorage(DockIconModeStore.key) private var rawMode: String = DockIconMode.auto.rawValue

    private var mode: DockIconMode { DockIconMode(rawValue: rawMode) ?? .auto }

    var body: some View {
        VStack(spacing: 0) {
            row(for: .auto,
                title: "Auto",
                subtitle: "Shows the Dock icon only while Settings is open.")
            SettingsSectionDivider()
            row(for: .alwaysShow,
                title: "Always Show",
                subtitle: "Always keeps Kwota visible in the Dock.")
            SettingsSectionDivider()
            row(for: .alwaysHide,
                title: "Always Hide",
                subtitle: "Keeps Kwota as a menu bar app only.")
        }
    }

    private func row(for option: DockIconMode, title: String, subtitle: String) -> some View {
        let isSelected = mode == option
        return Button {
            rawMode = option.rawValue
        } label: {
            SettingsRow(title: title, subtitle: subtitle) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .font(.system(size: 16))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
