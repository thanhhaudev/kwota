//
//  NotificationsTabView.swift
//  Kwota
//

import SwiftUI
import UserNotifications

struct NotificationsTabView: View {
    let vm: MenuBarViewModel

    /// `nil` while the first `.task` is in flight. The banner stays hidden
    /// during that gap so we don't flash it for an already-authorized user.
    @State private var authStatus: UNAuthorizationStatus? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let status = authStatus,
                   status == .denied || status == .notDetermined {
                    NotificationsPermissionBanner(status: status, vm: vm) {
                        await refreshAuthStatus()
                    }
                }

                NotificationsQuotaCard(store: vm.notificationSettingsStore)
                NotificationsMuteListCard(vm: vm)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task { await refreshAuthStatus() }
    }

    private func refreshAuthStatus() async {
        authStatus = await vm.notificationDispatcher.authorizationStatus()
    }
}
