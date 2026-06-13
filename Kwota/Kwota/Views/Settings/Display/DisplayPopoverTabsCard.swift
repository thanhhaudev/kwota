//
//  DisplayPopoverTabsCard.swift
//  Kwota
//

import SwiftUI

struct DisplayPopoverTabsCard: View {
    @AppStorage(AppStorageKeys.displayPopoverShowStats) private var showStats: Bool = true
    @AppStorage(AppStorageKeys.displayPopoverShowAwake) private var showAwake: Bool = true
    @AppStorage(AppStorageKeys.displayPopoverShowCache) private var showCache: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(title: "Stats") {
                Toggle("", isOn: $showStats).toggleStyle(.checkbox).labelsHidden()
            }
            SettingsSectionDivider()
            SettingsRow(title: "Awake") {
                Toggle("", isOn: $showAwake).toggleStyle(.checkbox).labelsHidden()
            }
            SettingsSectionDivider()
            SettingsRow(title: "Cache") {
                Toggle("", isOn: $showCache).toggleStyle(.checkbox).labelsHidden()
            }
        }
    }
}
