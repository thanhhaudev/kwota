//
//  CompactQuotaBar.swift
//  Kwota
//
//  Headline quota row for compact mode: label, remaining percentage, a
//  full-width battery bar, and the reset countdown. Session and weekly each
//  get one. Per-model rows use the denser `UsageBatteryRow` instead — these
//  two earn the extra height because they are the headline values and are the
//  only ones carrying a reset time.
//

import SwiftUI

struct CompactQuotaBar: View {
    let label: String
    let bucket: UsageBucket
    var now: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                Text(UsageBatteryRow.remainingText(for: bucket.utilization))
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(UsageLevel.tint(for: bucket.utilization))
            }
            track
            if let resetsAt = bucket.resetsAt {
                Text(UsageTrendChart.formatResetCountdown(until: resetsAt, now: now))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Battery track. `UsageLevel.tint` is fed the utilization (used), so the
    /// fill goes red as the *remaining* bar shrinks — an empty red bar means
    /// exhausted.
    private var track: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(UsageLevel.tint(for: bucket.utilization).gradient)
                    .frame(
                        width: geo.size.width
                            * UsageBatteryRow.remainingWidth(for: bucket.utilization) / 100
                    )
            }
        }
        .frame(height: 8)
    }
}
