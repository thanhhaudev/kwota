//
//  DisplayChartCard.swift
//  Kwota
//

import SwiftUI

struct DisplayChartCard: View {
    @AppStorage(AppStorageKeys.displayChartShowAvg)       private var showAvg: Bool = true
    @AppStorage(AppStorageKeys.displayChartShowPaceHint)  private var showPaceHint: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(title: "Average reference line") {
                Toggle("", isOn: $showAvg).toggleStyle(.checkbox).labelsHidden()
            }
            SettingsSectionDivider()
            SettingsRow(title: "Pace hint") {
                Toggle("", isOn: $showPaceHint).toggleStyle(.checkbox).labelsHidden()
            }
        }
    }
}
