//
//  KeepAwakeTabView.swift
//  Kwota
//

import SwiftUI

struct KeepAwakeTabView: View {
    let vm: MenuBarViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if vm.isNotificationPermissionDenied {
                    NotificationPermissionBanner()
                }

                AwakeCard(vm: vm)

                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Activity")
                    ActivityChartCard(vm: vm)
                }

                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(
                        title: "Agent Processes",
                        info: ["Agent CLI processes currently running. A process whose parent died is re-parented to launchd and labeled Orphan — those can be killed from here."]
                    )
                    AgentProcessesCard(vm: vm)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        // Tab content is recreated on tab switch and popover open/close, so
        // appear/disappear bound the polling window exactly to visibility.
        .onAppear { vm.startAgentProcessPolling() }
        .onDisappear { vm.stopAgentProcessPolling() }
    }
}
