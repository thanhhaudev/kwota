//
//  NotificationsProfileCard.swift
//  Kwota
//

import SwiftUI
import UserNotifications

struct NotificationsProfileCard: View {
    let profile: Profile
    let isActive: Bool
    let vm: MenuBarViewModel
    let onAuthChange: () async -> Void

    private var config: NotificationConfig {
        profile.notifications ?? .default
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            enableRow

            if config.enabled {
                Divider()
                quotaSection(
                    title: "Session quota",
                    subtitle: "Get notified when your current session reaches the selected quota levels.",
                    selected: config.sessionThresholds,
                    set: { newSet in update { $0.sessionThresholds = newSet } }
                )

                Divider()
                quotaSection(
                    title: "Weekly quota",
                    subtitle: "Get notified when your weekly quota reaches the selected levels.",
                    selected: config.weeklyThresholds,
                    set: { newSet in update { $0.weeklyThresholds = newSet } }
                )

                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    notifyCheckbox(
                        title: "Notify when quota resets",
                        subtitle: "Receive a notification when your quota is reset (usually weekly).",
                        isOn: bindBool(\.notifyOnReset)
                    )

                    if profile.authMethod == .cliSync {
                        notifyCheckbox(
                            title: "Notify when CLI token is about to expire",
                            subtitle: "Get alerted before your CLI token expires.",
                            isOn: bindBool(\.notifyOnTokenExpiry)
                        )
                    }
                }
            }
        }
        .settingsCard()
    }

    private var header: some View {
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
    }

    private var enableRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Enable notifications")
                    .font(.system(size: 13, weight: .semibold))
                Text("Receive alerts and updates about your usage and quota.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func quotaSection(
        title: String,
        subtitle: String,
        selected: Set<Int>,
        set: @escaping (Set<Int>) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 24) {
                ForEach([75, 90, 100], id: \.self) { value in
                    Toggle("\(value)%", isOn: Binding(
                        get: { selected.contains(value) },
                        set: { isOn in
                            var copy = selected
                            if isOn { copy.insert(value) } else { copy.remove(value) }
                            set(copy)
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
                Spacer()
            }

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func notifyCheckbox(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { config.enabled },
            set: { newValue in
                Task { await toggleEnabled(to: newValue) }
            }
        )
    }

    private func toggleEnabled(to newValue: Bool) async {
        if newValue {
            let status = await vm.notificationDispatcher.authorizationStatus()
            if status == .notDetermined {
                let granted = await vm.notificationDispatcher.requestAuthorization()
                await onAuthChange()
                if !granted { return }
            } else if status == .denied {
                await onAuthChange()
                return
            }
        }
        update { $0.enabled = newValue }
    }

    private func bindBool(_ keyPath: WritableKeyPath<NotificationConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { newValue in
                update { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private func update(_ mutate: (inout NotificationConfig) -> Void) {
        var c = profile.notifications ?? .default
        mutate(&c)
        var p = profile
        p.notifications = c
        try? vm.profileStore.updateProfile(p)
    }
}
