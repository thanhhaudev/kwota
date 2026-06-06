//
//  NotificationsMuteListCard.swift
//  Kwota
//

import SwiftUI

struct NotificationsMuteListCard: View {
    let vm: MenuBarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Per-account muting")
                    .font(.system(size: 13, weight: .semibold))
                Text("Only the active account triggers notifications. Muting an account keeps it silent even when it becomes active.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if vm.profileStore.profiles.isEmpty {
                Text("Add a profile from the Profiles tab to manage muting.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                ForEach(vm.profileStore.profiles, id: \.id) { profile in
                    row(for: profile)
                    if profile.id != vm.profileStore.profiles.last?.id {
                        Divider()
                    }
                }
            }
        }
        .settingsCard()
    }

    @ViewBuilder
    private func row(for profile: Profile) -> some View {
        let muted = profile.notificationsMuted
        let isActive = profile.id == vm.profileStore.activeProfileId

        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(profile.resolvedDisplayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(muted ? .secondary : .primary)
                    if isActive {
                        Text("Default")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                    }
                }
                Text(authCaption(for: profile))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { muted },
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
        .padding(.vertical, 4)
    }

    private func authCaption(for profile: Profile) -> String {
        switch profile.authMethod {
        case .cliSync:    return "CLI session"
        case .sessionKey: return "Browser session"
        }
    }
}
