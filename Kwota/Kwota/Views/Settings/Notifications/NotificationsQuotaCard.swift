//
//  NotificationsQuotaCard.swift
//  Kwota
//

import SwiftUI

struct NotificationsQuotaCard: View {
    let store: NotificationSettingsStore

    private static let thresholds = [75, 90, 100]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            quotaSection(
                title: "Short-window quota",
                subtitle: "Notify when the active account's short refill window approaches its limit.",
                selected: store.value.shortWindowThresholds,
                set: { store.value.shortWindowThresholds = $0 }
            )

            Divider()
            quotaSection(
                title: "Long-window quota",
                subtitle: "Notify when the active account's long-term cap approaches its limit.",
                selected: store.value.longWindowThresholds,
                set: { store.value.longWindowThresholds = $0 }
            )

            Divider()
            notifyCheckbox(
                title: "Notify when quota resets",
                subtitle: "Receive a notification when either window resets.",
                isOn: Binding(
                    get: { store.value.notifyOnReset },
                    set: { store.value.notifyOnReset = $0 }
                )
            )

            notifyCheckbox(
                title: "Notify when CLI token is about to expire",
                subtitle: "Alerts you before the active account's CLI token expires. Only applies to CLI-authenticated accounts.",
                isOn: Binding(
                    get: { store.value.notifyOnTokenExpiry },
                    set: { store.value.notifyOnTokenExpiry = $0 }
                )
            )
        }
        .settingsCard()
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
                ForEach(Self.thresholds, id: \.self) { value in
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
}
