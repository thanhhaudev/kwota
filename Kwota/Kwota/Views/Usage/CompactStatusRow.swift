//
//  CompactStatusRow.swift
//  Kwota
//
//  One compact "status list" row: limit name + "% left", a battery-style meter
//  colored by urgency, and an optional reset countdown + status tag beneath.
//  Shared by the session/weekly headline rows (with a verdict tag + reset) and
//  the per-model / per-category level rows (level-only, no verdict).
//
//  Reuses UsageBatteryRow's remaining-quota statics so "% remaining" stays the
//  single source of truth for the number and bar width.
//

import SwiftUI

struct CompactStatusRow: View {
    let label: String
    /// 0–100 USED (the app-wide convention). The row renders 100 − utilization.
    let utilization: Double?
    var resetsAt: Date? = nil
    var now: Date = Date()
    var tag: CompactUsageStatus.Tag? = nil

    private var remainingFraction: CGFloat {
        CGFloat(UsageBatteryRow.remainingWidth(for: utilization) / 100)
    }

    private var meterColor: Color {
        UsageUrgency(utilization: utilization)?.color ?? Color.secondary
    }

    private var hasFooter: Bool {
        resetsAt != nil || tag != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.primary)
                Spacer()
                value
            }

            meter

            if hasFooter {
                HStack(spacing: 8) {
                    if let resetsAt {
                        Text(UsageTrendChart.formatResetCountdown(until: resetsAt, now: now))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if let tag {
                        tagView(tag)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var value: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(UsageBatteryRow.remainingText(for: utilization))
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(utilization == nil ? .secondary : .primary)
            if utilization != nil {
                Text("left")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var meter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(meterColor.gradient)
                    .frame(width: max(0, geo.size.width * remainingFraction))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private func tagView(_ tag: CompactUsageStatus.Tag) -> some View {
        Text(tag.text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tagColor(tag.style))
            .padding(.horizontal, 7)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tagColor(tag.style).opacity(0.18)))
    }

    private func tagColor(_ style: CompactUsageStatus.Style) -> Color {
        switch style {
        case .calm:    return .green
        case .watch:   return .orange
        case .hot:     return .red
        case .neutral: return .secondary
        }
    }
}
