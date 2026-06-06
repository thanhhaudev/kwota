//
//  NotificationsProfileCard.swift
//  Kwota
//
//  Stub: temporary scaffold while the Notifications tab is rebuilt.
//  The full per-account UI moves to NotificationsMuteListCard in a later
//  task; this card is deleted then. Kept here only so the tab compiles.
//

import SwiftUI

struct NotificationsProfileCard: View {
    let profile: Profile
    let isActive: Bool
    let vm: MenuBarViewModel
    let onAuthChange: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(profile.name)
                    .font(.headline)
                if isActive {
                    Text("Default")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                }
                Spacer()
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mute notifications")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Silence quota and token-expiry alerts for this account.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { profile.notificationsMuted },
                    set: { newValue in
                        var p = profile
                        p.notificationsMuted = newValue
                        try? vm.profileStore.updateProfile(p)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
        .settingsCard()
    }
}
