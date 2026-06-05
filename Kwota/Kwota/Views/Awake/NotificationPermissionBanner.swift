//
//  NotificationPermissionBanner.swift
//  Kwota
//

import SwiftUI
import AppKit

struct NotificationPermissionBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 14))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications blocked")
                    .font(.callout).fontWeight(.semibold)
                Text("You won't see auto-stop alerts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                openSystemNotificationSettings()
            } label: {
                Text("Open System Settings")
                    .font(.caption).fontWeight(.medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.red.opacity(0.12))
                .stroke(Color.red.opacity(0.4), lineWidth: 0.5)
        )
    }

    private func openSystemNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
}
