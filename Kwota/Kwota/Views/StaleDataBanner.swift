//
//  StaleDataBanner.swift
//  Kwota
//
//  Surfaced above usage content when the last successful refresh is
//  older than `StaleDataBanner.threshold`. Tapping the CTA triggers a
//  manual refresh.
//

import SwiftUI

struct StaleDataBanner: View {
    static let threshold: TimeInterval = 5 * 60

    let lastFetchedAt: Date
    let onRefresh: () -> Void

    var body: some View {
        KwotaInlineAlert(
            tint: .yellow,
            icon: "clock.fill",
            title: "Data may be stale",
            detail: "Updated \(RelativeFormatters.abbreviated.localizedString(for: lastFetchedAt, relativeTo: Date()))",
            actionTitle: "Refresh",
            onAction: onRefresh
        )
    }
}
