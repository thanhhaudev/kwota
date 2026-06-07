//
//  NotificationsMuteListCard.swift
//  Kwota
//

import SwiftUI

struct NotificationsMuteListCard: View {
    let vm: MenuBarViewModel

    var body: some View {
        let liveProfiles = vm.profileStore.profiles.filter { $0.kind == .auto && isLive($0) }

        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Per-account muting")
                    .font(.system(size: 13, weight: .semibold))
                Text("Only live accounts (signed-in CLI or running app) fire notifications. Mute settings for offline accounts are preserved and apply when they come back online.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if liveProfiles.isEmpty {
                Text("No live accounts right now. Sign in to a provider's CLI or launch its app to manage notifications.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                ForEach(liveProfiles, id: \.id) { profile in
                    row(for: profile)
                    if profile.id != liveProfiles.last?.id {
                        Divider()
                    }
                }
            }
        }
        .settingsCard()
    }

    private func isLive(_ profile: Profile) -> Bool {
        ProfileSwitcherCard.isLive(
            profile: profile,
            claudeCLIEmail: vm.cliAccountWatcher.current?.email,
            codexCLIEmail: vm.codexAccountWatcher.current?.email,
            antigravityProcessAlive: vm.antigravityProcessWatcher.current != nil
        )
    }

    @ViewBuilder
    private func row(for profile: Profile) -> some View {
        let muted = profile.notificationsMuted
        let isDefault = profile.id == vm.profileStore.activeProfileId

        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.resolvedDisplayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(muted ? .secondary : .primary)
                    if isDefault {
                        chip(label: "Default", color: .accentColor)
                    }
                }
                Text(metadataCaption(for: profile))
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

    @ViewBuilder
    private func chip(label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
    }

    private func metadataCaption(for profile: Profile) -> String {
        let provider = vm.registry.provider(for: profile.providerID)?.displayName
            ?? profile.providerID.rawValue.capitalized
        return "\(provider) · \(authLabel(for: profile))"
    }

    private func authLabel(for profile: Profile) -> String {
        switch profile.authMethod {
        case .cliSync:    return "CLI session"
        case .sessionKey: return "Browser session"
        }
    }
}
