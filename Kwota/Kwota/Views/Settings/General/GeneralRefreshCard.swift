//
//  GeneralRefreshCard.swift
//  Kwota
//

import SwiftUI

struct GeneralRefreshCard: View {
    @AppStorage(AppStorageKeys.generalPollingMode) private var modeRaw: String = PollingMode.normal.rawValue

    private var batterySaverBinding: Binding<Bool> {
        Binding(
            get: { PollingMode.resolve(modeRaw) == .batterySaver },
            set: { newValue in
                modeRaw = (newValue ? PollingMode.batterySaver : .normal).rawValue
            }
        )
    }

    var body: some View {
        SettingsRow(title: "Battery Saver",
                    subtitle: "Updates less often to save power.") {
            Toggle("", isOn: batterySaverBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
