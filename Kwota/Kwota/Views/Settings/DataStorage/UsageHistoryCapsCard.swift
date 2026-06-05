//
//  UsageHistoryCapsCard.swift
//  Kwota
//

import SwiftUI

struct UsageHistoryCapsCard: View {
    let vm: MenuBarViewModel

    private static let capOptions = [100, 500, 1000, 2000, 5000]

    @AppStorage(AppStorageKeys.generalUsageHistorySessionCap) private var sessionCap: Int = 1000
    @AppStorage(AppStorageKeys.generalUsageHistoryWeeklyCap)  private var weeklyCap:  Int = 500

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(title: "Session entries") {
                CompactInlinePicker(
                    selection: $sessionCap,
                    options: Self.capOptions,
                    title: { "\($0)" }
                )
                .onChange(of: sessionCap) { _, _ in vm.reloadHistoryStores() }
            }
            SettingsSectionDivider()
            SettingsRow(title: "Weekly entries") {
                CompactInlinePicker(
                    selection: $weeklyCap,
                    options: Self.capOptions,
                    title: { "\($0)" }
                )
                .onChange(of: weeklyCap) { _, _ in vm.reloadHistoryStores() }
            }
        }
    }
}
