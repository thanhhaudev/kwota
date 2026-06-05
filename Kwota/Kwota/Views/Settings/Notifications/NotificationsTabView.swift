//
//  NotificationsTabView.swift
//  Kwota
//

import SwiftUI
import UserNotifications

struct NotificationsTabView: View {
    let vm: MenuBarViewModel
    @State private var authStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if authStatus == .denied || authStatus == .notDetermined {
                    NotificationsPermissionBanner(status: authStatus, vm: vm) {
                        await refreshAuthStatus()
                    }
                }

                if vm.profileStore.profiles.isEmpty {
                    emptyState
                } else {
                    ForEach(vm.profileStore.profiles, id: \.id) { profile in
                        NotificationsProfileCard(
                            profile: profile,
                            isActive: profile.id == vm.profileStore.activeProfileId,
                            vm: vm,
                            onAuthChange: {
                                await refreshAuthStatus()
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task { await refreshAuthStatus() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell.slash")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text("No profiles yet")
                .font(.system(size: 14, weight: .medium))
            Text("Add a profile from the Profiles tab to configure notifications.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func refreshAuthStatus() async {
        authStatus = await vm.notificationDispatcher.authorizationStatus()
    }
}
