//
//  ReAuthBanner.swift
//  Kwota
//
//  Surfaced in the popover when the active profile's credentials are
//  missing or rejected (authState == .expired, or the defensively-matched
//  .error / .unauthenticated). The title and detail are supplied by the
//  active profile's provider (`reauthTitle` / `reauthInstruction`) so the
//  copy names the right CLI — Claude vs Codex — or, for providers without a
//  CLI, the right recovery step (e.g. "open the Antigravity app").
//

import SwiftUI

struct ReAuthBanner: View {
    let title: String
    let detail: String

    var body: some View {
        KwotaInlineAlert(
            tint: .orange,
            icon: "exclamationmark.triangle.fill",
            title: title,
            detail: detail,
            actionTitle: nil,
            onAction: nil
        )
    }
}
