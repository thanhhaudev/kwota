//
//  DataStorageTabView.swift
//  Kwota
//

import SwiftUI

struct DataStorageTabView: View {
    let vm: MenuBarViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsGroupedSection(caption: "Storage") {
                        StorageFootprintCard(vm: vm)
                    }
                    .id("data.storage")

                    SettingsGroupedSection(caption: "Token stats") {
                        ClearStatsCard(vm: vm, provider: .claude)
                        SettingsSectionDivider()
                        ClearStatsCard(vm: vm, provider: .codex)
                        SettingsSectionDivider()
                        ClearStatsCard(vm: vm, provider: .antigravity)
                    }
                    .id("data.tokenstats")

                    SettingsGroupedSection(caption: "Usage history",
                                           footer: "Older entries are removed automatically when these limits are reached.") {
                        UsageHistoryCapsCard(vm: vm)
                    }
                    .id("data.usagehistory")

                    SettingsGroupedSection(caption: "Account history") {
                        ProfileHistoryCard(vm: vm)
                    }
                    .id("data.profilehistory")

                    SettingsGroupedSection(caption: "Reset") {
                        ResetEverythingCard(vm: vm)
                    }
                    .id("data.reset")
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .task(id: SettingsWindowPresenter.shared.pendingAnchorId) { consumePendingAnchor(proxy: proxy) }
        }
    }

    private func consumePendingAnchor(proxy: ScrollViewProxy) {
        let presenter = SettingsWindowPresenter.shared
        guard let anchor = presenter.pendingAnchorId, anchor.hasPrefix("data.") else { return }
        presenter.pendingAnchorId = nil
        withAnimation { proxy.scrollTo(anchor, anchor: .top) }
    }
}
