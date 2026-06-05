//
//  GeneralTabView.swift
//  Kwota
//

import SwiftUI

struct GeneralTabView: View {
    let vm: MenuBarViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsGroupedSection(caption: "Launch") {
                        GeneralLaunchCard()
                    }
                    .id("general.launch")

                    SettingsGroupedSection(caption: "Refresh",
                                           footer: "Changes take effect after restarting Kwota.") {
                        GeneralRefreshCard()
                    }
                    .id("general.refresh")

                    SettingsGroupedSection(caption: "Dock icon") {
                        GeneralDockIconCard()
                    }
                    .id("general.dockicon")
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .task(id: SettingsWindowPresenter.shared.pendingAnchorId) {
                consumePendingAnchor(proxy: proxy)
            }
        }
    }

    private func consumePendingAnchor(proxy: ScrollViewProxy) {
        let presenter = SettingsWindowPresenter.shared
        guard let anchor = presenter.pendingAnchorId, anchor.hasPrefix("general.") else { return }
        presenter.pendingAnchorId = nil
        withAnimation { proxy.scrollTo(anchor, anchor: .top) }
    }
}
