//
//  KeychainAccessBanner.swift
//  Kwota
//
//  Shown when a background credential read was refused because it would have
//  needed a consent dialog. Kwota never raises that dialog on its own — an
//  unanswered one froze the app for two hours on 2026-08-04 — so the user
//  asks for it explicitly, while they are at the machine to answer.
//

import SwiftUI

struct KeychainAccessBanner: View {
    let onGrant: () -> Void

    var body: some View {
        KwotaInlineAlert(
            tint: .blue,
            icon: "key.fill",
            title: "Keychain access needed",
            detail: "Kwota needs your approval to read the Claude Code credential. Showing the last known figures until then.",
            actionTitle: "Grant",
            onAction: onGrant
        )
    }
}
