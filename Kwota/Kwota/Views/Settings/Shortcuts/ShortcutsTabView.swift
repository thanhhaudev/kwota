//
//  ShortcutsTabView.swift
//  Kwota
//

import SwiftUI

struct ShortcutsTabView: View {
    let vm: MenuBarViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Global")
                    ShortcutsGlobalCard(
                        coordinator: vm.shortcutCoordinator,
                        profileStore: vm.profileStore
                    )
                }

                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(
                        title: "Account Navigation",
                        info: [
                            "Works only while the popup is open.",
                            "Without modifiers, only arrow keys are allowed."
                        ]
                    )
                    ShortcutsNavigationCard(profileStore: vm.profileStore)
                }

                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(
                        title: "Tab Navigation",
                        info: [
                            "Works only while the popup is open.",
                            "Without modifiers, only arrow keys are allowed for Next/Previous tab.",
                            "Hidden tabs don't participate in shortcut conflicts."
                        ]
                    )
                    ShortcutsTabsCard()
                }

                SettingsGroupedSection(
                    caption: "Switch Account",
                    footer: "Works only while the popup is open. Manage accounts in the Accounts tab."
                ) {
                    ShortcutsAccountsCard(vm: vm)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}
