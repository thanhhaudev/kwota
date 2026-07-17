//
//  DisplayChartCard.swift
//  Kwota
//

import SwiftUI

struct DisplayChartCard: View {
    @AppStorage(AppStorageKeys.displayUsageCompact)       private var compact: Bool = false
    @AppStorage(AppStorageKeys.displayChartShowAvg)       private var showAvg: Bool = true
    @AppStorage(AppStorageKeys.displayChartShowPaceHint)  private var showPaceHint: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(
                title: "Compact layout",
                subtitle: "Session and week on one axis, with a 24-hour history line."
            ) {
                Toggle("", isOn: $compact).toggleStyle(.checkbox).labelsHidden()
            }
            SettingsSectionDivider()
            // Both rows below drive UsageTrendChart, which compact does not
            // render. Disable rather than hide them: a row that vanishes reads
            // as a setting that was lost, one that greys out reads as a setting
            // this mode doesn't use.
            SettingsRow(title: "Average reference line") {
                Toggle("", isOn: $showAvg).toggleStyle(.checkbox).labelsHidden()
            }
            .disabled(compact)
            .opacity(compact ? 0.5 : 1)
            SettingsSectionDivider()
            SettingsRow(title: "Pace hint") {
                Toggle("", isOn: $showPaceHint).toggleStyle(.checkbox).labelsHidden()
            }
            .disabled(compact)
            .opacity(compact ? 0.5 : 1)
        }
    }
}
