//
//  AwakeTabView.swift
//  Kwota
//

import SwiftUI

struct AwakeTabView: View {
    let vm: MenuBarViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsGroupedSection(caption: "Status") {
                    AwakeStatusRow(vm: vm)
                }

                SettingsGroupedSection(
                    caption: "Keep awake",
                    footer: "Detects activity from your AI agents' logs. Sleep-prevention flags apply to both auto and manual keep-awake."
                ) {
                    AwakeAutoCard(vm: vm)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}
