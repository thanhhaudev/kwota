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
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
