//
//  RateLimitBanner.swift
//  Kwota
//
//  Shown when Anthropic returns 429 on the active refresh path. Without
//  this banner a manual Refresh click looks like a no-op — the snapshot
//  is intentionally preserved while we honor the server's Retry-After,
//  but the user has no way to know that. Banner displays a live countdown
//  (capped at MenuBarViewModel.manualRetryCap even when the server asks
//  for much longer) and offers a "Try now" probe that bypasses the
//  back-off floor — probing while throttled is the button's purpose.
//
//  `isProbing` keeps the banner on screen with a spinner while the probe
//  is in flight, so a repeat 429 reads as "tried, still throttled" with a
//  fresh countdown instead of the button silently doing nothing.
//

import SwiftUI

struct RateLimitBanner: View {
    let retryAt: Date
    var isProbing: Bool = false
    /// False while the probe gate (the 10s burst throttle) would silently
    /// swallow a click — the 429 that armed this banner stamped the
    /// throttle itself, so the first ~10s after it appears are exactly
    /// when users click. A greyed button reads "just tried, hold on";
    /// an active one guarantees visible action (spinner) on click.
    var probeEnabled: Bool = true
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
            onAction: onRetry,
            isActionBusy: isProbing
        )
        // .disabled reaches only the interactive control (the action
        // Button) — the countdown text is unaffected.
        .disabled(!probeEnabled && !isProbing)
    }

    private func detail(for now: Date) -> String {
        if isProbing {
            return "Checking whether the throttle has cleared…"
        }
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
