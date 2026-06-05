//
//  GeneralLaunchCard.swift
//  Kwota
//

import SwiftUI

struct GeneralLaunchCard: View {
    @State private var status: LoginItemController.Status = .disabled
    @State private var lastError: String?

    private var isEnabledBinding: Binding<Bool> {
        Binding(
            get: { status == .enabled || status == .requiresApproval },
            set: { newValue in attemptToggle(to: newValue) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsRow(title: "Open Kwota at login",
                        subtitle: "Start Kwota automatically when you sign in.") {
                Toggle("", isOn: isEnabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if status == .requiresApproval {
                Text("Approve in System Settings → General → Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
            }
            if let lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
            }
        }
        .onAppear { refreshStatus() }
    }

    private func refreshStatus() {
        status = LoginItemController.shared.status
    }

    private func attemptToggle(to newValue: Bool) {
        do {
            try LoginItemController.shared.setEnabled(newValue)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            AppLog.shared.log("GeneralLaunchCard toggle failed: \(error)", level: .warn)
        }
        refreshStatus()
    }
}
