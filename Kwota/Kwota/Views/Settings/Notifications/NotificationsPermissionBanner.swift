//
//  NotificationsPermissionBanner.swift
//  Kwota
//

import SwiftUI
import UserNotifications
import AppKit

struct NotificationsPermissionBanner: View {
    let status: UNAuthorizationStatus
    let vm: MenuBarViewModel
    let onRefresh: () async -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            actionButton
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.12)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.yellow.opacity(0.35), lineWidth: 1)
        )
    }

    private var title: String {
        switch status {
        case .notDetermined: return "Notifications haven't been enabled yet."
        case .denied:        return "Notifications are off for Kwota."
        default:             return ""
        }
    }

    private var detail: String {
        switch status {
        case .notDetermined: return "Toggle a profile on to grant permission, or grant it now."
        case .denied:        return "Allow them in System Settings → Notifications → Kwota."
        default:             return ""
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .notDetermined:
            Button("Grant access") {
                Task {
                    _ = await vm.notificationDispatcher.requestAuthorization()
                    await onRefresh()
                }
            }
            .buttonStyle(.borderedProminent)
        case .denied:
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
        default:
            EmptyView()
        }
    }
}
