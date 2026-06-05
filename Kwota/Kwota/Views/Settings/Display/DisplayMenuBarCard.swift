//
//  DisplayMenuBarCard.swift
//  Kwota
//

import SwiftUI

struct DisplayMenuBarCard: View {
    let vm: MenuBarViewModel

    @AppStorage(AppStorageKeys.generalMenuBarStyle) private var styleRaw: String = MenuBarStyle.original.rawValue
    @AppStorage(AppStorageKeys.generalMenuBarUsageSource) private var sourceRaw: String = MenuBarUsageSource.session.rawValue

    private var style: MenuBarStyle { MenuBarStyle.resolve(styleRaw) }
    private var source: MenuBarUsageSource { MenuBarUsageSource.resolve(sourceRaw) }
    private var reading: MenuBarReading {
        MenuBarUsageDriver.read(summary: vm.summary, source: source)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Display style").font(.system(size: 13))
                    Text("Choose how usage is shown in the menu bar.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    ForEach(MenuBarStyle.allCases) { option in
                        MenuBarStylePreviewTile(style: option, current: style, reading: reading) {
                            styleRaw = option.rawValue
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            SettingsSectionDivider()

            SettingsRow(title: "Usage source",
                        subtitle: "Choose which quota the menu bar indicator reflects.") {
                CompactInlinePicker(
                    selection: $sourceRaw,
                    options: MenuBarUsageSource.allCases.map { $0.rawValue },
                    title: { MenuBarUsageSource.resolve($0).title }
                )
                .disabled(!style.requiresUsageSource)
            }
        }
    }
}
