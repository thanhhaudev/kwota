//
//  AwakeAutoCard.swift
//  Kwota
//

import SwiftUI

struct AwakeAutoCard: View {
    let vm: MenuBarViewModel

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(
                title: "Auto keep Mac awake while an AI agent is working",
                subtitle: "Stops automatically after the agent has been idle."
            ) {
                Toggle("", isOn: Binding(
                    get: { vm.awake.config.autoEnabled },
                    set: { vm.awake.setAutoEnabled($0) }
                ))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            SettingsSectionDivider()
            SettingsRow(title: "Stop if the agent is idle for") {
                CompactInlinePicker(
                    selection: Binding(
                        get: { vm.awake.config.idleWindow },
                        set: { vm.awake.updateIdleWindow($0) }
                    ),
                    options: IdleWindow.allCases,
                    title: { $0.label }
                )
                .disabled(!vm.awake.config.autoEnabled)
            }
            SettingsSectionDivider()
            SettingsRow(
                title: "Stop on battery below",
                subtitle: batterySubtitle
            ) {
                CompactInlinePicker(
                    selection: Binding(
                        get: { vm.awake.config.batteryThreshold },
                        set: { vm.awake.updateBatteryThreshold($0) }
                    ),
                    options: BatteryThreshold.allCases,
                    title: { $0.label }
                )
                .disabled(!hasBattery || !vm.awake.config.autoEnabled)
            }
            SettingsSectionDivider()
            flagsBlock
        }
    }

    private var hasBattery: Bool { vm.awake.currentBatteryPercent != nil }

    private var batterySubtitle: String {
        hasBattery
            ? "Applies only when running on battery."
            : "Not applicable on this Mac."
    }

    private var flagsBlock: some View {
        VStack(spacing: 0) {
            flagRow("Prevent display sleep",   \.preventDisplaySleep)
            SettingsSectionDivider()
            flagRow("Prevent idle sleep",      \.preventIdleSleep)
            SettingsSectionDivider()
            flagRow("Prevent system sleep",    \.preventSystemSleep)
            SettingsSectionDivider()
            flagRow("Declare user activity",   \.declareUserActivity)
        }
    }

    private func flagRow(_ title: String, _ keyPath: WritableKeyPath<CaffeinateOptions, Bool>) -> some View {
        SettingsRow(title: title) {
            Toggle("", isOn: Binding(
                get: { vm.awake.config.flags[keyPath: keyPath] },
                set: { newValue in
                    var f = vm.awake.config.flags
                    f[keyPath: keyPath] = newValue
                    vm.awake.updateFlags(f)
                }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}
