//
//  KwotaConfirmPopover.swift
//  Kwota
//
//  Shared confirm bubble for destructive actions inside the menu-bar
//  popover. Alerts and sheets cannot be used there (they steal key status
//  from the MenuBarExtra window and dismiss it — see CacheTabView's AI
//  detail comment); an anchored .popover is the native-feeling shape that
//  survives. Present it via .popover { KwotaConfirmPopover(...) }.
//
//  Layout follows the macOS dialog convention: bold one-line title,
//  secondary message, buttons right-aligned with Cancel to the left of the
//  destructive action.
//

import SwiftUI

struct KwotaConfirmPopover: View {
    let title: String
    let message: String
    let destructiveTitle: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button(destructiveTitle, role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.red)
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
    }
}
