//
//  RateLimitBanner.swift
//  Kwota
//
//  Shown when Anthropic returns 429 on the active refresh path. Without
//  this banner a manual Refresh click looks like a no-op — the snapshot
//  is intentionally preserved while we honor the server's Retry-After,
//  but the user has no way to know that. Banner displays a live countdown
//  and offers a "Try now" probe in case the throttle has cleared.
//

import SwiftUI

struct RateLimitBanner: View {
    let retryAt: Date
    let onRetry: () -> Void

    var body: some View {
        KwotaInlineAlert(
            tint: .orange,
            icon: "hourglass",
            title: "Rate limited by Anthropic",
            detail: {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(detail(for: context.date))
                }
            },
            actionTitle: "Try now",
            onAction: onRetry
        )
    }

    private func detail(for now: Date) -> String {
        let remaining = retryAt.timeIntervalSince(now)
        if remaining <= 0 {
            return "Back-off elapsed — try refreshing again."
        }
        return "Holding last snapshot · retry in \(formatRemaining(remaining))"
    }

    private func formatRemaining(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        if s < 60 { return "\(s)s" }
        let m = (s + 59) / 60
        return "\(m)m"
    }
}
