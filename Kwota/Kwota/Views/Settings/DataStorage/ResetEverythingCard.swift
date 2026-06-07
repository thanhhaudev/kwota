//
//  ResetEverythingCard.swift
//  Kwota
//

import SwiftUI
import AppKit

struct ResetEverythingCard: View {
    let vm: MenuBarViewModel

    @State private var firstAlertShown = false
    @State private var secondAlertShown = false
    @State private var resetField: String = ""

    private let resetService = DataResetService()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button(role: .destructive) {
                firstAlertShown = true
            } label: {
                Text("Delete all data…")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Text("Removes accounts, credentials, usage history, settings, and cache results. Kwota will quit after reset.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .alert("Reset all Kwota data?", isPresented: $firstAlertShown) {
            Button("Continue", role: .destructive) {
                resetField = ""
                secondAlertShown = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This wipes accounts, credentials, usage history, settings, and cache scan results, then quits Kwota.")
        }
        .sheet(isPresented: $secondAlertShown) {
            ResetConfirmSheet(resetField: $resetField) {
                secondAlertShown = false
                performReset()
            } onCancel: {
                secondAlertShown = false
            }
        }
    }

    private func performReset() {
        do {
            try resetService.wipeAll(keychain: vm.credentialStore)
            NSApp.terminate(nil)
        } catch let error as DataResetService.WipeError {
            AppLog.shared.log("Reset failed: \(error)", level: .error)
            // Defer past the confirm-sheet dismiss so NSAlert doesn't fight
            // the in-flight SwiftUI sheet animation by entering a nested AppKit
            // runloop on top of it.
            Task { @MainActor in
                presentResetFailureAlert(error)
            }
        } catch {
            AppLog.shared.log("Reset failed (unknown): \(error)", level: .error)
            Task { @MainActor in
                presentResetFailureAlert(.keychainFailed(error))
            }
        }
    }

    private func presentResetFailureAlert(_ error: DataResetService.WipeError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch error {
        case .keychainFailed(let inner):
            alert.messageText = "Reset incomplete"
            alert.informativeText = """
            Kwota could not clear stored credentials from Keychain. No other data was deleted.

            Details: \(inner.localizedDescription)

            Unlock Keychain Access and try again.
            """
        case .appSupportFailed(let inner):
            alert.messageText = "Reset partially completed"
            alert.informativeText = """
            Kwota cleared credentials and preferences but could not remove some files in the Application Support directory.

            Details: \(inner.localizedDescription)

            You may want to manually delete the Kwota folder under ~/Library/Application Support.
            """
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private struct ResetConfirmSheet: View {
    @Binding var resetField: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Type RESET to confirm")
                .font(.headline)
            Text("This action is permanent. The app quits immediately after the reset completes.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField("RESET", text: $resetField)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive, action: onConfirm) {
                    Text("Reset all data")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(resetField != "RESET")
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
