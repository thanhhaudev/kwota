//
//  DisplayTabView.swift
//  Kwota

import SwiftUI

struct DisplayTabView: View {
    let vm: MenuBarViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsGroupedSection(caption: "Menu bar") {
                        DisplayMenuBarCard(vm: vm)
                    }
                    .id("display.menubar")

                    SettingsGroupedSection(caption: "Appearance",
                                           footer: "Affects the popover and Settings window.") {
                        DisplayThemeCard()
                    }
                    .id("display.theme")

                    SettingsGroupedSection(caption: "Popover tabs",
                                           footer: "Choose which tabs are shown in the menu bar popover.") {
                        DisplayPopoverTabsCard()
                    }
                    .id("display.popovertabs")

                    SettingsGroupedSection(caption: "Chart",
                                           footer: "Shows helpful chart guides based on your usage history.") {
                        DisplayChartCard()
                    }
                    .id("display.chart")
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
        guard let anchor = presenter.pendingAnchorId, anchor.hasPrefix("display.") else { return }
        presenter.pendingAnchorId = nil
        withAnimation { proxy.scrollTo(anchor, anchor: .top) }
    }
}
